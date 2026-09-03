// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-4.8/access/AccessControl.sol";
import "@openzeppelin/contracts-4.8/proxy/Clones.sol";
import "../supportContract/binderIds.sol";
import "./BattleProxy.sol";
import "../supportContract/Errors.sol";
import "../interfaces/IBattleFactory.sol";
import "../interfaces/IBinderData.sol";
import "../interfaces/IBinderSkills.sol";
import "../interfaces/IBook0fArts.sol";
import "../interfaces/IBook0fRealms.sol";
import "../interfaces/ICentralConsole.sol";
import "../supportContract/binderStructs.sol";

/// @notice Canonical factory and stable BinderData Battle-activity gateway.
/// @dev Each clone points to this factory's immutable implementation. Upgrading
/// battle execution means deploying a new factory/implementation and registering
/// it in CentralConsole; existing clones therefore retain their original code.
contract BattleFactory is AccessControl, IBattleFactory {
    /// @notice A two-player draft that records explicit consent before custody.
    struct BattleInvitation {
        address challenger;
        address opponent;
        uint32 mapId;
        uint48 expiresAt;
        bool accepted;
        bool cancelled;
    }

    /// @notice A single player's bounded party and selected Battle loadouts.
    /// @dev A submission never moves NFTs. Both submissions are revalidated and
    /// escrowed atomically only when the named opponent accepts the invitation.
    struct PartySubmission {
        uint256[] tokenIds;
        uint16[] spawnTileIds;
        uint32[][] selectedArtIds;
        bool submitted;
    }

    bytes32 public constant CONFIG_ROLE = keccak256("CONFIG_ROLE");

    ICentralConsole public immutable centralConsole;
    address public immutable battleImplementation;
    mapping(address => bool) public override isBattleProxy;
    uint256 public nextInvitationId = 1;
    mapping(uint256 => BattleInvitation) private _battleInvitations;
    mapping(uint256 => PartySubmission) private _challengerParties;
    mapping(uint256 => PartySubmission) private _opponentParties;

    event BattleInvitationCreated(
        uint256 indexed invitationId,
        address indexed challenger,
        address indexed opponent,
        uint32 mapId,
        uint48 expiresAt
    );
    event BattleInvitationCancelled(uint256 indexed invitationId, address indexed caller);
    event BattleInvitationAccepted(uint256 indexed invitationId, address indexed opponent, address indexed battleProxy);
    event BattleCreated(
        address indexed battleProxy,
        uint256 indexed invitationId,
        uint32 indexed mapId,
        uint16 mapVersion,
        address book0fArts,
        address book0fRealms,
        uint256 participantCount
    );
    event BattleActivityEnded(address indexed battleProxy, uint256 indexed tokenId);

    error InvalidBattleImplementation(address implementation);
    error NotCanonicalBattleFactory(address expectedFactory, address actualFactory);
    error BattleActivityGatewayNotConfigured(address configuredController);
    error InvalidBattleParticipantCount(uint256 participantCount);
    error MismatchedBattleInputs();
    error InvalidInvitationOpponent(address opponent);
    error InvalidInvitationExpiry(uint48 expiresAt);
    error UnknownBattleInvitation(uint256 invitationId);
    error UnauthorizedInvitationParty(uint256 invitationId, address expectedParticipant, address actualCaller);
    error BattleInvitationExpired(uint256 invitationId, uint48 expiresAt);
    error BattleInvitationAlreadyAccepted(uint256 invitationId);
    error BattleInvitationWasCancelled(uint256 invitationId);
    error PartyAlreadySubmitted(uint256 invitationId, address participant);
    error DuplicateInvitationToken(uint256 invitationId, uint256 tokenId);
    error InvitationTokenOwnerMismatch(
        uint256 invitationId, uint256 tokenId, address expectedOwner, address actualOwner
    );
    error InvitationTokenNotReady(uint256 invitationId, uint256 tokenId);
    error BattleTransferNotApproved(uint256 invitationId, uint256 tokenId, address owner);
    error BattleTokenNotEscrowed(uint256 tokenId, address expectedProxy, address actualOwner);
    error BattleActivityMismatch(uint256 tokenId, uint8 activityId);

    constructor(address initialAdmin, address centralConsoleAddress, address battleImplementationAddress) {
        if (initialAdmin == address(0) || centralConsoleAddress.code.length == 0) {
            revert InvalidInitialOwner(initialAdmin);
        }
        if (battleImplementationAddress.code.length == 0) {
            revert InvalidBattleImplementation(battleImplementationAddress);
        }
        centralConsole = ICentralConsole(centralConsoleAddress);
        battleImplementation = battleImplementationAddress;
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(CONFIG_ROLE, initialAdmin);
    }

    /// @notice Creates an expiring invitation and records the challenger's own party.
    /// @dev Ownership is checked here and rechecked at activation. ERC-721 approval
    /// permits the later transfer but never substitutes for this explicit call.
    function createBattleInvitation(
        address opponent,
        uint32 mapId,
        uint48 expiresAt,
        PartySubmission calldata challengerParty
    ) external returns (uint256 invitationId) {
        _requireCanonicalFactory();
        if (opponent == address(0) || opponent == msg.sender) revert InvalidInvitationOpponent(opponent);
        if (expiresAt <= block.timestamp) revert InvalidInvitationExpiry(expiresAt);

        invitationId = nextInvitationId++;
        _battleInvitations[invitationId] = BattleInvitation({
            challenger: msg.sender,
            opponent: opponent,
            mapId: mapId,
            expiresAt: expiresAt,
            accepted: false,
            cancelled: false
        });
        _storeParty(invitationId, _challengerParties[invitationId], challengerParty, msg.sender);
        emit BattleInvitationCreated(invitationId, msg.sender, opponent, mapId, expiresAt);
    }

    /// @notice The named opponent explicitly supplies its own party and atomically activates the match.
    function acceptBattleInvitation(uint256 invitationId, PartySubmission calldata opponentParty)
        external
        returns (address battleProxy)
    {
        BattleInvitation storage invitation = _requireActiveInvitation(invitationId);
        if (msg.sender != invitation.opponent) {
            revert UnauthorizedInvitationParty(invitationId, invitation.opponent, msg.sender);
        }
        if (invitation.accepted) revert BattleInvitationAlreadyAccepted(invitationId);

        _storeParty(invitationId, _opponentParties[invitationId], opponentParty, msg.sender);
        _validateDistinctParties(invitationId);

        invitation.accepted = true;
        battleProxy = _createAndEscrowBattle(invitationId, invitation);
        emit BattleInvitationAccepted(invitationId, msg.sender, battleProxy);
    }

    /// @notice Cancels a draft without moving NFTs. Named players may cancel at
    /// any time before acceptance; anyone may clear an expired draft.
    function cancelBattleInvitation(uint256 invitationId) external {
        BattleInvitation storage invitation = _getInvitation(invitationId);
        if (invitation.accepted) revert BattleInvitationAlreadyAccepted(invitationId);
        if (invitation.cancelled) revert BattleInvitationWasCancelled(invitationId);
        if (
            msg.sender != invitation.challenger && msg.sender != invitation.opponent
                && block.timestamp < invitation.expiresAt
        ) {
            revert UnauthorizedInvitationParty(invitationId, invitation.challenger, msg.sender);
        }
        invitation.cancelled = true;
        emit BattleInvitationCancelled(invitationId, msg.sender);
    }

    function getBattleInvitation(uint256 invitationId) external view returns (BattleInvitation memory) {
        return _getInvitation(invitationId);
    }

    function getPartySubmission(uint256 invitationId, bool challenger)
        external
        view
        returns (
            uint256[] memory tokenIds,
            uint16[] memory spawnTileIds,
            uint32[][] memory selectedArtIds,
            bool submitted
        )
    {
        _getInvitation(invitationId);
        PartySubmission storage party = challenger ? _challengerParties[invitationId] : _opponentParties[invitationId];
        return (party.tokenIds, party.spawnTileIds, party.selectedArtIds, party.submitted);
    }

    function _createAndEscrowBattle(uint256 invitationId, BattleInvitation storage invitation)
        internal
        returns (address battleProxy)
    {
        PartySubmission storage challengerParty = _challengerParties[invitationId];
        PartySubmission storage opponentParty = _opponentParties[invitationId];
        uint256 count = challengerParty.tokenIds.length + opponentParty.tokenIds.length;
        if (count > BinderIds.MAX_BATTLE_PARTICIPANTS) revert InvalidBattleParticipantCount(count);

        IBinderData binderData = IBinderData(centralConsole.binderData());
        if (binderData.getActivityController(BinderIds.ACTIVITY_BATTLE) != address(this)) {
            revert BattleActivityGatewayNotConfigured(binderData.getActivityController(BinderIds.ACTIVITY_BATTLE));
        }

        IBook0fArts book0fArts = IBook0fArts(centralConsole.book0fArts());
        IBook0fRealms book0fRealms = IBook0fRealms(centralConsole.book0fRealms());
        binderStructs.MapDefinition memory map = book0fRealms.getMap(invitation.mapId);
        if (!map.enabled) revert InvalidBattleProxy(address(0));

        _validatePartyForEscrow(invitationId, challengerParty, invitation.challenger, binderData);
        _validatePartyForEscrow(invitationId, opponentParty, invitation.opponent, binderData);

        address clone = Clones.clone(battleImplementation);
        isBattleProxy[clone] = true;
        BattleProxy.InitializationParams memory params;
        params.factoryAddress = address(this);
        params.binderDataAddress = address(binderData);
        params.binderSkillsAddress = centralConsole.binderSkills();
        params.book0fArtsAddress = address(book0fArts);
        params.book0fRealmsAddress = address(book0fRealms);
        params.requestedMapId = invitation.mapId;
        params.requestedMapVersion = map.version;
        params.tokenIds = _combineTokenIds(challengerParty, opponentParty);
        params.spawnTileIds = _combineSpawnTileIds(challengerParty, opponentParty);
        params.selectedArtIds = _combineSelectedArtIds(challengerParty, opponentParty);
        BattleProxy(clone).initialize(params);

        for (uint256 index; index < count; ++index) {
            uint256 tokenId = params.tokenIds[index];
            address owner = binderData.ownerOf(tokenId);
            binderData.safeTransferFrom(owner, clone, tokenId);
            binderData.startActivity(tokenId, BinderIds.ACTIVITY_BATTLE, 0);
            binderData.registerBattleProxy(tokenId, clone);
        }
        emit BattleCreated(
            clone, invitationId, invitation.mapId, map.version, address(book0fArts), address(book0fRealms), count
        );
        return clone;
    }

    function _storeParty(
        uint256 invitationId,
        PartySubmission storage destination,
        PartySubmission calldata party,
        address participant
    ) internal {
        if (destination.submitted) revert PartyAlreadySubmitted(invitationId, participant);
        uint256 count = party.tokenIds.length;
        if (count == 0 || count > 6) revert InvalidBattleParticipantCount(count);
        if (party.spawnTileIds.length != count || party.selectedArtIds.length != count) revert MismatchedBattleInputs();

        IBinderData binderData = IBinderData(centralConsole.binderData());
        for (uint256 index; index < count; ++index) {
            uint256 tokenId = party.tokenIds[index];
            address owner = binderData.ownerOf(tokenId);
            if (owner != participant) {
                revert InvitationTokenOwnerMismatch(invitationId, tokenId, participant, owner);
            }
            for (uint256 priorIndex; priorIndex < index; ++priorIndex) {
                if (party.tokenIds[priorIndex] == tokenId) revert DuplicateInvitationToken(invitationId, tokenId);
            }
            destination.tokenIds.push(tokenId);
            destination.spawnTileIds.push(party.spawnTileIds[index]);
            destination.selectedArtIds.push();
            for (uint256 artIndex; artIndex < party.selectedArtIds[index].length; ++artIndex) {
                destination.selectedArtIds[index].push(party.selectedArtIds[index][artIndex]);
            }
        }
        destination.submitted = true;
    }

    function _validateDistinctParties(uint256 invitationId) internal view {
        PartySubmission storage challengerParty = _challengerParties[invitationId];
        PartySubmission storage opponentParty = _opponentParties[invitationId];
        for (uint256 challengerIndex; challengerIndex < challengerParty.tokenIds.length; ++challengerIndex) {
            uint256 tokenId = challengerParty.tokenIds[challengerIndex];
            for (uint256 opponentIndex; opponentIndex < opponentParty.tokenIds.length; ++opponentIndex) {
                if (tokenId == opponentParty.tokenIds[opponentIndex]) {
                    revert DuplicateInvitationToken(invitationId, tokenId);
                }
            }
        }
    }

    function _validatePartyForEscrow(
        uint256 invitationId,
        PartySubmission storage party,
        address participant,
        IBinderData binderData
    ) internal view {
        for (uint256 index; index < party.tokenIds.length; ++index) {
            uint256 tokenId = party.tokenIds[index];
            address owner = binderData.ownerOf(tokenId);
            if (owner != participant) {
                revert InvitationTokenOwnerMismatch(invitationId, tokenId, participant, owner);
            }
            binderStructs.UnitStateView memory state = binderData.getUnitState(tokenId);
            if (!state.idle || !state.readyToArm) revert InvitationTokenNotReady(invitationId, tokenId);
            if (binderData.getApproved(tokenId) != address(this) && !binderData.isApprovedForAll(owner, address(this)))
            {
                revert BattleTransferNotApproved(invitationId, tokenId, owner);
            }
        }
    }

    function _combineTokenIds(PartySubmission storage challengerParty, PartySubmission storage opponentParty)
        internal
        view
        returns (uint256[] memory tokenIds)
    {
        uint256 challengerCount = challengerParty.tokenIds.length;
        tokenIds = new uint256[](challengerCount + opponentParty.tokenIds.length);
        for (uint256 index; index < challengerCount; ++index) {
            tokenIds[index] = challengerParty.tokenIds[index];
        }
        for (uint256 index; index < opponentParty.tokenIds.length; ++index) {
            tokenIds[challengerCount + index] = opponentParty.tokenIds[index];
        }
    }

    function _combineSpawnTileIds(PartySubmission storage challengerParty, PartySubmission storage opponentParty)
        internal
        view
        returns (uint16[] memory spawnTileIds)
    {
        uint256 challengerCount = challengerParty.spawnTileIds.length;
        spawnTileIds = new uint16[](challengerCount + opponentParty.spawnTileIds.length);
        for (uint256 index; index < challengerCount; ++index) {
            spawnTileIds[index] = challengerParty.spawnTileIds[index];
        }
        for (uint256 index; index < opponentParty.spawnTileIds.length; ++index) {
            spawnTileIds[challengerCount + index] = opponentParty.spawnTileIds[index];
        }
    }

    function _combineSelectedArtIds(PartySubmission storage challengerParty, PartySubmission storage opponentParty)
        internal
        view
        returns (uint32[][] memory selectedArtIds)
    {
        uint256 challengerCount = challengerParty.selectedArtIds.length;
        selectedArtIds = new uint32[][](challengerCount + opponentParty.selectedArtIds.length);
        for (uint256 index; index < challengerCount; ++index) {
            selectedArtIds[index] = challengerParty.selectedArtIds[index];
        }
        for (uint256 index; index < opponentParty.selectedArtIds.length; ++index) {
            selectedArtIds[challengerCount + index] = opponentParty.selectedArtIds[index];
        }
    }

    function _getInvitation(uint256 invitationId) internal view returns (BattleInvitation storage invitation) {
        invitation = _battleInvitations[invitationId];
        if (invitation.challenger == address(0)) revert UnknownBattleInvitation(invitationId);
    }

    function _requireActiveInvitation(uint256 invitationId)
        internal
        view
        returns (BattleInvitation storage invitation)
    {
        invitation = _getInvitation(invitationId);
        if (invitation.cancelled) revert BattleInvitationWasCancelled(invitationId);
        if (block.timestamp >= invitation.expiresAt) revert BattleInvitationExpired(invitationId, invitation.expiresAt);
    }

    /// @notice Ends Battle activity only for an official clone currently escrowed by itself.
    /// @dev Old factories intentionally keep this exit path after CentralConsole points new matches at a replacement factory.
    function endBattle(uint256[] calldata tokenIds) external override {
        if (!isBattleProxy[msg.sender]) revert InvalidBattleProxy(msg.sender);
        IBinderData binderData = IBinderData(centralConsole.binderData());
        for (uint256 index; index < tokenIds.length; ++index) {
            uint256 tokenId = tokenIds[index];
            address owner = binderData.ownerOf(tokenId);
            if (owner != msg.sender) revert BattleTokenNotEscrowed(tokenId, msg.sender, owner);
            uint8 activityId = binderData.getUnitState(tokenId).activity.activityId;
            if (activityId != BinderIds.ACTIVITY_BATTLE) revert BattleActivityMismatch(tokenId, activityId);
            binderData.endBattleActivity(tokenId, msg.sender);
            emit BattleActivityEnded(msg.sender, tokenId);
        }
    }

    function _requireCanonicalFactory() internal view {
        address canonicalFactory = centralConsole.battleFactory();
        if (canonicalFactory != address(this)) revert NotCanonicalBattleFactory(canonicalFactory, address(this));
    }
}
