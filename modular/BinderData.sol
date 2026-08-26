// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-4.8/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts-4.8/token/ERC721/extensions/ERC721Pausable.sol";
import "@openzeppelin/contracts-4.8/access/Ownable.sol";
import "@openzeppelin/contracts-4.8/access/AccessControl.sol";
import "@openzeppelin/contracts-4.8/utils/Strings.sol";
import "./supportContract/binderStructs.sol";

/// @notice Minimal read-only metadata-renderer interface.
interface IBinderUriBldr {
    function tokenURI(uint256 tokenId) external view returns (string memory);
}

/// @notice ERC-721 NFT-instance database and authoritative activity/transfer state.
contract BinderData is ERC721, ERC721Pausable, Ownable, AccessControl {
    bytes32 public constant CONFIG_ROLE = keccak256("CONFIG_ROLE");
    bytes32 public constant BATTLE_ROLE = keccak256("BATTLE_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant FUSION_ROLE = keccak256("FUSION_ROLE");
    bytes4 public constant ERC4906_INTERFACE_ID = 0x49064906;

    error InvalidUriFormat();
    error MaxSupplyReached();
    error InvalidToken(uint256 tokenId);
    error AlreadyUpgraded();
    error NotDeadYet();
    error UriBuilderNotSet();
    error InvalidClassId();
    error InvalidNewVersionTooHigh();
    error GraveyardNotSet();
    error TokenBusy(uint256 tokenId, uint8 activityId);
    error UnitNotReadyToArm(uint256 tokenId);
    error UnitAlreadyIdle(uint256 tokenId);
    error InvalidActivityId(uint8 activityId);
    error ActivityControllerNotSet(uint8 activityId);
    error UnauthorizedActivityController(uint8 activityId, address caller);
    error TokenInGraveyard(uint256 tokenId);
    error UnauthorizedGraveyardTransfer(uint256 tokenId);

    uint256 public maxSupply = 1_000_000;
    uint128 internal supplyBuffer = 125;
    uint256 internal supplyIncrement = 10_000;
    uint128 private _tokenIdCounter = 1;

    string public baseImageURI;
    address public binderGraveyard;
    address public binderUriBldrAddress;

    mapping(uint256 => binderStructs.NFTMetadata) private _tokenMetadata;
    mapping(uint256 => uint16) public classVersion;
    mapping(uint256 => binderStructs.ActivityState) private _activityState;
    mapping(uint8 => address) private _activityController;
    bool private _graveyardTransferInProgress;

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
    event MetadataUpdate(uint256 tokenId);
    event BatchMetadataUpdate(uint256 fromTokenId, uint256 toTokenId);

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
    ) external onlyRole(MINTER_ROLE) returns (uint256) {
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
    ) external onlyRole(FUSION_ROLE) returns (uint256) {
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
        emit ActivityStarted(tokenId, activityId, lockedUntil);
        _emitMetadataUpdate(tokenId);
    }

    /// @notice Ends the caller's currently active activity. ReadyToArm is intentionally not checked on exit.
    /// @dev Custody activities must call this before custody -> player transfer in the same transaction.
    function endActivity(uint256 tokenId) external {
        _requireToken(tokenId);
        uint8 activityId = _activityState[tokenId].activityId;
        if (activityId == 0) revert UnitAlreadyIdle(tokenId);
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

        meta.staticStats = stats;
        meta.dynamicStats = dynamicStats;
        meta.configVersion = latestVersion;
        emit NFTStatsUpdated(tokenId, stats.stats, latestVersion);
        _emitMetadataUpdate(tokenId);
    }

    /// @notice Battle-state update. Frequent HP/MP changes deliberately do not emit ERC-4906 events.
    function updateCurrentStats(uint256 tokenId, uint16 currentHP, uint16 currentMP) external onlyRole(BATTLE_ROLE) {
        _requireToken(tokenId);
        binderStructs.NFTMetadata storage meta = _tokenMetadata[tokenId];
        meta.dynamicStats.currentHP = currentHP > meta.dynamicStats.maxHP ? meta.dynamicStats.maxHP : currentHP;
        meta.dynamicStats.currentMP = currentMP > meta.dynamicStats.maxMP ? meta.dynamicStats.maxMP : currentMP;
        if (meta.dynamicStats.currentHP == 0) _autoTransferToGraveyard(tokenId);
    }

    // === Graveyard ===

    function _autoTransferToGraveyard(uint256 tokenId) internal {
        if (_tokenMetadata[tokenId].dynamicStats.currentHP != 0) revert NotDeadYet();
        _moveToGraveyard(tokenId);
    }

    /// @notice Explicit fusion retirement path.
    function tfToGraveyard(uint256 tokenId) external onlyRole(FUSION_ROLE) {
        _requireToken(tokenId);
        _moveToGraveyard(tokenId);
    }

    function _moveToGraveyard(uint256 tokenId) internal {
        if (binderGraveyard == address(0)) revert GraveyardNotSet();
        uint8 activityId = _activityState[tokenId].activityId;
        if (activityId != 0) {
            delete _activityState[tokenId];
            emit ActivityClearedForGraveyard(tokenId, activityId);
            _emitMetadataUpdate(tokenId);
        }

        _graveyardTransferInProgress = true;
        _transfer(ownerOf(tokenId), binderGraveyard, tokenId);
        _graveyardTransferInProgress = false;
    }

    // === ERC-721 metadata entrypoint ===

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireToken(tokenId);
        if (binderUriBldrAddress == address(0)) revert UriBuilderNotSet();
        return IBinderUriBldr(binderUriBldrAddress).tokenURI(tokenId);
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

    function setBinderUriBldr(address builderAddress) external onlyOwner {
        if (builderAddress == address(0)) revert UriBuilderNotSet();
        binderUriBldrAddress = builderAddress;
        _emitAllMetadataUpdate();
    }

    function setBaseImageURI(string memory newURI) external onlyOwner {
        if (bytes(newURI).length > 0 && bytes(newURI)[bytes(newURI).length - 1] != "/") revert InvalidUriFormat();
        baseImageURI = newURI;
        _emitAllMetadataUpdate();
    }

    function setGraveyard(address graveyard) external onlyOwner {
        if (graveyard == address(0)) revert GraveyardNotSet();
        binderGraveyard = graveyard;
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
            if (from == binderGraveyard) revert TokenInGraveyard(tokenId);
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
