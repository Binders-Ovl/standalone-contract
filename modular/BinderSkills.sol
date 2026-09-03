// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-4.8/access/AccessControl.sol";
import "@openzeppelin/contracts-4.8/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-4.8/proxy/utils/UUPSUpgradeable.sol";
import "./supportContract/binderIds.sol";
import "./supportContract/Errors.sol";
import "./supportContract/binderStructs.sol";
import "./interfaces/IBinderData.sol";
import "./interfaces/IBinderSkills.sol";
import "./interfaces/ICentralConsole.sol";
import "./interfaces/IBook0fArts.sol";

/// @notice Canonical persistent learned-skill state for the Binder collection.
/// @dev Deploy this implementation behind an OZ 4.8 ERC1967/UUPS proxy. The
/// implementation constructor is locked; all persistent state is proxy storage.
contract BinderSkills is Initializable, AccessControl, UUPSUpgradeable, IBinderSkills {
    bytes32 public constant SKILL_GRANTER_ROLE = keccak256("SKILL_GRANTER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @notice Canonically paired, permanent BinderData collection address.
    address public override binderData;
    /// @notice Canonical registry used to reject skill writes through an unregistered proxy.
    address public override centralConsole;

    mapping(uint256 => uint32[3]) private _moveSets;
    mapping(uint256 => uint32[]) private _activeSkills;
    mapping(uint256 => mapping(uint32 => bool)) private _hasActiveSkill;
    mapping(uint256 => uint32[]) private _passiveSkills;
    mapping(uint256 => mapping(uint32 => bool)) private _hasPassiveSkill;

    /// @dev Reserved only for future appended BinderSkills storage variables.
    uint256[44] private __gap;

    event MoveSetLearned(uint256 indexed tokenId, uint8 indexed slot, uint32 indexed artId);
    event ActiveSkillLearned(uint256 indexed tokenId, uint32 indexed artId);
    event PassiveSkillLearned(uint256 indexed tokenId, uint32 indexed artId);
    event CentralConsoleUpdated(address indexed previousConsole, address indexed newConsole);

    error ArtDoesNotExist(uint32 artId);
    error ArtNotEnabled(uint32 artId, uint16 version);
    error ArtTypeMismatch(uint32 artId, uint8 expectedType, uint8 actualType);
    error ArtClassIneligible(uint256 tokenId, uint256 classId, uint32 artId, uint16 version);
    error UnitNotReadyToLearn(uint256 tokenId);
    error UnitInGraveyard(uint256 tokenId);
    error IncompatibleSkillCategory(uint256 tokenId, uint32 artId);

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
    }

    /// @notice Permanently fills the first available MoveSet slot for an Idle Binder.
    function grantMoveSet(uint256 tokenId, uint32 artId) external onlyRole(SKILL_GRANTER_ROLE) {
        _requireCanonicalPair();
        _requireIdleExisting(tokenId);
        _requireLearnableArt(tokenId, artId, BinderIds.ART_TYPE_MOVE_SET);
        if (_hasActiveSkill[tokenId][artId] || _hasPassiveSkill[tokenId][artId]) {
            revert IncompatibleSkillCategory(tokenId, artId);
        }

        uint32[3] storage moveSets = _moveSets[tokenId];
        for (uint8 slot; slot < BinderIds.MOVE_SET_SLOTS; ++slot) {
            uint32 currentArtId = moveSets[slot];
            if (currentArtId == artId) revert SkillAlreadyLearned(tokenId, artId);
            if (currentArtId == 0) {
                moveSets[slot] = artId;
                emit MoveSetLearned(tokenId, slot, artId);
                _refreshTokenMetadata(tokenId);
                return;
            }
        }
        revert MoveSetSlotsFull(tokenId);
    }

    /// @notice Records a learned Active Art without imposing a permanent loadout cap.
    function grantActiveSkill(uint256 tokenId, uint32 artId) external onlyRole(SKILL_GRANTER_ROLE) {
        _requireCanonicalPair();
        _requireIdleExisting(tokenId);
        _requireLearnableArt(tokenId, artId, BinderIds.ART_TYPE_ACTIVE);
        if (_hasPassiveSkill[tokenId][artId] || _hasMoveSet(tokenId, artId)) {
            revert IncompatibleSkillCategory(tokenId, artId);
        }
        if (_hasActiveSkill[tokenId][artId]) revert SkillAlreadyLearned(tokenId, artId);

        _hasActiveSkill[tokenId][artId] = true;
        _activeSkills[tokenId].push(artId);
        emit ActiveSkillLearned(tokenId, artId);
        _refreshTokenMetadata(tokenId);
    }

    /// @notice Records a learned Passive Art without imposing a permanent loadout cap.
    function grantPassiveSkill(uint256 tokenId, uint32 artId) external onlyRole(SKILL_GRANTER_ROLE) {
        _requireCanonicalPair();
        _requireIdleExisting(tokenId);
        _requireLearnableArt(tokenId, artId, BinderIds.ART_TYPE_PASSIVE);
        if (_hasActiveSkill[tokenId][artId] || _hasMoveSet(tokenId, artId)) {
            revert IncompatibleSkillCategory(tokenId, artId);
        }
        if (_hasPassiveSkill[tokenId][artId]) revert SkillAlreadyLearned(tokenId, artId);

        _hasPassiveSkill[tokenId][artId] = true;
        _passiveSkills[tokenId].push(artId);
        emit PassiveSkillLearned(tokenId, artId);
        _refreshTokenMetadata(tokenId);
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

    function _requireLearnableArt(uint256 tokenId, uint32 artId, uint8 expectedType) internal view {
        _requireArtId(artId);
        address artsAddress = ICentralConsole(centralConsole).book0fArts();
        if (artsAddress == address(0) || artsAddress.code.length == 0) revert ArtDoesNotExist(artId);
        IBook0fArts arts = IBook0fArts(artsAddress);
        if (!arts.artExists(artId)) revert ArtDoesNotExist(artId);
        binderStructs.ArtDefinition memory definition = arts.getArtDefinition(artId);
        if (definition.version == 0 || !definition.enabled) revert ArtNotEnabled(artId, definition.version);
        if (definition.artTypeId != expectedType) {
            revert ArtTypeMismatch(artId, expectedType, definition.artTypeId);
        }
        uint256 classId = IBinderData(binderData).getNFTClass(tokenId);
        if (!arts.isClassEligible(artId, definition.version, classId)) {
            revert ArtClassIneligible(tokenId, classId, artId, definition.version);
        }
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
