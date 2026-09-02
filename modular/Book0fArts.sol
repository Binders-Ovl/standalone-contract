// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-4.8/access/AccessControl.sol";
import "./supportContract/binderIds.sol";
import "./supportContract/Errors.sol";
import "./supportContract/binderStructs.sol";
import "./interfaces/IBook0fArts.sol";

/// @notice Canonical, versioned Art/Skill definitions; it never owns learned skills.
contract Book0fArts is AccessControl, IBook0fArts {
    bytes32 public constant CONFIG_ROLE = keccak256("CONFIG_ROLE");

    mapping(uint32 => bool) private _artExists;
    mapping(uint32 => uint16) private _currentVersion;
    mapping(uint32 => mapping(uint16 => bool)) private _versionExists;
    mapping(uint32 => mapping(uint16 => binderStructs.ArtDefinition)) private _definitions;
    mapping(uint32 => uint16[]) private _versions;
    mapping(uint32 => mapping(uint16 => uint256[])) private _eligibleClassIds;
    mapping(uint32 => mapping(uint16 => mapping(uint256 => bool))) private _classEligible;
    uint32[] private _artIds;

    event ArtVersionConfigured(uint32 indexed artId, uint16 indexed version, bool enabled);
    event ArtEligibilityConfigured(uint32 indexed artId, uint16 indexed version, uint256 eligibleClassCount);

    error ArtAlreadyExists(uint32 artId);
    error ArtDoesNotExist(uint32 artId);
    error ArtVersionDoesNotExist(uint32 artId, uint16 version);
    error InvalidArtVersion(uint16 version);
    error InvalidArtDefinition();
    error DuplicateEligibleClass(uint32 artId, uint16 version, uint256 classId);

    constructor(address initialAdmin) {
        if (initialAdmin == address(0)) revert InvalidModuleAddress(BinderIds.MODULE_BOOK_OF_ARTS, initialAdmin);
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(CONFIG_ROLE, initialAdmin);
    }

    function addArt(binderStructs.ArtDefinition calldata definition, uint256[] calldata eligibleClassIds)
        external
        onlyRole(CONFIG_ROLE)
    {
        if (definition.artId == 0) revert InvalidArtId(definition.artId);
        if (_artExists[definition.artId]) revert ArtAlreadyExists(definition.artId);
        _artExists[definition.artId] = true;
        _artIds.push(definition.artId);
        _storeVersion(definition, eligibleClassIds);
    }

    function updateArt(binderStructs.ArtDefinition calldata definition, uint256[] calldata eligibleClassIds)
        external
        onlyRole(CONFIG_ROLE)
    {
        _requireArt(definition.artId);
        if (definition.version <= _currentVersion[definition.artId]) revert InvalidArtVersion(definition.version);
        _storeVersion(definition, eligibleClassIds);
    }

    /// @notice Disables or re-enables an Art in a new immutable version snapshot.
    function setArtEnabled(uint32 artId, bool enabled, uint16 newVersion) external onlyRole(CONFIG_ROLE) {
        _requireArt(artId);
        if (newVersion <= _currentVersion[artId]) revert InvalidArtVersion(newVersion);

        binderStructs.ArtDefinition memory definition = _definitions[artId][_currentVersion[artId]];
        uint256[] memory eligibility = _eligibleClassIds[artId][_currentVersion[artId]];
        definition.enabled = enabled;
        definition.version = newVersion;
        _storeVersionMemory(definition, eligibility);
    }

    /// @notice Chunk-safe migration import. Each item is an initial Art or a newer Art version.
    function importArtVersions(
        binderStructs.ArtDefinition[] calldata definitions,
        uint256[][] calldata eligibilityByDefinition
    ) external onlyRole(CONFIG_ROLE) {
        require(definitions.length == eligibilityByDefinition.length, "Mismatched Art import");
        for (uint256 i; i < definitions.length; ++i) {
            uint32 artId = definitions[i].artId;
            if (artId == 0) revert InvalidArtId(artId);
            if (!_artExists[artId]) {
                _artExists[artId] = true;
                _artIds.push(artId);
            } else if (definitions[i].version <= _currentVersion[artId]) {
                revert InvalidArtVersion(definitions[i].version);
            }
            _storeVersion(definitions[i], eligibilityByDefinition[i]);
        }
    }

    function getArtCount() external view override returns (uint256) {
        return _artIds.length;
    }

    function getArtIdAt(uint256 index) external view override returns (uint32) {
        return _artIds[index];
    }

    function getArtIds(uint256 offset, uint256 limit) external view override returns (uint32[] memory) {
        uint256 sourceLength = _artIds.length;
        if (offset >= sourceLength || limit == 0) return new uint32[](0);
        uint256 available = sourceLength - offset;
        uint256 pageLength = limit < available ? limit : available;
        uint32[] memory page = new uint32[](pageLength);
        for (uint256 i; i < pageLength; ++i) page[i] = _artIds[offset + i];
        return page;
    }

    function getArtDefinition(uint32 artId) external view override returns (binderStructs.ArtDefinition memory) {
        _requireArt(artId);
        return _definitions[artId][_currentVersion[artId]];
    }

    function getArtDefinitionAtVersion(uint32 artId, uint16 version)
        external
        view
        override
        returns (binderStructs.ArtDefinition memory)
    {
        _requireArtVersion(artId, version);
        return _definitions[artId][version];
    }

    function getArtVersionCount(uint32 artId) external view override returns (uint256) {
        _requireArt(artId);
        return _versions[artId].length;
    }

    function getArtVersionAt(uint32 artId, uint256 index) external view override returns (uint16) {
        _requireArt(artId);
        return _versions[artId][index];
    }

    function getArtVersions(uint32 artId, uint256 offset, uint256 limit)
        external
        view
        override
        returns (uint16[] memory)
    {
        _requireArt(artId);
        return _pageVersions(_versions[artId], offset, limit);
    }

    function isArtEnabled(uint32 artId) external view override returns (bool) {
        _requireArt(artId);
        return _definitions[artId][_currentVersion[artId]].enabled;
    }

    /// @dev An empty eligibility list means the Art is available to every class.
    function isClassEligible(uint32 artId, uint16 version, uint256 classId) external view override returns (bool) {
        _requireArtVersion(artId, version);
        return _eligibleClassIds[artId][version].length == 0 || _classEligible[artId][version][classId];
    }

    function getEligibleClassIds(uint32 artId, uint16 version, uint256 offset, uint256 limit)
        external
        view
        override
        returns (uint256[] memory)
    {
        _requireArtVersion(artId, version);
        uint256[] storage source = _eligibleClassIds[artId][version];
        uint256 sourceLength = source.length;
        if (offset >= sourceLength || limit == 0) return new uint256[](0);
        uint256 available = sourceLength - offset;
        uint256 pageLength = limit < available ? limit : available;
        uint256[] memory page = new uint256[](pageLength);
        for (uint256 i; i < pageLength; ++i) page[i] = source[offset + i];
        return page;
    }

    function _storeVersion(binderStructs.ArtDefinition calldata definition, uint256[] calldata eligibility) internal {
        binderStructs.ArtDefinition memory definitionCopy = definition;
        uint256[] memory eligibilityCopy = eligibility;
        _storeVersionMemory(definitionCopy, eligibilityCopy);
    }

    function _storeVersionMemory(binderStructs.ArtDefinition memory definition, uint256[] memory eligibility) internal {
        _validateDefinition(definition);
        uint32 artId = definition.artId;
        uint16 version = definition.version;
        if (_versionExists[artId][version]) revert InvalidArtVersion(version);

        _writeDefinition(artId, version, definition);
        _versionExists[artId][version] = true;
        _versions[artId].push(version);
        _currentVersion[artId] = version;

        for (uint256 i; i < eligibility.length; ++i) {
            uint256 classId = eligibility[i];
            if (classId == 0 || _classEligible[artId][version][classId]) {
                revert DuplicateEligibleClass(artId, version, classId);
            }
            _classEligible[artId][version][classId] = true;
            _eligibleClassIds[artId][version].push(classId);
        }

        emit ArtVersionConfigured(artId, version, definition.enabled);
        emit ArtEligibilityConfigured(artId, version, eligibility.length);
    }

    function _validateDefinition(binderStructs.ArtDefinition memory definition) internal pure {
        if (
            definition.artId == 0 || definition.version == 0 || bytes(definition.name).length == 0
                || definition.artTypeId == BinderIds.ART_TYPE_INVALID || definition.effectTypeId == BinderIds.EFFECT_TYPE_INVALID
                || definition.patternTypeId == BinderIds.PATTERN_TYPE_INVALID
                || definition.primaryFormula.termCount > BinderIds.MAX_FORMULA_TERMS
                || definition.secondaryFormula.termCount > BinderIds.MAX_FORMULA_TERMS
        ) revert InvalidArtDefinition();

        _validateFormula(definition.primaryFormula);
        _validateFormula(definition.secondaryFormula);
        if (definition.ailmentId != 0 && definition.ailmentId < BinderIds.MIN_AILMENT_ID) {
            revert InvalidAilmentId(definition.ailmentId);
        }
    }

    /// @dev Solidity 0.8.24 cannot assign a memory struct containing a fixed
    /// nested struct array directly to storage, so copy the bounded formula data
    /// explicitly while retaining the shared public struct shape.
    function _writeDefinition(uint32 artId, uint16 version, binderStructs.ArtDefinition memory source) internal {
        binderStructs.ArtDefinition storage destination = _definitions[artId][version];
        destination.artId = source.artId;
        destination.name = source.name;
        destination.artTypeId = source.artTypeId;
        destination.hpCost = source.hpCost;
        destination.mpCost = source.mpCost;
        destination.effectTypeId = source.effectTypeId;
        destination.patternTypeId = source.patternTypeId;
        destination.range = source.range;
        destination.requirementFlags = source.requirementFlags;
        destination.ailmentId = source.ailmentId;
        destination.version = source.version;
        destination.enabled = source.enabled;
        _writeFormula(destination.primaryFormula, source.primaryFormula);
        _writeFormula(destination.secondaryFormula, source.secondaryFormula);
    }

    function _writeFormula(binderStructs.Formula storage destination, binderStructs.Formula memory source) internal {
        destination.formulaTypeId = source.formulaTypeId;
        destination.termCount = source.termCount;
        destination.flatValue = source.flatValue;
        for (uint256 i; i < BinderIds.MAX_FORMULA_TERMS; ++i) {
            destination.terms[i].sourceId = source.terms[i].sourceId;
            destination.terms[i].statId = source.terms[i].statId;
            destination.terms[i].coefficientBps = source.terms[i].coefficientBps;
        }
    }

    function _validateFormula(binderStructs.Formula memory formula) internal pure {
        for (uint256 i; i < formula.termCount; ++i) {
            binderStructs.FormulaTerm memory term = formula.terms[i];
            if (
                term.sourceId == BinderIds.FORMULA_SOURCE_INVALID || term.sourceId > BinderIds.FORMULA_SOURCE_TARGET
                    || term.statId >= BinderIds.STAT_COUNT
            ) revert InvalidArtDefinition();
        }
    }

    function _pageVersions(uint16[] storage source, uint256 offset, uint256 limit) internal view returns (uint16[] memory) {
        uint256 sourceLength = source.length;
        if (offset >= sourceLength || limit == 0) return new uint16[](0);
        uint256 available = sourceLength - offset;
        uint256 pageLength = limit < available ? limit : available;
        uint16[] memory page = new uint16[](pageLength);
        for (uint256 i; i < pageLength; ++i) page[i] = source[offset + i];
        return page;
    }

    function _requireArt(uint32 artId) internal view {
        if (!_artExists[artId]) revert ArtDoesNotExist(artId);
    }

    function _requireArtVersion(uint32 artId, uint16 version) internal view {
        _requireArt(artId);
        if (!_versionExists[artId][version]) revert ArtVersionDoesNotExist(artId, version);
    }
}
