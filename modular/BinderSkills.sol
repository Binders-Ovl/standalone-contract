// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-4.8/access/AccessControl.sol";
import "@openzeppelin/contracts-4.8/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-4.8/proxy/utils/UUPSUpgradeable.sol";
import "@pythnetwork/entropy-sdk-solidity/IEntropyConsumer.sol";
import "@pythnetwork/entropy-sdk-solidity/IEntropyV2.sol";
import "./supportContract/binderIds.sol";
import "./supportContract/Errors.sol";
import "./supportContract/binderStructs.sol";
import "./interfaces/IBinderData.sol";
import "./interfaces/IBinderSkills.sol";
import "./interfaces/ICentralConsole.sol";
import "./interfaces/IBook0fArts.sol";
import "./interfaces/IBook0fItems.sol";
import "./interfaces/IBinderInventory.sol";
import "./Items/ItemStruct.sol";

/// @notice Canonical persistent learned-skill state for the Binder collection.
/// @dev Deploy this implementation behind an OZ 4.8 ERC1967/UUPS proxy. The
/// implementation constructor is locked; all persistent state is proxy storage.
contract BinderSkills is Initializable, AccessControl, UUPSUpgradeable, IEntropyConsumer, IBinderSkills {
    bytes32 public constant SKILL_GRANTER_ROLE = keccak256("SKILL_GRANTER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant TOME_CONFIG_ROLE = keccak256("TOME_CONFIG_ROLE");
    uint48 public constant TOME_RESCUE_DELAY = 1 days;

    /// @notice Canonically paired, permanent BinderData collection address.
    address public override binderData;
    /// @notice Canonical registry used to reject skill writes through an unregistered proxy.
    address public override centralConsole;

    mapping(uint256 => uint32[3]) private _moveSets;
    mapping(uint256 => uint32[]) private _activeSkills;
    mapping(uint256 => mapping(uint32 => bool)) private _hasActiveSkill;
    mapping(uint256 => uint32[]) private _passiveSkills;
    mapping(uint256 => mapping(uint32 => bool)) private _hasPassiveSkill;
    mapping(uint256 => mapping(uint32 => uint16)) private _learnedArtVersion;

    IBook0fItems public book0fItems;
    IBinderInventory public binderInventory;
    IEntropyV2 public tomeEntropy;
    address public tomeEntropyProvider;

    struct PendingTomeLearning {
        uint256 binderId;
        uint256 tomeTokenId;
        uint32 artId;
        uint16 successBps;
        TomeBurnPolicy burnPolicy;
        uint48 requestedAt;
    }

    mapping(uint64 => PendingTomeLearning) private _pendingTomeLearning;

    /// @dev Reserved only for future appended BinderSkills storage variables.
    uint256[38] private __gap;

    event MoveSetLearned(uint256 indexed tokenId, uint8 indexed slot, uint32 indexed artId);
    event ActiveSkillLearned(uint256 indexed tokenId, uint32 indexed artId);
    event PassiveSkillLearned(uint256 indexed tokenId, uint32 indexed artId);
    event CentralConsoleUpdated(address indexed previousConsole, address indexed newConsole);
    event TomeLearningDependenciesUpdated(
        address indexed book, address indexed inventory, address entropy, address provider
    );
    event TomeLearningRequested(uint64 indexed sequenceNumber, uint256 indexed tokenId, uint256 indexed tomeTokenId);
    event TomeLearningResolved(
        uint64 indexed sequenceNumber, uint256 indexed tokenId, uint256 indexed tomeTokenId, bool learned
    );
    event TomeLearningRescued(uint64 indexed sequenceNumber, uint256 indexed tokenId, uint256 indexed tomeTokenId);

    error ArtDoesNotExist(uint32 artId);
    error ArtNotEnabled(uint32 artId, uint16 version);
    error ArtTypeMismatch(uint32 artId, uint8 expectedType, uint8 actualType);
    error ArtClassIneligible(uint256 tokenId, uint256 classId, uint32 artId, uint16 version);
    error UnitNotReadyToLearn(uint256 tokenId);
    error UnitInGraveyard(uint256 tokenId);
    error IncompatibleSkillCategory(uint256 tokenId, uint32 artId);
    error TomeLearningNotConfigured();
    error TomeNotOwnedByBinder(uint256 tokenId, uint256 tomeTokenId);
    error TomeLearningAlreadyPending(uint64 sequenceNumber);
    error UnknownTomeLearning(uint64 sequenceNumber);
    error TomeLearningRescueNotReady(uint64 sequenceNumber, uint48 availableAt);
    error InvalidTomeLearningPayment(uint256 expected, uint256 received);
    error UnsupportedTomeArtType(uint32 artId, uint8 artTypeId);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes exactly one BinderSkills proxy against the canonical BinderData collection.
    function initialize(address initialAdmin, address binderDataAddress, address centralConsoleAddress)
        external
        initializer
    {
        if (initialAdmin == address(0) || binderDataAddress == address(0) || centralConsoleAddress == address(0)) {
            revert CanonicalPairMismatch(address(0), binderDataAddress);
        }
        if (binderDataAddress.code.length == 0 || centralConsoleAddress.code.length == 0) {
            revert CanonicalPairMismatch(address(0), binderDataAddress);
        }

        address canonicalBinderData;
        try ICentralConsole(centralConsoleAddress).binderData() returns (address resolvedBinderData) {
            canonicalBinderData = resolvedBinderData;
        } catch {
            revert CanonicalPairMismatch(address(0), binderDataAddress);
        }
        if (canonicalBinderData != binderDataAddress) {
            revert CanonicalPairMismatch(canonicalBinderData, binderDataAddress);
        }

        binderData = binderDataAddress;
        centralConsole = centralConsoleAddress;
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(SKILL_GRANTER_ROLE, initialAdmin);
        _grantRole(UPGRADER_ROLE, initialAdmin);
        _grantRole(TOME_CONFIG_ROLE, centralConsoleAddress);
    }

    /// @notice Permanently fills the first available MoveSet slot for an Idle Binder.
    function grantMoveSet(uint256 tokenId, uint32 artId) external onlyRole(SKILL_GRANTER_ROLE) {
        _grantArt(tokenId, artId, BinderIds.ART_TYPE_MOVE_SET);
    }

    /// @notice Records a learned Active Art without imposing a permanent loadout cap.
    function grantActiveSkill(uint256 tokenId, uint32 artId) external onlyRole(SKILL_GRANTER_ROLE) {
        _grantArt(tokenId, artId, BinderIds.ART_TYPE_ACTIVE);
    }

    /// @notice Records a learned Passive Art without imposing a permanent loadout cap.
    function grantPassiveSkill(uint256 tokenId, uint32 artId) external onlyRole(SKILL_GRANTER_ROLE) {
        _grantArt(tokenId, artId, BinderIds.ART_TYPE_PASSIVE);
    }

    function getMoveSets(uint256 tokenId) external view override returns (uint32[3] memory) {
        _requireTokenExists(tokenId);
        return _moveSets[tokenId];
    }

    function hasActiveSkill(uint256 tokenId, uint32 artId) external view override returns (bool) {
        _requireTokenExists(tokenId);
        return _hasActiveSkill[tokenId][artId];
    }

    function hasPassiveSkill(uint256 tokenId, uint32 artId) external view override returns (bool) {
        _requireTokenExists(tokenId);
        return _hasPassiveSkill[tokenId][artId];
    }

    function getLearnedArtVersion(uint256 tokenId, uint32 artId) external view override returns (uint16) {
        _requireTokenExists(tokenId);
        return _learnedArtVersion[tokenId][artId];
    }

    function setTomeLearningDependencies(
        address bookAddress,
        address inventoryAddress,
        address entropyAddress,
        address providerAddress
    ) external onlyRole(TOME_CONFIG_ROLE) {
        if (bookAddress.code.length == 0 || inventoryAddress.code.length == 0) revert TomeLearningNotConfigured();
        if ((entropyAddress == address(0)) != (providerAddress == address(0))) revert TomeLearningNotConfigured();
        if (entropyAddress != address(0) && entropyAddress.code.length == 0) revert TomeLearningNotConfigured();
        book0fItems = IBook0fItems(bookAddress);
        binderInventory = IBinderInventory(inventoryAddress);
        tomeEntropy = IEntropyV2(entropyAddress);
        tomeEntropyProvider = providerAddress;
        emit TomeLearningDependenciesUpdated(bookAddress, inventoryAddress, entropyAddress, providerAddress);
    }

    function learnFromTome(uint256 tokenId, uint256 tomeTokenId) external payable {
        _requireCanonicalPair();
        _requireIdleExisting(tokenId);
        if (IBinderData(binderData).ownerOf(tokenId) != msg.sender) revert TomeNotOwnedByBinder(tokenId, tomeTokenId);
        if (address(book0fItems) == address(0) || address(binderInventory) == address(0)) {
            revert TomeLearningNotConfigured();
        }
        if (!binderInventory.isTomeInInventory(tokenId, tomeTokenId)) revert TomeNotOwnedByBinder(tokenId, tomeTokenId);

        uint16 tomeId = binderInventory.tomeIdInInventory(tokenId, tomeTokenId);
        TomeConfig memory tome = book0fItems.getTome(tomeId);
        if (!tome.exists || !tome.enabled) revert ArtNotEnabled(tome.artId, 0);
        {
            binderStructs.ArtDefinition memory art = _requireCurrentArtEligibility(tokenId, tome.artId);
            _requireArtLearnable(tokenId, art);

            if (tome.learnSuccessBps == 10_000) {
                if (msg.value != 0) revert InvalidTomeLearningPayment(0, msg.value);
                binderInventory.consumeTomeForLearning(tokenId, tomeTokenId);
                _learnArt(tokenId, art);
                emit TomeLearningResolved(0, tokenId, tomeTokenId, true);
                return;
            }
        }

        _requestTomeLearning(tokenId, tomeTokenId, tome);
    }

    function _requestTomeLearning(uint256 tokenId, uint256 tomeTokenId, TomeConfig memory tome) private {
        if (address(tomeEntropy) == address(0)) revert TomeLearningNotConfigured();
        uint256 fee = tomeEntropy.getFeeV2(tomeEntropyProvider, 0);
        if (msg.value != fee) revert InvalidTomeLearningPayment(fee, msg.value);
        binderInventory.lockTomeForLearning(tokenId, tomeTokenId);
        uint64 sequence =
            tomeEntropy.requestV2{value: fee}(tomeEntropyProvider, keccak256(abi.encode(tokenId, tomeTokenId)), 0);
        PendingTomeLearning storage pending = _pendingTomeLearning[sequence];
        if (pending.binderId != 0) revert TomeLearningAlreadyPending(sequence);
        pending.binderId = tokenId;
        pending.tomeTokenId = tomeTokenId;
        pending.artId = tome.artId;
        pending.successBps = tome.learnSuccessBps;
        pending.burnPolicy = tome.burnPolicy;
        pending.requestedAt = uint48(block.timestamp);
        emit TomeLearningRequested(sequence, tokenId, tomeTokenId);
    }

    function rescueTomeLearning(uint64 sequenceNumber) external {
        PendingTomeLearning memory pending = _pendingTomeLearning[sequenceNumber];
        if (pending.binderId == 0) revert UnknownTomeLearning(sequenceNumber);
        if (IBinderData(binderData).ownerOf(pending.binderId) != msg.sender) {
            revert TomeNotOwnedByBinder(pending.binderId, pending.tomeTokenId);
        }
        uint48 availableAt = pending.requestedAt + TOME_RESCUE_DELAY;
        if (block.timestamp < availableAt) revert TomeLearningRescueNotReady(sequenceNumber, availableAt);
        delete _pendingTomeLearning[sequenceNumber];
        binderInventory.unlockTomeForLearning(pending.binderId, pending.tomeTokenId);
        emit TomeLearningRescued(sequenceNumber, pending.binderId, pending.tomeTokenId);
    }

    function pendingTomeLearning(uint64 sequenceNumber) external view returns (PendingTomeLearning memory) {
        return _pendingTomeLearning[sequenceNumber];
    }

    function getActiveSkillCount(uint256 tokenId) external view override returns (uint256) {
        _requireTokenExists(tokenId);
        return _activeSkills[tokenId].length;
    }

    function getPassiveSkillCount(uint256 tokenId) external view override returns (uint256) {
        _requireTokenExists(tokenId);
        return _passiveSkills[tokenId].length;
    }

    function getActiveSkills(uint256 tokenId, uint256 offset, uint256 limit)
        external
        view
        override
        returns (uint32[] memory)
    {
        _requireTokenExists(tokenId);
        return _page(_activeSkills[tokenId], offset, limit);
    }

    function getPassiveSkills(uint256 tokenId, uint256 offset, uint256 limit)
        external
        view
        override
        returns (uint32[] memory)
    {
        _requireTokenExists(tokenId);
        return _page(_passiveSkills[tokenId], offset, limit);
    }

    function isCanonicalPair() external view returns (bool) {
        return ICentralConsole(centralConsole).binderData() == binderData
            && ICentralConsole(centralConsole).binderSkills() == address(this);
    }

    /// @notice Moves this persistent Skills proxy to a staged replacement
    /// console only after that console proves the same immutable collection and
    /// canonical Skills pairing. Learned storage remains in this proxy.
    function setCentralConsole(address newCentralConsole) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newCentralConsole == centralConsole || newCentralConsole.code.length == 0) {
            revert CanonicalPairMismatch(centralConsole, newCentralConsole);
        }
        address candidateBinderData;
        address candidateSkills;
        try ICentralConsole(newCentralConsole).binderData() returns (address resolvedBinderData) {
            candidateBinderData = resolvedBinderData;
        } catch {
            revert CanonicalPairMismatch(binderData, address(0));
        }
        try ICentralConsole(newCentralConsole).binderSkills() returns (address resolvedSkills) {
            candidateSkills = resolvedSkills;
        } catch {
            revert CanonicalSkillsMismatch(address(this), address(0));
        }
        if (candidateBinderData != binderData) revert CanonicalPairMismatch(binderData, candidateBinderData);
        if (candidateSkills != address(this)) revert CanonicalSkillsMismatch(address(this), candidateSkills);

        address previousConsole = centralConsole;
        centralConsole = newCentralConsole;
        emit CentralConsoleUpdated(previousConsole, newCentralConsole);
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

    function getEntropy() internal view override returns (address) {
        return address(tomeEntropy);
    }

    function entropyCallback(uint64 sequenceNumber, address providerAddress, bytes32 randomNumber) internal override {
        if (providerAddress != tomeEntropyProvider) revert UnknownTomeLearning(sequenceNumber);
        PendingTomeLearning memory pending = _pendingTomeLearning[sequenceNumber];
        if (pending.binderId == 0) revert UnknownTomeLearning(sequenceNumber);
        delete _pendingTomeLearning[sequenceNumber];

        bool learned = uint256(randomNumber) % 10_000 < pending.successBps;
        if (learned) {
            binderStructs.ArtDefinition memory art = _requireCurrentArtEligibility(pending.binderId, pending.artId);
            _requireArtLearnable(pending.binderId, art);
            binderInventory.consumeTomeForLearning(pending.binderId, pending.tomeTokenId);
            _learnArt(pending.binderId, art);
        } else if (pending.burnPolicy == TomeBurnPolicy.ON_ATTEMPT) {
            binderInventory.consumeTomeForLearning(pending.binderId, pending.tomeTokenId);
        } else {
            binderInventory.unlockTomeForLearning(pending.binderId, pending.tomeTokenId);
        }
        emit TomeLearningResolved(sequenceNumber, pending.binderId, pending.tomeTokenId, learned);
    }

    function _requireCanonicalPair() internal view {
        address canonicalBinderData = ICentralConsole(centralConsole).binderData();
        if (canonicalBinderData != binderData) revert CanonicalPairMismatch(canonicalBinderData, binderData);

        address canonicalSkills = ICentralConsole(centralConsole).binderSkills();
        if (canonicalSkills != address(this)) revert CanonicalSkillsMismatch(canonicalSkills, address(this));
    }

    function _requireIdleExisting(uint256 tokenId) internal view {
        _requireTokenExists(tokenId);
        binderStructs.UnitStateView memory state = IBinderData(binderData).getUnitState(tokenId);
        if (!state.idle) revert UnitNotIdle(tokenId, state.activity.activityId);
        if (!state.readyToArm) revert UnitNotReadyToLearn(tokenId);
        address graveyard = IBinderData(binderData).binderGraveyard();
        if (graveyard != address(0) && IBinderData(binderData).ownerOf(tokenId) == graveyard) {
            revert UnitInGraveyard(tokenId);
        }
    }

    function _requireTokenExists(uint256 tokenId) internal view {
        IBinderData(binderData).ownerOf(tokenId);
    }

    function _grantArt(uint256 tokenId, uint32 artId, uint8 expectedType) private {
        _requireCanonicalPair();
        _requireIdleExisting(tokenId);
        binderStructs.ArtDefinition memory art = _requireCurrentArtEligibility(tokenId, artId);
        if (art.artTypeId != expectedType) revert ArtTypeMismatch(artId, expectedType, art.artTypeId);
        _requireArtLearnable(tokenId, art);
        _learnArt(tokenId, art);
    }

    function _requireCurrentArtEligibility(uint256 tokenId, uint32 artId)
        internal
        view
        returns (binderStructs.ArtDefinition memory definition)
    {
        _requireArtId(artId);
        address artsAddress = ICentralConsole(centralConsole).book0fArts();
        if (artsAddress == address(0) || artsAddress.code.length == 0) revert ArtDoesNotExist(artId);
        IBook0fArts arts = IBook0fArts(artsAddress);
        if (!arts.artExists(artId)) revert ArtDoesNotExist(artId);
        definition = arts.getArtDefinition(artId);
        if (definition.version == 0 || !definition.enabled) revert ArtNotEnabled(artId, definition.version);
        uint256 classId = IBinderData(binderData).getNFTClass(tokenId);
        if (!arts.isClassEligible(artId, definition.version, classId)) {
            revert ArtClassIneligible(tokenId, classId, artId, definition.version);
        }
        binderStructs.NFTMetadata memory details = IBinderData(binderData).getNFTDetails(tokenId);
        for (uint256 i; i < 8; ++i) {
            if (details.staticStats.stats[i] < definition.minBaseStats[i]) revert UnitNotReadyToLearn(tokenId);
        }
        for (uint256 i; i < definition.requiredSkillIds.length; ++i) {
            if (!_hasLearnedArt(tokenId, definition.requiredSkillIds[i])) revert UnitNotReadyToLearn(tokenId);
        }
        for (uint256 i; i < definition.forbiddenSkillIds.length; ++i) {
            if (_hasLearnedArt(tokenId, definition.forbiddenSkillIds[i])) revert UnitNotReadyToLearn(tokenId);
        }
    }

    function _learnArt(uint256 tokenId, binderStructs.ArtDefinition memory art) private {
        uint32 artId = art.artId;
        if (art.artTypeId == BinderIds.ART_TYPE_MOVE_SET) {
            uint32[3] storage moveSets = _moveSets[tokenId];
            uint8 slot;
            for (; slot < BinderIds.MOVE_SET_SLOTS; ++slot) {
                if (moveSets[slot] == artId || moveSets[slot] == 0) break;
            }
            if (slot == BinderIds.MOVE_SET_SLOTS) revert MoveSetSlotsFull(tokenId);
            moveSets[slot] = artId;
            emit MoveSetLearned(tokenId, slot, artId);
        } else if (art.artTypeId == BinderIds.ART_TYPE_ACTIVE) {
            if (!_hasActiveSkill[tokenId][artId]) {
                _hasActiveSkill[tokenId][artId] = true;
                _activeSkills[tokenId].push(artId);
            }
            emit ActiveSkillLearned(tokenId, artId);
        } else {
            if (!_hasPassiveSkill[tokenId][artId]) {
                _hasPassiveSkill[tokenId][artId] = true;
                _passiveSkills[tokenId].push(artId);
            }
            emit PassiveSkillLearned(tokenId, artId);
        }
        _learnedArtVersion[tokenId][artId] = art.version;
        _refreshTokenMetadata(tokenId);
    }

    function _requireArtLearnable(uint256 tokenId, binderStructs.ArtDefinition memory art) private view {
        uint8 artTypeId = art.artTypeId;
        uint32 artId = art.artId;
        if (
            artTypeId != BinderIds.ART_TYPE_MOVE_SET && artTypeId != BinderIds.ART_TYPE_ACTIVE
                && artTypeId != BinderIds.ART_TYPE_PASSIVE
        ) revert UnsupportedTomeArtType(artId, artTypeId);
        if (
            (_hasMoveSet(tokenId, artId) && artTypeId != BinderIds.ART_TYPE_MOVE_SET)
                || (_hasActiveSkill[tokenId][artId] && artTypeId != BinderIds.ART_TYPE_ACTIVE)
                || (_hasPassiveSkill[tokenId][artId] && artTypeId != BinderIds.ART_TYPE_PASSIVE)
        ) revert IncompatibleSkillCategory(tokenId, artId);
        if (_hasLearnedArt(tokenId, artId) && _learnedArtVersion[tokenId][artId] >= art.version) {
            revert SkillAlreadyLearned(tokenId, artId);
        }
    }

    function _hasLearnedArt(uint256 tokenId, uint32 artId) private view returns (bool) {
        return _hasMoveSet(tokenId, artId) || _hasActiveSkill[tokenId][artId] || _hasPassiveSkill[tokenId][artId];
    }

    function _requireArtId(uint32 artId) internal pure {
        if (artId == 0) revert InvalidArtId(artId);
    }

    function _hasMoveSet(uint256 tokenId, uint32 artId) internal view returns (bool) {
        uint32[3] storage moveSets = _moveSets[tokenId];
        for (uint256 slot; slot < BinderIds.MOVE_SET_SLOTS; ++slot) {
            if (moveSets[slot] == artId) return true;
        }
        return false;
    }

    function _refreshTokenMetadata(uint256 tokenId) internal {
        IBinderData(binderData).refreshMetadata(tokenId);
    }

    function _page(uint32[] storage source, uint256 offset, uint256 limit)
        internal
        view
        returns (uint32[] memory page)
    {
        uint256 sourceLength = source.length;
        if (offset >= sourceLength || limit == 0) return new uint32[](0);

        uint256 available = sourceLength - offset;
        uint256 pageLength = limit < available ? limit : available;
        page = new uint32[](pageLength);
        for (uint256 index; index < pageLength; ++index) {
            page[index] = source[offset + index];
        }
    }
}
