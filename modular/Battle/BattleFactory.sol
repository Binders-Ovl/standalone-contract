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
    struct BattleRequest {
        uint32 mapId;
        uint256[] tokenIds;
        uint16[] spawnTileIds;
        uint32[][] selectedArtIds;
    }

    bytes32 public constant CONFIG_ROLE = keccak256("CONFIG_ROLE");

    ICentralConsole public immutable centralConsole;
    address public immutable battleImplementation;
    mapping(address => bool) public override isBattleProxy;

    event BattleCreated(
        address indexed battleProxy,
        uint32 indexed mapId,
        uint16 indexed mapVersion,
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
    error BattleTokenNotEscrowed(uint256 tokenId, address expectedProxy, address actualOwner);
    error BattleActivityMismatch(uint256 tokenId, uint8 activityId);

    constructor(address initialAdmin, address centralConsoleAddress, address battleImplementationAddress) {
        if (initialAdmin == address(0) || centralConsoleAddress.code.length == 0) {
            revert InvalidInitialOwner(initialAdmin);
        }
        if (battleImplementationAddress.code.length == 0) revert InvalidBattleImplementation(battleImplementationAddress);
        centralConsole = ICentralConsole(centralConsoleAddress);
        battleImplementation = battleImplementationAddress;
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(CONFIG_ROLE, initialAdmin);
    }

    /// @notice Creates and escrows a bounded official match using only CentralConsole modules.
    /// @dev All participants must have approved this factory for their BinderData NFT.
    function createBattle(BattleRequest calldata request) external returns (address battleProxy) {
        _requireCanonicalFactory();
        uint256 count = request.tokenIds.length;
        if (count < 2 || count > BinderIds.MAX_BATTLE_PARTICIPANTS) revert InvalidBattleParticipantCount(count);
        if (request.spawnTileIds.length != count || request.selectedArtIds.length != count) revert MismatchedBattleInputs();

        IBinderData binderData = IBinderData(centralConsole.binderData());
        if (binderData.getActivityController(BinderIds.ACTIVITY_BATTLE) != address(this)) {
            revert BattleActivityGatewayNotConfigured(binderData.getActivityController(BinderIds.ACTIVITY_BATTLE));
        }

        IBook0fArts book0fArts = IBook0fArts(centralConsole.book0fArts());
        IBook0fRealms book0fRealms = IBook0fRealms(centralConsole.book0fRealms());
        binderStructs.MapDefinition memory map = book0fRealms.getMap(request.mapId);
        if (!map.enabled) revert InvalidBattleProxy(address(0));

        address clone = Clones.clone(battleImplementation);
        isBattleProxy[clone] = true;
        BattleProxy.InitializationParams memory params;
        params.factoryAddress = address(this);
        params.binderDataAddress = address(binderData);
        params.binderSkillsAddress = centralConsole.binderSkills();
        params.book0fArtsAddress = address(book0fArts);
        params.book0fRealmsAddress = address(book0fRealms);
        params.requestedMapId = request.mapId;
        params.requestedMapVersion = map.version;
        params.tokenIds = request.tokenIds;
        params.spawnTileIds = request.spawnTileIds;
        params.selectedArtIds = request.selectedArtIds;
        BattleProxy(clone).initialize(params);

        for (uint256 index; index < count; ++index) {
            uint256 tokenId = request.tokenIds[index];
            address owner = binderData.ownerOf(tokenId);
            binderData.safeTransferFrom(owner, clone, tokenId);
            binderData.startActivity(tokenId, BinderIds.ACTIVITY_BATTLE, 0);
            binderData.registerBattleProxy(tokenId, clone);
        }
        emit BattleCreated(clone, request.mapId, map.version, address(book0fArts), address(book0fRealms), count);
        return clone;
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
            binderData.clearBattleProxy(tokenId, msg.sender);
            binderData.endActivity(tokenId);
            emit BattleActivityEnded(msg.sender, tokenId);
        }
    }

    function _requireCanonicalFactory() internal view {
        address canonicalFactory = centralConsole.battleFactory();
        if (canonicalFactory != address(this)) revert NotCanonicalBattleFactory(canonicalFactory, address(this));
    }
}
