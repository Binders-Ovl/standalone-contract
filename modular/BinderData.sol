// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-4.8/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts-4.8/token/ERC721/extensions/ERC721Pausable.sol";
import "@openzeppelin/contracts-4.8/access/Ownable.sol";
import "@openzeppelin/contracts-4.8/access/AccessControl.sol";
import "@openzeppelin/contracts-4.8/utils/Strings.sol";
import "./supportContract/binderIds.sol";
import "./supportContract/binderStructs.sol";
import "./interfaces/IBinderMetadata.sol";
import "./interfaces/IBattleFactory.sol";

/// @notice ERC-721 NFT-instance database and authoritative activity/transfer state.
contract BinderData is ERC721, ERC721Pausable, Ownable, AccessControl {
    bytes32 public constant CONFIG_ROLE = keccak256("CONFIG_ROLE");
    bytes32 public constant BATTLE_ROLE = keccak256("BATTLE_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant FUSION_ROLE = keccak256("FUSION_ROLE");
    bytes32 public constant METADATA_REFRESH_ROLE = keccak256("METADATA_REFRESH_ROLE");
    bytes4 public constant ERC4906_INTERFACE_ID = 0x49064906;

    error InvalidUriFormat();
    error MaxSupplyReached();
    error InvalidToken(uint256 tokenId);
    error AlreadyUpgraded();
    error NotDeadYet();
    error BinderMetadataNotSet();
    error InvalidClassId();
    error InvalidNewVersionTooHigh();
    error GraveyardNotSet();
    error GraveyardAlreadyConfigured(address configuredGraveyard);
    error TokenBusy(uint256 tokenId, uint8 activityId);
    error UnitNotReadyToArm(uint256 tokenId);
    error UnitAlreadyIdle(uint256 tokenId);
    error InvalidActivityId(uint8 activityId);
    error ActivityControllerNotSet(uint8 activityId);
    error UnauthorizedActivityController(uint8 activityId, address caller);
    error TokenInGraveyard(uint256 tokenId);
    error UnauthorizedGraveyardTransfer(uint256 tokenId);
    error UnauthorizedResurrection(address caller);
    error TokenNotInGraveyard(uint256 tokenId, address actualOwner);
    error InvalidResurrectionRecipient(address recipient);
    error InvalidResurrectionVitals(uint256 tokenId, uint16 currentHP, uint16 currentMP, uint16 maxHP, uint16 maxMP);
    error InvalidBattleFactory(address factory);
    error BattleFactoryHasActiveEscrows(address factory, uint256 activeCount);
    error UnauthorizedBattleFactory(address caller);
    error InvalidBattleProxyRegistration(address battleProxy);
    error BattleProxyMismatch(uint256 tokenId, address expectedProxy, address actualProxy);
    error BattleTokenNotEscrowed(uint256 tokenId, address expectedProxy, address actualOwner);
    error BattleActivityRequired(uint256 tokenId, uint8 activityId);
    error InvalidBattleVitalsInput();
    error StaleBattleCheckpoint(uint256 tokenId, uint32 currentNonce, uint32 providedNonce);
    error BattleVitalsExceedMaximum(uint256 tokenId, uint16 currentHP, uint16 currentMP, uint16 maxHP, uint16 maxMP);
    error ActiveBattleBinding(uint256 tokenId, address battleProxy);
    error ActiveFusionBinding(uint256 tokenId, address fusionMinter);
    error UnauthorizedFusionMinter(address minter);
    error UnauthorizedBinderLogic(address logic);
    error FusionMinterHasActiveEscrows(address minter, uint256 activeCount);
    error TokenNotEscrowedForFusion(uint256 tokenId, address expectedMinter, address actualOwner);
    error InvalidPermanentMetadata(uint256 classId, uint8 rarityId, uint16 configVersion);
    error InvalidPermanentVitals(uint16 currentHP, uint16 currentMP, uint16 maxHP, uint16 maxMP);

    uint256 public maxSupply = 1_000_000;
    uint128 internal supplyBuffer = 125;
    uint256 internal supplyIncrement = 10_000;
    uint128 private _tokenIdCounter = 1;

    string public baseImageURI;
    address public binderGraveyard;
    address public binderMetadataAddress;
    bool public battleCheckpointMetadataEnabled;

    /// @dev An outgoing factory stays authorized only until its registered
    /// fixed-code matches settle, enabling safe factory replacement.
    mapping(address => bool) public authorizedBattleFactory;
    mapping(address => uint256) public activeBattleCountByFactory;
    mapping(address => address) public battleProxyFactory;
    mapping(uint256 => address) public activeBattleProxy;
    mapping(uint256 => uint32) public battleCheckpointNonce;

    /// @dev Fusion custody is bound to the minter that started it so an
    /// outgoing minter can finish/rescue pending requests after a cutover.
    mapping(address => bool) public authorizedFusionMinter;
    mapping(address => uint256) public activeFusionCountByMinter;
    mapping(uint256 => address) public activeFusionMinter;
    mapping(address => bool) public authorizedBinderLogic;

    mapping(uint256 => binderStructs.NFTMetadata) private _tokenMetadata;
    mapping(uint256 => uint16) public classVersion;
    mapping(uint256 => binderStructs.ActivityState) private _activityState;
    mapping(uint8 => address) private _activityController;
    bool private _graveyardTransferInProgress;
    bool private _resurrectionTransferInProgress;
    bool private _permanentBurnInProgress;

    event NFTMinted(address indexed owner, uint256 tokenId, uint8 rarityId, string rarity, string className);
    event NFTFusionMinted(address indexed owner, uint256 tokenId, uint8 rarityId, string rarity, string className);
    event SupplyAdded(uint256 indexed amount);
    event NFTStatsUpdated(uint256 indexed tokenId, uint8[8] newStats, uint16 latestVersion);
    event ActivityControllerUpdated(
        uint8 indexed activityId, address indexed oldController, address indexed newController
    );
    event ActivityStarted(uint256 indexed tokenId, uint8 indexed activityId, uint48 lockedUntil);
    event ActivityEnded(uint256 indexed tokenId, uint8 indexed activityId);
    event ActivityForceCleared(uint256 indexed tokenId, uint8 indexed activityId, address indexed admin);
    event ActivityClearedForGraveyard(uint256 indexed tokenId, uint8 indexed activityId);
    event GraveyardConfigured(address indexed graveyard);
    event BinderSentToGraveyard(uint256 indexed tokenId, address indexed previousOwner, address indexed graveyard);
    event BinderResurrected(uint256 indexed tokenId, address indexed recipient, uint16 currentHP, uint16 currentMP);
    event BinderPermanentlyBurned(uint256 indexed tokenId, address indexed graveyard, address indexed admin);
    event MetadataUpdate(uint256 tokenId);
    event BatchMetadataUpdate(uint256 fromTokenId, uint256 toTokenId);
    event BattleFactoryAuthorizationUpdated(address indexed factory, bool authorized);
    event BattleProxyRegistered(uint256 indexed tokenId, address indexed battleProxy, address indexed factory);
    event BattleProxyCleared(uint256 indexed tokenId, address indexed battleProxy, address indexed factory);
    event BattleVitalsCheckpointed(
        uint256 indexed tokenId, address indexed battleProxy, uint16 currentHP, uint16 currentMP, uint32 nonce
    );
    event BattleVitalsSettled(
        uint256 indexed tokenId, address indexed battleProxy, uint16 currentHP, uint16 currentMP, uint32 nonce
    );
    event AdminPersistentVitalsUpdated(
        uint256 indexed tokenId, uint16 currentHP, uint16 currentMP, address indexed admin
    );
    event FusionMinterAuthorizationUpdated(address indexed minter, bool authorized);
    event FusionActivityRegistered(uint256 indexed tokenId, address indexed fusionMinter);
    event FusionActivityCleared(uint256 indexed tokenId, address indexed fusionMinter);
    event BinderLogicAuthorizationUpdated(address indexed logic, bool authorized);

    constructor(address initialOwner, string memory newBaseImageURI) ERC721("Binders", "UBIND") {
        if (bytes(newBaseImageURI).length > 0 && bytes(newBaseImageURI)[bytes(newBaseImageURI).length - 1] != "/") {
            revert InvalidUriFormat();
        }
        require(initialOwner != address(0), "Invalid owner");
        baseImageURI = newBaseImageURI;
        transferOwnership(initialOwner);
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
        _grantRole(CONFIG_ROLE, initialOwner);
        _grantRole(BATTLE_ROLE, initialOwner);
        _grantRole(MINTER_ROLE, initialOwner);
        _grantRole(FUSION_ROLE, initialOwner);
        _grantRole(METADATA_REFRESH_ROLE, initialOwner);
    }

    // === Minting ===

    function _mintNFT(address recipient, binderStructs.NFTMetadata memory metadata) internal returns (uint256) {
        if (_tokenIdCounter > maxSupply) revert MaxSupplyReached();
        if (maxSupply - _tokenIdCounter <= supplyBuffer) {
            maxSupply += supplyIncrement;
            emit SupplyAdded(supplyIncrement);
        }

        uint256 tokenId = _tokenIdCounter++;
        _safeMint(recipient, tokenId);
        metadata.name = string(abi.encodePacked(metadata.name, "#", Strings.toString(tokenId)));
        _tokenMetadata[tokenId] = metadata;
        return tokenId;
    }

    function _buildMintMetadata(
        uint256 classId,
        string memory className,
        uint8 rarityId,
        binderStructs.StaticStats memory staticStats,
        binderStructs.DynamicStats memory dynamicStats
    ) internal view returns (binderStructs.NFTMetadata memory) {
        return binderStructs.NFTMetadata({
            name: className,
            classId: classId,
            rarityId: rarityId,
            staticStats: staticStats,
            dynamicStats: dynamicStats,
            configVersion: classVersion[classId]
        });
    }

    function _mintRandomNFT(
        address recipient,
        uint256 classId,
        string memory className,
        uint8 rarityId,
        string memory rarityName,
        binderStructs.StaticStats memory staticStats,
        binderStructs.DynamicStats memory dynamicStats
    ) external returns (uint256) {
        _requireMinterAuthority(msg.sender);
        _validatePermanentMetadata(classId, rarityId, staticStats, dynamicStats);
        uint256 tokenId =
            _mintNFT(recipient, _buildMintMetadata(classId, className, rarityId, staticStats, dynamicStats));
        emit NFTMinted(recipient, tokenId, rarityId, rarityName, className);
        return tokenId;
    }

    function _mint4Fusion(
        address recipient,
        uint256 classId,
        string memory className,
        uint8 rarityId,
        string memory rarityName,
        binderStructs.StaticStats memory staticStats,
        binderStructs.DynamicStats memory dynamicStats
    ) external returns (uint256) {
        _requireFusionAuthority(msg.sender);
        _validatePermanentMetadata(classId, rarityId, staticStats, dynamicStats);
        uint256 tokenId =
            _mintNFT(recipient, _buildMintMetadata(classId, className, rarityId, staticStats, dynamicStats));
        emit NFTFusionMinted(recipient, tokenId, rarityId, rarityName, className);
        return tokenId;
    }

    // === Authoritative activity state ===

    /// @notice Starts an activity for an Idle, current-version Binder.
    /// @dev Soft activities retain player ownership. Custody activities must transfer
    /// player -> controller first while Idle, then call this in the same transaction.
    function startActivity(uint256 tokenId, uint8 activityId, uint48 lockedUntil) external {
        _requireActivityController(activityId, msg.sender);
        _requireCanStartActivity(tokenId);
        _activityState[tokenId] = binderStructs.ActivityState({activityId: activityId, lockedUntil: lockedUntil});
        if (activityId == BinderIds.ACTIVITY_FUSION) {
            if (!authorizedFusionMinter[msg.sender] || ownerOf(tokenId) != msg.sender) {
                revert UnauthorizedFusionMinter(msg.sender);
            }
            activeFusionMinter[tokenId] = msg.sender;
            activeFusionCountByMinter[msg.sender] += 1;
            emit FusionActivityRegistered(tokenId, msg.sender);
        }
        emit ActivityStarted(tokenId, activityId, lockedUntil);
        _emitMetadataUpdate(tokenId);
    }

    /// @notice Ends the caller's currently active activity. ReadyToArm is intentionally not checked on exit.
    /// @dev Custody activities must call this before custody -> player transfer in the same transaction.
    function endActivity(uint256 tokenId) external {
        _requireToken(tokenId);
        uint8 activityId = _activityState[tokenId].activityId;
        if (activityId == 0) revert UnitAlreadyIdle(tokenId);
        address battleProxy = activeBattleProxy[tokenId];
        if (battleProxy != address(0)) revert ActiveBattleBinding(tokenId, battleProxy);
        address fusionMinter = activeFusionMinter[tokenId];
        if (fusionMinter != address(0)) revert ActiveFusionBinding(tokenId, fusionMinter);
        _requireActivityController(activityId, msg.sender);
        delete _activityState[tokenId];
        emit ActivityEnded(tokenId, activityId);
        _emitMetadataUpdate(tokenId);
    }

    /// @notice Emergency recovery for an abandoned or faulty activity controller.
    function forceClearActivity(uint256 tokenId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _requireToken(tokenId);
        uint8 activityId = _activityState[tokenId].activityId;
        if (activityId == 0) revert UnitAlreadyIdle(tokenId);
        address battleProxy = activeBattleProxy[tokenId];
        if (battleProxy != address(0)) revert ActiveBattleBinding(tokenId, battleProxy);
        address fusionMinter = activeFusionMinter[tokenId];
        if (fusionMinter != address(0)) revert ActiveFusionBinding(tokenId, fusionMinter);
        delete _activityState[tokenId];
        emit ActivityForceCleared(tokenId, activityId, msg.sender);
        _emitMetadataUpdate(tokenId);
    }

    function setActivityController(uint8 activityId, address controller) external onlyRole(CONFIG_ROLE) {
        if (activityId == 0) revert InvalidActivityId(activityId);
        if (controller == address(0)) revert ActivityControllerNotSet(activityId);
        address oldController = _activityController[activityId];
        _activityController[activityId] = controller;
        emit ActivityControllerUpdated(activityId, oldController, controller);
    }

    // === Version/stat updates ===

    /// @dev Defense in depth: a CONFIG_ROLE holder cannot reroll an active Binder.
    function updateNFTStats(
        uint256 tokenId,
        binderStructs.StaticStats calldata stats,
        binderStructs.DynamicStats calldata dynamicStats
    ) external onlyRole(CONFIG_ROLE) {
        _requireToken(tokenId);
        if (!_isIdle(tokenId)) revert TokenBusy(tokenId, _activityState[tokenId].activityId);

        binderStructs.NFTMetadata storage meta = _tokenMetadata[tokenId];
        uint16 latestVersion = classVersion[meta.classId];
        if (meta.configVersion >= latestVersion) revert AlreadyUpgraded();
        _validatePermanentMetadata(meta.classId, meta.rarityId, stats, dynamicStats);

        meta.staticStats = stats;
        meta.dynamicStats = dynamicStats;
        meta.configVersion = latestVersion;
        emit NFTStatsUpdated(tokenId, stats.stats, latestVersion);
        _emitMetadataUpdate(tokenId);
    }

    /// @notice Explicit development/emergency update for a persistent, non-Battle Binder.
    /// @dev Official BattleProxy vitals use provenance-checked checkpoint paths;
    /// this function must never mutate an active match behind its proxy's back.
    function adminUpdatePersistentVitals(uint256 tokenId, uint16 currentHP, uint16 currentMP)
        external
        onlyRole(BATTLE_ROLE)
    {
        _requireToken(tokenId);
        address battleProxy = activeBattleProxy[tokenId];
        if (battleProxy != address(0)) revert ActiveBattleBinding(tokenId, battleProxy);
        if (!_isIdle(tokenId)) revert TokenBusy(tokenId, _activityState[tokenId].activityId);
        if (binderGraveyard != address(0) && ownerOf(tokenId) == binderGraveyard) revert TokenInGraveyard(tokenId);
        binderStructs.NFTMetadata storage meta = _tokenMetadata[tokenId];
        meta.dynamicStats.currentHP = currentHP > meta.dynamicStats.maxHP ? meta.dynamicStats.maxHP : currentHP;
        meta.dynamicStats.currentMP = currentMP > meta.dynamicStats.maxMP ? meta.dynamicStats.maxMP : currentMP;
        emit AdminPersistentVitalsUpdated(tokenId, meta.dynamicStats.currentHP, meta.dynamicStats.currentMP, msg.sender);
        if (meta.dynamicStats.currentHP == 0) {
            _autoTransferToGraveyard(tokenId);
        } else {
            _emitMetadataUpdate(tokenId);
        }
    }

    // === Narrow official BattleProxy lifecycle / persistence ===

    /// @notice Approves a Factory to register official BattleProxy escrows.
    /// @dev An outgoing factory cannot be removed until every registered clone
    /// has settled, preserving old fixed-code matches through a factory cutover.
    function setAuthorizedBattleFactory(address factory, bool authorized) external onlyRole(CONFIG_ROLE) {
        if (authorized) {
            if (factory.code.length == 0) revert InvalidBattleFactory(factory);
        } else if (activeBattleCountByFactory[factory] != 0) {
            revert BattleFactoryHasActiveEscrows(factory, activeBattleCountByFactory[factory]);
        }
        authorizedBattleFactory[factory] = authorized;
        emit BattleFactoryAuthorizationUpdated(factory, authorized);
    }

    /// @notice Approves a FusionMinter to begin custody activities and finish
    /// its own pending requests after a future controller cutover.
    function setAuthorizedFusionMinter(address minter, bool authorized) external onlyRole(CONFIG_ROLE) {
        if (authorized) {
            if (minter.code.length == 0) revert InvalidBattleFactory(minter);
        } else if (activeFusionCountByMinter[minter] != 0) {
            revert FusionMinterHasActiveEscrows(minter, activeFusionCountByMinter[minter]);
        }
        if (!authorized) _revokeRole(FUSION_ROLE, minter);
        authorizedFusionMinter[minter] = authorized;
        emit FusionMinterAuthorizationUpdated(minter, authorized);
    }

    /// @notice Authorizes a BinderLogic mint orchestrator without giving it
    /// general configuration or administrative roles. Outgoing logic remains
    /// authorized until an explicit post-pending-request retirement.
    function setAuthorizedBinderLogic(address logic, bool authorized) external onlyRole(CONFIG_ROLE) {
        if (authorized && logic.code.length == 0) revert InvalidBattleFactory(logic);
        if (!authorized) _revokeRole(MINTER_ROLE, logic);
        authorizedBinderLogic[logic] = authorized;
        emit BinderLogicAuthorizationUpdated(logic, authorized);
    }

    /// @notice Moves the narrow configuration authority used by the canonical
    /// ScaleOfBalance without changing its owner/admin hierarchy.
    function setScaleOfBalanceAuthority(address previousScale, address newScale) external onlyRole(CONFIG_ROLE) {
        _grantRole(CONFIG_ROLE, newScale);
        if (previousScale != newScale) _revokeRole(CONFIG_ROLE, previousScale);
    }

    /// @notice Enables the canonical Factory gateway to bind a just-escrowed NFT to a recognized clone.
    function registerBattleProxy(uint256 tokenId, address battleProxy) external {
        _requireAuthorizedBattleFactory(msg.sender);
        if (!IBattleFactory(msg.sender).isBattleProxy(battleProxy)) revert InvalidBattleProxyRegistration(battleProxy);
        _requireToken(tokenId);
        if (activeBattleProxy[tokenId] != address(0)) {
            revert BattleProxyMismatch(tokenId, address(0), activeBattleProxy[tokenId]);
        }
        address owner = ownerOf(tokenId);
        if (owner != battleProxy) revert BattleTokenNotEscrowed(tokenId, battleProxy, owner);
        uint8 activityId = _activityState[tokenId].activityId;
        if (activityId != BinderIds.ACTIVITY_BATTLE) revert BattleActivityRequired(tokenId, activityId);

        activeBattleProxy[tokenId] = battleProxy;
        // A checkpoint sequence belongs to one official proxy binding, not to
        // the token's lifetime. Every fresh battle starts from its own nonce 0.
        battleCheckpointNonce[tokenId] = 0;
        battleProxyFactory[battleProxy] = msg.sender;
        activeBattleCountByFactory[msg.sender] += 1;
        emit BattleProxyRegistered(tokenId, battleProxy, msg.sender);
    }

    /// @notice Atomically ends a survivor's battle activity and its official
    /// proxy binding. The recorded Factory remains eligible after cutover.
    function endBattleActivity(uint256 tokenId, address battleProxy) external {
        _requireAuthorizedBattleFactory(msg.sender);
        _requireBattleBinding(tokenId, battleProxy, msg.sender);
        address owner = ownerOf(tokenId);
        if (owner != battleProxy) revert BattleTokenNotEscrowed(tokenId, battleProxy, owner);
        uint8 activityId = _activityState[tokenId].activityId;
        if (activityId != BinderIds.ACTIVITY_BATTLE) revert BattleActivityRequired(tokenId, activityId);
        _clearBattleBinding(tokenId, battleProxy, msg.sender);
        delete _activityState[tokenId];
        emit ActivityEnded(tokenId, activityId);
        _emitMetadataUpdate(tokenId);
    }

    /// @notice Atomically ends the Fusion activity owned by the minter that
    /// originally took custody. It intentionally bypasses the current starter
    /// controller so pending pre-cutover requests can be rescued safely.
    function endFusionActivity(uint256 tokenId) external {
        _requireToken(tokenId);
        address fusionMinter = activeFusionMinter[tokenId];
        if (fusionMinter != msg.sender) revert ActiveFusionBinding(tokenId, fusionMinter);
        if (ownerOf(tokenId) != msg.sender) revert TokenNotEscrowedForFusion(tokenId, msg.sender, ownerOf(tokenId));
        uint8 activityId = _activityState[tokenId].activityId;
        if (activityId != BinderIds.ACTIVITY_FUSION) revert BattleActivityRequired(tokenId, activityId);
        _clearFusionBinding(tokenId, fusionMinter);
        delete _activityState[tokenId];
        emit ActivityEnded(tokenId, activityId);
        _emitMetadataUpdate(tokenId);
    }

    /// @notice Persists only dirty HP/MP values produced by their recognized live BattleProxy.
    /// @dev A zero-HP unit remains in battle custody during pulses; graveyard handling is final-settlement only.
    function checkpointBattleVitals(
        uint256[] calldata tokenIds,
        uint16[] calldata hpValues,
        uint16[] calldata mpValues,
        uint32 checkpointNonce
    ) external {
        _validateBattleVitalsInput(tokenIds, hpValues, mpValues);
        for (uint256 index; index < tokenIds.length; ++index) {
            _validateBattleCheckpoint(tokenIds[index], msg.sender, checkpointNonce, hpValues[index], mpValues[index]);
        }
        for (uint256 index; index < tokenIds.length; ++index) {
            uint256 tokenId = tokenIds[index];
            _writeBattleVitals(tokenId, hpValues[index], mpValues[index], checkpointNonce);
            emit BattleVitalsCheckpointed(tokenId, msg.sender, hpValues[index], mpValues[index], checkpointNonce);
            if (battleCheckpointMetadataEnabled) _emitMetadataUpdate(tokenId);
        }
    }

    /// @notice Commits final local vitals; zero-HP units move to the graveyard here, never at ordinary pulse time.
    function settleBattleVitals(
        uint256[] calldata tokenIds,
        uint16[] calldata hpValues,
        uint16[] calldata mpValues,
        uint32 checkpointNonce
    ) external {
        _validateBattleVitalsInput(tokenIds, hpValues, mpValues);
        for (uint256 index; index < tokenIds.length; ++index) {
            _validateBattleCheckpoint(tokenIds[index], msg.sender, checkpointNonce, hpValues[index], mpValues[index]);
        }
        for (uint256 index; index < tokenIds.length; ++index) {
            uint256 tokenId = tokenIds[index];
            _writeBattleVitals(tokenId, hpValues[index], mpValues[index], checkpointNonce);
            emit BattleVitalsSettled(tokenId, msg.sender, hpValues[index], mpValues[index], checkpointNonce);
            if (hpValues[index] == 0) {
                address factory = battleProxyFactory[msg.sender];
                _clearBattleBinding(tokenId, msg.sender, factory);
                _moveToGraveyard(tokenId);
            } else if (battleCheckpointMetadataEnabled) {
                _emitMetadataUpdate(tokenId);
            }
        }
    }

    // === Graveyard ===

    function _autoTransferToGraveyard(uint256 tokenId) internal {
        if (_tokenMetadata[tokenId].dynamicStats.currentHP != 0) revert NotDeadYet();
        _moveToGraveyard(tokenId);
    }

    /// @notice Explicit fusion retirement path.
    function tfToGraveyard(uint256 tokenId) external {
        _requireFusionAuthority(msg.sender);
        _requireToken(tokenId);
        address battleProxy = activeBattleProxy[tokenId];
        if (battleProxy != address(0)) revert ActiveBattleBinding(tokenId, battleProxy);
        address fusionMinter = activeFusionMinter[tokenId];
        if (fusionMinter != msg.sender) revert ActiveFusionBinding(tokenId, fusionMinter);
        if (ownerOf(tokenId) != msg.sender) revert TokenNotEscrowedForFusion(tokenId, msg.sender, ownerOf(tokenId));
        _clearFusionBinding(tokenId, fusionMinter);
        _moveToGraveyard(tokenId);
    }

    function _moveToGraveyard(uint256 tokenId) internal {
        if (binderGraveyard == address(0)) revert GraveyardNotSet();
        address battleProxy = activeBattleProxy[tokenId];
        if (battleProxy != address(0)) revert ActiveBattleBinding(tokenId, battleProxy);
        uint8 activityId = _activityState[tokenId].activityId;
        if (activityId != 0) {
            delete _activityState[tokenId];
            emit ActivityClearedForGraveyard(tokenId, activityId);
            _emitMetadataUpdate(tokenId);
        }

        _graveyardTransferInProgress = true;
        address previousOwner = ownerOf(tokenId);
        _transfer(previousOwner, binderGraveyard, tokenId);
        _graveyardTransferInProgress = false;
        emit BinderSentToGraveyard(tokenId, previousOwner, binderGraveyard);
    }

    /// @notice Releases one dead Binder only through the configured Graveyard's
    /// validated game-rule flow, atomically restoring nonzero bounded vitals.
    function resurrectFromGraveyard(uint256 tokenId, address recipient, uint16 currentHP, uint16 currentMP) external {
        if (binderGraveyard == address(0)) revert GraveyardNotSet();
        if (msg.sender != binderGraveyard) revert UnauthorizedResurrection(msg.sender);
        if (recipient == address(0) || recipient == binderGraveyard) revert InvalidResurrectionRecipient(recipient);
        _requireToken(tokenId);
        address owner = ownerOf(tokenId);
        if (owner != binderGraveyard) revert TokenNotInGraveyard(tokenId, owner);

        binderStructs.DynamicStats storage dynamicStats = _tokenMetadata[tokenId].dynamicStats;
        if (currentHP == 0 || currentHP > dynamicStats.maxHP || currentMP > dynamicStats.maxMP) {
            revert InvalidResurrectionVitals(tokenId, currentHP, currentMP, dynamicStats.maxHP, dynamicStats.maxMP);
        }
        dynamicStats.currentHP = currentHP;
        dynamicStats.currentMP = currentMP;
        _resurrectionTransferInProgress = true;
        _transfer(binderGraveyard, recipient, tokenId);
        _resurrectionTransferInProgress = false;
        emit BinderResurrected(tokenId, recipient, currentHP, currentMP);
        _emitMetadataUpdate(tokenId);
    }

    /// @notice Irreversibly removes a Binder already held in Graveyard custody.
    /// @dev This is deliberately distinct from the reversible resurrection flow.
    function burnGraveyardedBinder(uint256 tokenId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (binderGraveyard == address(0)) revert GraveyardNotSet();
        _requireToken(tokenId);
        address owner = ownerOf(tokenId);
        if (owner != binderGraveyard) revert TokenNotInGraveyard(tokenId, owner);
        _permanentBurnInProgress = true;
        _burn(tokenId);
        _permanentBurnInProgress = false;
        emit BinderPermanentlyBurned(tokenId, binderGraveyard, msg.sender);
    }

    // === ERC-721 metadata entrypoint ===

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireToken(tokenId);
        if (binderMetadataAddress == address(0)) revert BinderMetadataNotSet();
        return IBinderMetadata(binderMetadataAddress).tokenURI(tokenId);
    }

    // === Consolidated views ===

    function getUnitState(uint256 tokenId) external view returns (binderStructs.UnitStateView memory) {
        _requireToken(tokenId);
        return binderStructs.UnitStateView({
            readyToArm: _isReadyToArm(tokenId),
            idle: _isIdle(tokenId),
            transferable: _isProtocolTransferable(tokenId),
            activity: _activityState[tokenId]
        });
    }

    function getNFTClass(uint256 tokenId) external view returns (uint256) {
        _requireToken(tokenId);
        return _tokenMetadata[tokenId].classId;
    }

    function getNFTRarityId(uint256 tokenId) external view returns (uint8) {
        _requireToken(tokenId);
        return _tokenMetadata[tokenId].rarityId;
    }

    function getConfigVersion(uint256 tokenId) external view returns (uint16) {
        _requireToken(tokenId);
        return _tokenMetadata[tokenId].configVersion;
    }

    function getNFTDetails(uint256 tokenId) external view returns (binderStructs.NFTMetadata memory) {
        _requireToken(tokenId);
        return _tokenMetadata[tokenId];
    }

    function getActivityController(uint8 activityId) external view returns (address) {
        return _activityController[activityId];
    }

    // === Administration ===

    function setBinderMetadata(address metadataAddress) external onlyRole(CONFIG_ROLE) {
        if (metadataAddress == address(0) || metadataAddress.code.length == 0) revert BinderMetadataNotSet();
        binderMetadataAddress = metadataAddress;
        _emitAllMetadataUpdate();
    }

    /// @notice Rotates the narrowly scoped metadata-refresh authority used by
    /// the canonical BinderSkills proxy without granting it CONFIG_ROLE.
    function setMetadataRefreshModule(address previousModule, address newModule) external onlyRole(CONFIG_ROLE) {
        if (newModule == address(0) || newModule.code.length == 0) revert BinderMetadataNotSet();
        if (previousModule != address(0) && previousModule != newModule) {
            _revokeRole(METADATA_REFRESH_ROLE, previousModule);
        }
        _grantRole(METADATA_REFRESH_ROLE, newModule);
    }

    function setBaseImageURI(string memory newURI) external onlyOwner {
        if (bytes(newURI).length > 0 && bytes(newURI)[bytes(newURI).length - 1] != "/") revert InvalidUriFormat();
        baseImageURI = newURI;
        _emitAllMetadataUpdate();
    }

    function setGraveyard(address graveyard) external onlyOwner {
        if (graveyard == address(0)) revert GraveyardNotSet();
        if (binderGraveyard != address(0)) revert GraveyardAlreadyConfigured(binderGraveyard);
        binderGraveyard = graveyard;
        emit GraveyardConfigured(graveyard);
        _emitAllMetadataUpdate();
    }

    function setClassVersion(uint256 classId, uint16 version) external onlyRole(CONFIG_ROLE) {
        if (classId == 0) revert InvalidClassId();
        if (version <= classVersion[classId]) revert InvalidNewVersionTooHigh();
        classVersion[classId] = version;
        _emitAllMetadataUpdate();
    }

    /// @notice Signals presentation changes made in dependent configuration contracts, e.g. rarity/activity labels.
    function refreshAllMetadata() external onlyRole(CONFIG_ROLE) {
        _emitAllMetadataUpdate();
    }

    /// @notice Enables ERC-4906 events for coarse official battle checkpoints.
    /// @dev The official proxy pulse path remains opt-in to avoid high-frequency metadata spam.
    function setBattleCheckpointMetadataEnabled(bool enabled) external onlyRole(CONFIG_ROLE) {
        battleCheckpointMetadataEnabled = enabled;
    }

    /// @notice Emits a narrowly authorized ERC-4906 refresh for a dependent module update.
    /// @dev BinderSkills receives this role after canonical pairing so learned-skill changes
    /// can refresh one NFT without receiving CONFIG_ROLE or gameplay write authority.
    function refreshMetadata(uint256 tokenId) external onlyRole(METADATA_REFRESH_ROLE) {
        _requireToken(tokenId);
        _emitMetadataUpdate(tokenId);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // === Internal state / transfer enforcement ===

    function _requireCanStartActivity(uint256 tokenId) internal view {
        _requireToken(tokenId);
        if (!_isIdle(tokenId)) revert TokenBusy(tokenId, _activityState[tokenId].activityId);
        if (!_isReadyToArm(tokenId)) revert UnitNotReadyToArm(tokenId);
        if (binderGraveyard != address(0) && ownerOf(tokenId) == binderGraveyard) revert TokenInGraveyard(tokenId);
    }

    function _requireAuthorizedBattleFactory(address factory) internal view {
        if (!authorizedBattleFactory[factory]) revert UnauthorizedBattleFactory(factory);
    }

    function _requireFusionAuthority(address minter) internal view {
        if (!authorizedFusionMinter[minter]) revert UnauthorizedFusionMinter(minter);
    }

    function _requireMinterAuthority(address logic) internal view {
        if (!authorizedBinderLogic[logic]) revert UnauthorizedBinderLogic(logic);
    }

    function _requireBattleBinding(uint256 tokenId, address battleProxy, address factory) internal view {
        address expectedProxy = activeBattleProxy[tokenId];
        if (expectedProxy != battleProxy) revert BattleProxyMismatch(tokenId, expectedProxy, battleProxy);
        address expectedFactory = battleProxyFactory[battleProxy];
        if (expectedFactory != factory) revert UnauthorizedBattleFactory(factory);
    }

    function _clearFusionBinding(uint256 tokenId, address fusionMinter) internal {
        delete activeFusionMinter[tokenId];
        if (activeFusionCountByMinter[fusionMinter] == 0) revert ActiveFusionBinding(tokenId, fusionMinter);
        activeFusionCountByMinter[fusionMinter] -= 1;
        emit FusionActivityCleared(tokenId, fusionMinter);
    }

    function _clearBattleBinding(uint256 tokenId, address battleProxy, address factory) internal {
        delete activeBattleProxy[tokenId];
        if (activeBattleCountByFactory[factory] == 0) revert UnauthorizedBattleFactory(factory);
        activeBattleCountByFactory[factory] -= 1;
        emit BattleProxyCleared(tokenId, battleProxy, factory);
    }

    function _validateBattleVitalsInput(
        uint256[] calldata tokenIds,
        uint16[] calldata hpValues,
        uint16[] calldata mpValues
    ) internal pure {
        if (
            tokenIds.length == 0 || tokenIds.length > BinderIds.MAX_BATTLE_PARTICIPANTS
                || tokenIds.length != hpValues.length || tokenIds.length != mpValues.length
        ) {
            revert InvalidBattleVitalsInput();
        }
        for (uint256 index; index < tokenIds.length; ++index) {
            for (uint256 comparison = index + 1; comparison < tokenIds.length; ++comparison) {
                if (tokenIds[index] == tokenIds[comparison]) revert InvalidBattleVitalsInput();
            }
        }
    }

    function _validateBattleCheckpoint(
        uint256 tokenId,
        address battleProxy,
        uint32 checkpointNonce,
        uint16 currentHP,
        uint16 currentMP
    ) internal view {
        _requireToken(tokenId);
        address factory = battleProxyFactory[battleProxy];
        _requireAuthorizedBattleFactory(factory);
        _requireBattleBinding(tokenId, battleProxy, factory);
        address owner = ownerOf(tokenId);
        if (owner != battleProxy) revert BattleTokenNotEscrowed(tokenId, battleProxy, owner);
        uint8 activityId = _activityState[tokenId].activityId;
        if (activityId != BinderIds.ACTIVITY_BATTLE) revert BattleActivityRequired(tokenId, activityId);
        uint32 previousNonce = battleCheckpointNonce[tokenId];
        if (checkpointNonce <= previousNonce) revert StaleBattleCheckpoint(tokenId, previousNonce, checkpointNonce);
        binderStructs.DynamicStats storage dynamicStats = _tokenMetadata[tokenId].dynamicStats;
        if (currentHP > dynamicStats.maxHP || currentMP > dynamicStats.maxMP) {
            revert BattleVitalsExceedMaximum(tokenId, currentHP, currentMP, dynamicStats.maxHP, dynamicStats.maxMP);
        }
    }

    function _writeBattleVitals(uint256 tokenId, uint16 currentHP, uint16 currentMP, uint32 checkpointNonce) internal {
        binderStructs.DynamicStats storage dynamicStats = _tokenMetadata[tokenId].dynamicStats;
        dynamicStats.currentHP = currentHP;
        dynamicStats.currentMP = currentMP;
        battleCheckpointNonce[tokenId] = checkpointNonce;
    }

    function _validatePermanentMetadata(
        uint256 classId,
        uint8 rarityId,
        binderStructs.StaticStats memory,
        binderStructs.DynamicStats memory dynamicStats
    ) internal view {
        uint16 version = classVersion[classId];
        if (classId == 0 || rarityId == 0 || version == 0) {
            revert InvalidPermanentMetadata(classId, rarityId, version);
        }
        if (dynamicStats.currentHP > dynamicStats.maxHP || dynamicStats.currentMP > dynamicStats.maxMP) {
            revert InvalidPermanentVitals(
                dynamicStats.currentHP, dynamicStats.currentMP, dynamicStats.maxHP, dynamicStats.maxMP
            );
        }
    }

    function _requireActivityController(uint8 activityId, address caller) internal view {
        if (activityId == 0) revert InvalidActivityId(activityId);
        address controller = _activityController[activityId];
        if (controller == address(0)) revert ActivityControllerNotSet(activityId);
        if (caller != controller) revert UnauthorizedActivityController(activityId, caller);
    }

    function _isReadyToArm(uint256 tokenId) internal view returns (bool) {
        binderStructs.NFTMetadata storage meta = _tokenMetadata[tokenId];
        return meta.configVersion == classVersion[meta.classId];
    }

    function _isIdle(uint256 tokenId) internal view returns (bool) {
        return _activityState[tokenId].activityId == 0;
    }

    function _isProtocolTransferable(uint256 tokenId) internal view returns (bool) {
        if (!_isIdle(tokenId) || paused()) return false;
        return binderGraveyard == address(0) || ownerOf(tokenId) != binderGraveyard;
    }

    function _emitMetadataUpdate(uint256 tokenId) internal {
        emit MetadataUpdate(tokenId);
    }

    function _emitAllMetadataUpdate() internal {
        if (_tokenIdCounter > 1) emit BatchMetadataUpdate(1, _tokenIdCounter - 1);
    }

    /// @dev OpenZeppelin 4.8 transfer hook. There is intentionally no generic lock-bypass role.
    function _beforeTokenTransfer(address from, address to, uint256 tokenId, uint256 batchSize)
        internal
        override(ERC721, ERC721Pausable)
    {
        if (from != address(0)) {
            if (from == binderGraveyard && !_resurrectionTransferInProgress && !_permanentBurnInProgress) {
                revert TokenInGraveyard(tokenId);
            }
            uint8 activityId = _activityState[tokenId].activityId;
            if (activityId != 0) revert TokenBusy(tokenId, activityId);
        }
        if (to == binderGraveyard && !_graveyardTransferInProgress) revert UnauthorizedGraveyardTransfer(tokenId);
        super._beforeTokenTransfer(from, to, tokenId, batchSize);
    }

    function _requireToken(uint256 tokenId) internal view {
        if (!_exists(tokenId)) revert InvalidToken(tokenId);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, AccessControl) returns (bool) {
        return interfaceId == ERC4906_INTERFACE_ID || super.supportsInterface(interfaceId);
    }
}
