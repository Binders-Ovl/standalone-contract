// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-4.8/access/AccessControl.sol";

/// @notice Canonical registry for nations, player allegiance, and diplomatic relations.
/// @dev nationId 0 is permanently reserved for General / No Nation.
contract AllegianceRegistry is AccessControl {
    bytes32 public constant CONFIG_ROLE = keccak256("CONFIG_ROLE");

    uint8 public constant RELATION_NEUTRAL = 0;
    uint8 public constant RELATION_FRIENDLY = 1;
    uint8 public constant RELATION_HOSTILE = 2;
    uint32 public constant DEFAULT_ALLEGIANCE_COOLDOWN = 29 days;

    mapping(uint8 => bool) private _nationExists;
    mapping(uint8 => bool) private _nationActive;
    mapping(uint8 => string) private _nationNames;
    mapping(address => uint8) private _playerNation;
    mapping(address => uint48) private _nextAllegianceChangeAt;
    mapping(uint8 => mapping(uint8 => uint8)) private _nationRelation;

    uint32 public allegianceCooldown = DEFAULT_ALLEGIANCE_COOLDOWN;

    event NationRegistered(uint8 indexed nationId, string name);
    event NationNameUpdated(uint8 indexed nationId, string name);
    event NationActiveStatusChanged(uint8 indexed nationId, bool active);
    event PlayerJoinedNation(address indexed player, uint8 indexed nationId, uint48 nextChangeAt);
    event AllegianceChanged(address indexed player, uint8 indexed oldNationId, uint8 indexed newNationId, uint48 nextChangeAt);
    event AllegianceCooldownChanged(uint32 previousCooldown, uint32 newCooldown);
    event NationRelationChanged(uint8 indexed nationA, uint8 indexed nationB, uint8 relationId);

    error InvalidNationId();
    error NationAlreadyExists(uint8 nationId);
    error NationDoesNotExist(uint8 nationId);
    error NationInactive(uint8 nationId);
    error EmptyNationName();
    error AlreadyAligned(uint8 currentNationId);
    error NotYetAligned();
    error SameAllegiance();
    error AllegianceCooldownActive(uint48 nextChangeAt);
    error InvalidRelation(uint8 relationId);
    error SameNationRelation();

    constructor(address initialOwner) {
        require(initialOwner != address(0), "Invalid owner");
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
        _grantRole(CONFIG_ROLE, initialOwner);

        _registerNation(1, "Weatonia");
        _registerNation(2, "Mitrevar");
        _registerNation(3, "Urtaka");
    }

    function registerNation(uint8 nationId, string calldata name) external onlyRole(CONFIG_ROLE) {
        _registerNation(nationId, name);
    }

    function setNationName(uint8 nationId, string calldata name) external onlyRole(CONFIG_ROLE) {
        _requireNationExists(nationId);
        if (bytes(name).length == 0) revert EmptyNationName();
        _nationNames[nationId] = name;
        emit NationNameUpdated(nationId, name);
    }

    function setNationActive(uint8 nationId, bool active) external onlyRole(CONFIG_ROLE) {
        _requireNationExists(nationId);
        _nationActive[nationId] = active;
        emit NationActiveStatusChanged(nationId, active);
    }

    function setAllegianceCooldown(uint32 newCooldown) external onlyRole(CONFIG_ROLE) {
        uint32 previousCooldown = allegianceCooldown;
        allegianceCooldown = newCooldown;
        emit AllegianceCooldownChanged(previousCooldown, newCooldown);
    }

    /// @notice First-time player allegiance registration. An unregistered wallet naturally has nation 0.
    function joinNation(uint8 nationId) external {
        if (_playerNation[msg.sender] != 0) revert AlreadyAligned(_playerNation[msg.sender]);
        _requireActiveNation(nationId);

        uint48 nextChangeAt = _snapshotNextChangeAt();
        _playerNation[msg.sender] = nationId;
        _nextAllegianceChangeAt[msg.sender] = nextChangeAt;
        emit PlayerJoinedNation(msg.sender, nationId, nextChangeAt);
    }

    function changeAllegiance(uint8 newNationId) external {
        uint8 oldNationId = _playerNation[msg.sender];
        if (oldNationId == 0) revert NotYetAligned();
        _requireActiveNation(newNationId);
        if (newNationId == oldNationId) revert SameAllegiance();

        uint48 currentLock = _nextAllegianceChangeAt[msg.sender];
        if (block.timestamp < currentLock) revert AllegianceCooldownActive(currentLock);

        uint48 nextChangeAt = _snapshotNextChangeAt();
        _playerNation[msg.sender] = newNationId;
        _nextAllegianceChangeAt[msg.sender] = nextChangeAt;
        emit AllegianceChanged(msg.sender, oldNationId, newNationId, nextChangeAt);
    }

    function setNationRelation(uint8 nationA, uint8 nationB, uint8 relationId) external onlyRole(CONFIG_ROLE) {
        _requireNationExists(nationA);
        _requireNationExists(nationB);
        if (nationA == nationB) revert SameNationRelation();
        if (relationId > RELATION_HOSTILE) revert InvalidRelation(relationId);

        _nationRelation[nationA][nationB] = relationId;
        _nationRelation[nationB][nationA] = relationId;
        emit NationRelationChanged(nationA, nationB, relationId);
    }

    function getPlayerNation(address player) external view returns (uint8) {
        return _playerNation[player];
    }

    function getNextAllegianceChangeAt(address player) external view returns (uint48) {
        return _nextAllegianceChangeAt[player];
    }

    function isNationRegistered(uint8 nationId) external view returns (bool) {
        return nationId != 0 && _nationExists[nationId];
    }

    function isNationActive(uint8 nationId) external view returns (bool) {
        return nationId != 0 && _nationActive[nationId];
    }

    function getNationName(uint8 nationId) external view returns (string memory) {
        if (nationId == 0) return "General";
        _requireNationExists(nationId);
        return _nationNames[nationId];
    }

    function getNationRelation(uint8 nationA, uint8 nationB) external view returns (uint8) {
        _requireNationExists(nationA);
        _requireNationExists(nationB);
        if (nationA == nationB) return RELATION_FRIENDLY;
        return _nationRelation[nationA][nationB];
    }

    function _registerNation(uint8 nationId, string memory name) internal {
        if (nationId == 0) revert InvalidNationId();
        if (_nationExists[nationId]) revert NationAlreadyExists(nationId);
        if (bytes(name).length == 0) revert EmptyNationName();

        _nationExists[nationId] = true;
        _nationActive[nationId] = true;
        _nationNames[nationId] = name;
        emit NationRegistered(nationId, name);
    }

    function _requireNationExists(uint8 nationId) internal view {
        if (nationId == 0 || !_nationExists[nationId]) revert NationDoesNotExist(nationId);
    }

    function _requireActiveNation(uint8 nationId) internal view {
        _requireNationExists(nationId);
        if (!_nationActive[nationId]) revert NationInactive(nationId);
    }

    function _snapshotNextChangeAt() internal view returns (uint48) {
        return uint48(block.timestamp + allegianceCooldown);
    }
}
