// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-4.8/access/AccessControl.sol";
import "./supportContract/binderStructs.sol";
import "./interfaces/IAllegianceRegistry.sol";

/// @notice Canonical class configuration, rarity registry, and mint-pool index.
/// @dev A class has one rarity but may belong to many non-General nation pools.
contract Book0fLife is AccessControl {
    bytes32 public constant CONFIG_ROLE = keccak256("CONFIG_ROLE");
    bytes32 public constant FUSION_MINTER = keccak256("FUSION_MINTER");

    uint32 public constant ACQ_NORMAL_MINT = uint32(1) << 0;
    uint32 public constant ACQ_FUSION = uint32(1) << 1;
    uint32 public constant ACQ_QUEST = uint32(1) << 2;
    uint32 public constant ACQ_EVENT_MINT = uint32(1) << 3;
    uint32 public constant ACQ_CRAFTING = uint32(1) << 4;
    uint32 public constant ACQ_AIRDROP = uint32(1) << 5;

    mapping(uint256 => string) private _classNames;
    mapping(uint256 => uint8) private _classRarityId;
    mapping(uint8 => string) private _rarityNames;
    mapping(uint8 => bool) private _rarityExists;
    uint8[] private _allRarityIds;
    mapping(uint256 => mapping(uint16 => binderStructs.ClassConfig)) private _classConfigsByVersion;
    mapping(uint256 => mapping(uint16 => bool)) private _configVersionExists;
    mapping(uint256 => uint16[]) private _classConfigVersions;
    mapping(uint256 => uint16) public classVersion;

    // nationId => rarityId => class IDs. Index values are index + 1 for O(1) removal.
    mapping(uint8 => mapping(uint8 => uint256[])) private _classesByNationRarity;
    mapping(uint8 => mapping(uint8 => mapping(uint256 => uint256))) private _poolIndexPlusOne;
    mapping(uint256 => uint8[]) private _classNationMemberships;
    mapping(uint256 => mapping(uint8 => uint256)) private _classNationIndexPlusOne;

    mapping(uint256 => uint32) private _classAcquisitionFlags;
    mapping(uint256 => binderStructs.EventMintSchedule) private _eventMintSchedule;
    mapping(uint256 => uint8[]) private _eventNationRotation;

    uint256[] private _allClassIds;
    mapping(uint256 => bool) private _classExists;
    mapping(uint256 => bool) private _classEnabled;
    mapping(uint256 => uint256) private _classIndexPlusOne;

    binderStructs.ClassPair[] private _allFusionPairs;
    mapping(uint256 => mapping(uint256 => bool)) private _fusionPairExists;
    mapping(uint256 => mapping(uint256 => uint256)) private _fusionPairIndex;
    mapping(uint256 => mapping(uint256 => binderStructs.FusionRecipe)) private _fusionRecipe;

    address public currentConfigAdmin;
    address public currentFusionMinter;
    IAllegianceRegistry public allegianceRegistry;

    event ConfigRoleChanged(address indexed triggeredBy, address indexed newConfigAdmin);
    event FusionMinterRoleChanged(address indexed triggeredBy, address indexed newFusionMinter);
    event AllegianceRegistryUpdated(address indexed registry);
    event RarityRegistered(uint8 indexed rarityId, string displayName);
    event RarityNameUpdated(uint8 indexed rarityId, string displayName);
    event ClassEnabledChanged(uint256 indexed classId, bool enabled);
    event ClassRarityChanged(uint256 indexed classId, uint8 indexed oldRarityId, uint8 indexed newRarityId);
    event ClassNationAssigned(uint256 indexed classId, uint8 indexed nationId, uint8 rarityId);
    event ClassNationRemoved(uint256 indexed classId, uint8 indexed nationId, uint8 rarityId);
    event ClassAcquisitionFlagsChanged(uint256 indexed classId, uint32 flags);
    event EventMintScheduleChanged(uint256 indexed classId, bool enabled, uint48 startTime, uint48 endTime, uint32 slotDuration);
    event EventNationRotationChanged(uint256 indexed classId, uint8[] nationIds);

    error InvalidClassId();
    error ClassAlreadyExists(uint256 classId);
    error ClassDoesNotExist(uint256 classId);
    error InvalidRarityId();
    error RarityAlreadyRegistered(uint8 rarityId);
    error RarityNotRegistered(uint8 rarityId);
    error EmptyDisplayName();
    error InvalidNationId(uint8 nationId);
    error ClassAlreadyAssignedToNation(uint256 classId, uint8 nationId);
    error ClassNotAssignedToNation(uint256 classId, uint8 nationId);
    error GeneralMembershipConflict(uint256 classId);
    error InvalidEventSchedule();
    error DuplicateRotationNation(uint8 nationId);

    struct ClassImport {
        uint256 classId;
        string name;
        uint8 rarityId;
        binderStructs.ClassConfig config;
        uint16 version;
        bool enabled;
        uint32 acquisitionFlags;
    }

    struct FusionRecipeImport {
        uint256 class1;
        uint256 class2;
        uint256[] outcomeClassIds;
        uint16[] outcomeWeights;
        uint16 successChance;
    }

    constructor() {
        address deployer = msg.sender;
        currentConfigAdmin = deployer;
        currentFusionMinter = deployer;
        _grantRole(DEFAULT_ADMIN_ROLE, deployer);
        _grantRole(CONFIG_ROLE, deployer);
        _grantRole(FUSION_MINTER, deployer);
    }

    // === Registry wiring and rarity configuration ===

    function setAllegianceRegistry(address registry) external onlyRole(CONFIG_ROLE) {
        require(registry != address(0), "Invalid registry");
        allegianceRegistry = IAllegianceRegistry(registry);
        emit AllegianceRegistryUpdated(registry);
    }

    function registerRarity(uint8 rarityId, string calldata displayName) external onlyRole(CONFIG_ROLE) {
        _registerRarity(rarityId, displayName);
    }

    function _registerRarity(uint8 rarityId, string memory displayName) internal {
        if (rarityId == 0) revert InvalidRarityId();
        if (_rarityExists[rarityId]) revert RarityAlreadyRegistered(rarityId);
        if (bytes(displayName).length == 0) revert EmptyDisplayName();
        _rarityExists[rarityId] = true;
        _rarityNames[rarityId] = displayName;
        _allRarityIds.push(rarityId);
        emit RarityRegistered(rarityId, displayName);
    }

    function setRarityName(uint8 rarityId, string calldata displayName) external onlyRole(CONFIG_ROLE) {
        _requireRarity(rarityId);
        if (bytes(displayName).length == 0) revert EmptyDisplayName();
        _rarityNames[rarityId] = displayName;
        emit RarityNameUpdated(rarityId, displayName);
    }

    // === Class setup ===

    function addNewClass(
        uint256 classId,
        string calldata name,
        uint8 rarityId,
        binderStructs.ClassConfig calldata config,
        uint16 version
    ) external onlyRole(CONFIG_ROLE) {
        _addNewClass(classId, name, rarityId, config, version, true, 0);
    }

    function _addNewClass(
        uint256 classId,
        string memory name,
        uint8 rarityId,
        binderStructs.ClassConfig memory config,
        uint16 version,
        bool enabled,
        uint32 acquisitionFlags
    ) internal {
        if (classId == 0) revert InvalidClassId();
        if (_classExists[classId]) revert ClassAlreadyExists(classId);
        _requireRarity(rarityId);
        require(bytes(name).length > 0, "Empty class name");
        require(version > 0, "Invalid version");
        _validateClassConfig(config);

        _classNames[classId] = name;
        _classRarityId[classId] = rarityId;
        _classConfigsByVersion[classId][version] = config;
        _configVersionExists[classId][version] = true;
        _classConfigVersions[classId].push(version);
        classVersion[classId] = version;
        _classExists[classId] = true;
        _classEnabled[classId] = enabled;
        _classAcquisitionFlags[classId] = acquisitionFlags;
        _allClassIds.push(classId);
        _classIndexPlusOne[classId] = _allClassIds.length;
    }

    function upgradeClassConfig(
        uint256 classId,
        uint16 totalPoints,
        uint8[8] calldata minStats,
        uint8[8] calldata maxStats,
        uint16 hpPerVit,
        uint16 mpPerWis,
        uint16 newVersion
    ) external onlyRole(CONFIG_ROLE) {
        _requireClass(classId);
        require(newVersion > classVersion[classId], "Invalid version");
        binderStructs.ClassConfig memory newConfig = binderStructs.ClassConfig({
            minStats: minStats,
            maxStats: maxStats,
            totalPoints: totalPoints,
            hpPerVit: hpPerVit,
            mpPerWis: mpPerWis
        });
        _addClassConfigVersion(classId, newConfig, newVersion);
    }

    function setClassRarityId(uint256 classId, uint8 newRarityId) external onlyRole(CONFIG_ROLE) {
        _requireClass(classId);
        _requireRarity(newRarityId);
        uint8 oldRarityId = _classRarityId[classId];
        if (oldRarityId == newRarityId) return;

        uint8[] memory nations = _classNationMemberships[classId];
        for (uint256 i = 0; i < nations.length; ++i) {
            _removeClassFromPool(classId, nations[i], oldRarityId);
        }
        _classRarityId[classId] = newRarityId;
        for (uint256 i = 0; i < nations.length; ++i) {
            _addClassToPool(classId, nations[i], newRarityId);
        }
        emit ClassRarityChanged(classId, oldRarityId, newRarityId);
    }

    function removeClass(uint256 classId) external onlyRole(CONFIG_ROLE) {
        _requireClass(classId);
        // Stable class IDs may be referenced by live NFTs and recipes. Retain all
        // records for migration/audit and deprecate instead of erasing history.
        _classEnabled[classId] = false;
        emit ClassEnabledChanged(classId, false);
    }

    function setClassEnabled(uint256 classId, bool enabled) external onlyRole(CONFIG_ROLE) {
        _requireClass(classId);
        _classEnabled[classId] = enabled;
        emit ClassEnabledChanged(classId, enabled);
    }

    /// @notice Chunk-safe migration import for rarity display records.
    function importRarities(uint8[] calldata rarityIds, string[] calldata displayNames) external onlyRole(CONFIG_ROLE) {
        require(rarityIds.length == displayNames.length, "Mismatched rarities");
        for (uint256 i; i < rarityIds.length; ++i) {
            _registerRarity(rarityIds[i], displayNames[i]);
        }
    }

    /// @notice Chunk-safe migration import for initial class records.
    function importClasses(ClassImport[] calldata classes) external onlyRole(CONFIG_ROLE) {
        for (uint256 i; i < classes.length; ++i) {
            ClassImport calldata classImport = classes[i];
            _addNewClass(
                classImport.classId,
                classImport.name,
                classImport.rarityId,
                classImport.config,
                classImport.version,
                classImport.enabled,
                classImport.acquisitionFlags
            );
        }
    }

    /// @notice Chunk-safe import of additional immutable class-config history.
    function importClassVersions(
        uint256 classId,
        uint16[] calldata versions,
        binderStructs.ClassConfig[] calldata configs
    ) external onlyRole(CONFIG_ROLE) {
        _requireClass(classId);
        require(versions.length == configs.length, "Mismatched versions");
        for (uint256 i; i < versions.length; ++i) {
            _addClassConfigVersion(classId, configs[i], versions[i]);
        }
    }

    /// @notice Chunk-safe import of class-to-nation pool memberships.
    function importClassNationMemberships(uint256[] calldata classIds, uint8[][] calldata nationIds)
        external
        onlyRole(CONFIG_ROLE)
    {
        require(classIds.length == nationIds.length, "Mismatched memberships");
        for (uint256 i; i < classIds.length; ++i) {
            for (uint256 j; j < nationIds[i].length; ++j) {
                _assignClassToNation(classIds[i], nationIds[i][j]);
            }
        }
    }

    /// @notice Chunk-safe import of current fusion recipes.
    function importFusionRecipes(FusionRecipeImport[] calldata recipes) external onlyRole(CONFIG_ROLE) {
        for (uint256 i; i < recipes.length; ++i) {
            FusionRecipeImport calldata recipe = recipes[i];
            _setFusionRecipe(
                recipe.class1, recipe.class2, recipe.outcomeClassIds, recipe.outcomeWeights, recipe.successChance
            );
        }
    }

    // === Nation / rarity pool membership ===

    function assignClassToNation(uint256 classId, uint8 nationId) external onlyRole(CONFIG_ROLE) {
        _assignClassToNation(classId, nationId);
    }

    function _assignClassToNation(uint256 classId, uint8 nationId) internal {
        _requireClass(classId);
        _requirePoolNation(nationId);
        if (_classNationIndexPlusOne[classId][nationId] != 0) {
            revert ClassAlreadyAssignedToNation(classId, nationId);
        }

        uint256 membershipCount = _classNationMemberships[classId].length;
        if ((nationId == 0 && membershipCount != 0) || (nationId != 0 && _classNationIndexPlusOne[classId][0] != 0)) {
            revert GeneralMembershipConflict(classId);
        }

        uint8 rarityId = _classRarityId[classId];
        _classNationMemberships[classId].push(nationId);
        _classNationIndexPlusOne[classId][nationId] = _classNationMemberships[classId].length;
        _addClassToPool(classId, nationId, rarityId);
        emit ClassNationAssigned(classId, nationId, rarityId);
    }

    function removeClassFromNation(uint256 classId, uint8 nationId) external onlyRole(CONFIG_ROLE) {
        _requireClass(classId);
        uint256 membershipIndex = _classNationIndexPlusOne[classId][nationId];
        if (membershipIndex == 0) revert ClassNotAssignedToNation(classId, nationId);

        uint8 rarityId = _classRarityId[classId];
        _removeClassFromPool(classId, nationId, rarityId);
        _removeNationMembership(classId, nationId, membershipIndex);
        emit ClassNationRemoved(classId, nationId, rarityId);
    }

    // === Class acquisition policy and event availability ===

    function setClassAcquisitionFlags(uint256 classId, uint32 flags) external onlyRole(CONFIG_ROLE) {
        _requireClass(classId);
        _classAcquisitionFlags[classId] = flags;
        emit ClassAcquisitionFlagsChanged(classId, flags);
    }

    function enableClassAcquisition(uint256 classId, uint32 flagMask) external onlyRole(CONFIG_ROLE) {
        _requireClass(classId);
        uint32 flags = _classAcquisitionFlags[classId] | flagMask;
        _classAcquisitionFlags[classId] = flags;
        emit ClassAcquisitionFlagsChanged(classId, flags);
    }

    function disableClassAcquisition(uint256 classId, uint32 flagMask) external onlyRole(CONFIG_ROLE) {
        _requireClass(classId);
        uint32 flags = _classAcquisitionFlags[classId] & ~flagMask;
        _classAcquisitionFlags[classId] = flags;
        emit ClassAcquisitionFlagsChanged(classId, flags);
    }

    function setEventMintSchedule(uint256 classId, binderStructs.EventMintSchedule calldata schedule) external onlyRole(CONFIG_ROLE) {
        _requireClass(classId);
        if (schedule.enabled && schedule.startTime == 0) revert InvalidEventSchedule();
        if (schedule.endTime != 0 && schedule.endTime <= schedule.startTime) revert InvalidEventSchedule();
        if (_eventNationRotation[classId].length != 0 && schedule.slotDuration == 0) revert InvalidEventSchedule();
        _eventMintSchedule[classId] = schedule;
        emit EventMintScheduleChanged(classId, schedule.enabled, schedule.startTime, schedule.endTime, schedule.slotDuration);
    }

    function setEventNationRotation(uint256 classId, uint8[] calldata nationIds) external onlyRole(CONFIG_ROLE) {
        _requireClass(classId);
        if (nationIds.length != 0 && _eventMintSchedule[classId].slotDuration == 0) revert InvalidEventSchedule();
        for (uint256 i = 0; i < nationIds.length; ++i) {
            if (nationIds[i] == 0 || address(allegianceRegistry) == address(0) || !allegianceRegistry.isNationRegistered(nationIds[i])) {
                revert InvalidNationId(nationIds[i]);
            }
            for (uint256 j = 0; j < i; ++j) {
                if (nationIds[j] == nationIds[i]) revert DuplicateRotationNation(nationIds[i]);
            }
        }
        _eventNationRotation[classId] = nationIds;
        emit EventNationRotationChanged(classId, nationIds);
    }

    /// @notice Determines class-level eligibility for a normal random mint.
    /// @dev Pool membership is checked by BinderLogic, which only reads General and the snapshotted nation pool.
    function isClassMintEligible(uint256 classId, uint8 playerNationId) external view returns (bool) {
        _requireClass(classId);
        if (!_classEnabled[classId]) return false;
        uint32 flags = _classAcquisitionFlags[classId];
        if ((flags & ACQ_NORMAL_MINT) != 0) return true;
        return _isClassEventMintEligible(classId, playerNationId, flags);
    }

    function isClassEventMintEligible(uint256 classId, uint8 playerNationId) external view returns (bool) {
        _requireClass(classId);
        if (!_classEnabled[classId]) return false;
        return _isClassEventMintEligible(classId, playerNationId, _classAcquisitionFlags[classId]);
    }

    // === Fusion recipes ===

    function setFusionRecipe(
        uint256 class1,
        uint256 class2,
        uint256[] calldata classIds,
        uint16[] calldata multiProbChance,
        uint16 successChance
    ) external onlyRole(CONFIG_ROLE) {
        _setFusionRecipe(class1, class2, classIds, multiProbChance, successChance);
    }

    function _setFusionRecipe(
        uint256 class1,
        uint256 class2,
        uint256[] calldata classIds,
        uint16[] calldata multiProbChance,
        uint16 successChance
    ) internal {
        _requireClass(class1);
        _requireClass(class2);
        require(successChance > 0 && successChance <= 10_000, "Invalid successChance");
        require(classIds.length > 0 && classIds.length == multiProbChance.length, "Mismatched outcomes");
        (uint256 a, uint256 b) = _sortMi(class1, class2);
        delete _fusionRecipe[a][b].outcomes;

        uint256 totalWeight;
        for (uint256 i = 0; i < classIds.length; ++i) {
            _requireClass(classIds[i]);
            require(multiProbChance[i] > 0, "Weight must be positive");
            _fusionRecipe[a][b].outcomes.push(binderStructs.FusionOutcome({
                outcomeClassId: classIds[i],
                multiProbChance: multiProbChance[i]
            }));
            totalWeight += multiProbChance[i];
        }
        require(totalWeight == 10_000, "Weights must sum to 10000");
        _fusionRecipe[a][b].successChance = successChance;
        if (!_fusionPairExists[a][b]) {
            _allFusionPairs.push(binderStructs.ClassPair(a, b));
            _fusionPairExists[a][b] = true;
            _fusionPairIndex[a][b] = _allFusionPairs.length;
        }
    }

    function removeFusionRecipe(uint256 class1, uint256 class2) external onlyRole(CONFIG_ROLE) {
        (uint256 a, uint256 b) = _sortMi(class1, class2);
        delete _fusionRecipe[a][b];
        if (_fusionPairExists[a][b]) {
            uint256 index = _fusionPairIndex[a][b] - 1;
            uint256 lastIndex = _allFusionPairs.length - 1;
            if (index != lastIndex) {
                binderStructs.ClassPair memory lastPair = _allFusionPairs[lastIndex];
                _allFusionPairs[index] = lastPair;
                _fusionPairIndex[lastPair.class1][lastPair.class2] = index + 1;
            }
            _allFusionPairs.pop();
            delete _fusionPairIndex[a][b];
            delete _fusionPairExists[a][b];
        }
    }

    // === Views ===

    function getClassName(uint256 classId) external view returns (string memory) {
        _requireClass(classId);
        return _classNames[classId];
    }

    function getClassRarityId(uint256 classId) external view returns (uint8) {
        _requireClass(classId);
        return _classRarityId[classId];
    }

    function getRarityName(uint8 rarityId) external view returns (string memory) {
        _requireRarity(rarityId);
        return _rarityNames[rarityId];
    }

    function isRarityRegistered(uint8 rarityId) external view returns (bool) {
        return rarityId != 0 && _rarityExists[rarityId];
    }

    function getRarityCount() external view returns (uint256) {
        return _allRarityIds.length;
    }

    function getRarityIdAt(uint256 index) external view returns (uint8) {
        return _allRarityIds[index];
    }

    function getRarityIds(uint256 offset, uint256 limit) external view returns (uint8[] memory) {
        return _pageRarityIds(offset, limit);
    }

    function getClassCount() external view returns (uint256) {
        return _allClassIds.length;
    }

    function getClassIdAt(uint256 index) external view returns (uint256) {
        return _allClassIds[index];
    }

    function getClassIds(uint256 offset, uint256 limit) external view returns (uint256[] memory) {
        return _pageClassIds(offset, limit);
    }

    function isClassEnabled(uint256 classId) external view returns (bool) {
        _requireClass(classId);
        return _classEnabled[classId];
    }

    function getClassVersionCount(uint256 classId) external view returns (uint256) {
        _requireClass(classId);
        return _classConfigVersions[classId].length;
    }

    function getClassVersionAt(uint256 classId, uint256 index) external view returns (uint16) {
        _requireClass(classId);
        return _classConfigVersions[classId][index];
    }

    function getClassVersions(uint256 classId, uint256 offset, uint256 limit) external view returns (uint16[] memory) {
        _requireClass(classId);
        return _pageClassVersions(classId, offset, limit);
    }

    function getFusionPairCount() external view returns (uint256) {
        return _allFusionPairs.length;
    }

    function getFusionPairAt(uint256 index) external view returns (binderStructs.ClassPair memory) {
        return _allFusionPairs[index];
    }

    function getFusionPairs(uint256 offset, uint256 limit) external view returns (binderStructs.ClassPair[] memory) {
        uint256 sourceLength = _allFusionPairs.length;
        if (offset >= sourceLength || limit == 0) return new binderStructs.ClassPair[](0);
        uint256 available = sourceLength - offset;
        uint256 pageLength = limit < available ? limit : available;
        binderStructs.ClassPair[] memory page = new binderStructs.ClassPair[](pageLength);
        for (uint256 i; i < pageLength; ++i) page[i] = _allFusionPairs[offset + i];
        return page;
    }

    function getClassesByNationRarity(uint8 nationId, uint8 rarityId) external view returns (uint256[] memory) {
        return _classesByNationRarity[nationId][rarityId];
    }

    function getClassNations(uint256 classId) external view returns (uint8[] memory) {
        _requireClass(classId);
        return _classNationMemberships[classId];
    }

    function isClassAssignedToNation(uint256 classId, uint8 nationId) external view returns (bool) {
        _requireClass(classId);
        return _classNationIndexPlusOne[classId][nationId] != 0;
    }

    function getClassAcquisitionFlags(uint256 classId) external view returns (uint32) {
        _requireClass(classId);
        return _classAcquisitionFlags[classId];
    }

    function hasClassAcquisition(uint256 classId, uint32 flagMask) external view returns (bool) {
        _requireClass(classId);
        return _classEnabled[classId] && (_classAcquisitionFlags[classId] & flagMask) != 0;
    }

    function getEventMintSchedule(uint256 classId) external view returns (binderStructs.EventMintSchedule memory) {
        _requireClass(classId);
        return _eventMintSchedule[classId];
    }

    function getEventNationRotation(uint256 classId) external view returns (uint8[] memory) {
        _requireClass(classId);
        return _eventNationRotation[classId];
    }

    function getClassConfig(uint256 classId) external view returns (binderStructs.ClassConfig memory) {
        _requireClass(classId);
        return _classConfigsByVersion[classId][classVersion[classId]];
    }

    function getClassConfigAtVersion(uint256 classId, uint16 version) external view returns (binderStructs.ClassConfig memory) {
        _requireClass(classId);
        require(_configVersionExists[classId][version], "Unknown config version");
        return _classConfigsByVersion[classId][version];
    }

    function getClassVersion(uint256 classId) external view returns (uint16) {
        _requireClass(classId);
        return classVersion[classId];
    }

    function getFusionRecipe(uint256 class1, uint256 class2) external view returns (binderStructs.FusionRecipe memory) {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender) || msg.sender == currentFusionMinter, "Access denied");
        (uint256 a, uint256 b) = _sortMi(class1, class2);
        return _fusionRecipe[a][b];
    }

    function getAllClasses() external view onlyRole(DEFAULT_ADMIN_ROLE) returns (binderStructs.ClassMeta[] memory) {
        binderStructs.ClassMeta[] memory result = new binderStructs.ClassMeta[](_allClassIds.length);
        for (uint256 i = 0; i < _allClassIds.length; ++i) {
            uint256 classId = _allClassIds[i];
            result[i] = binderStructs.ClassMeta({
                classId: classId,
                name: _classNames[classId],
                rarityId: _classRarityId[classId]
            });
        }
        return result;
    }

    function getAllClassConfigs() external view onlyRole(DEFAULT_ADMIN_ROLE) returns (binderStructs.ClassConfig[] memory) {
        binderStructs.ClassConfig[] memory configs = new binderStructs.ClassConfig[](_allClassIds.length);
        for (uint256 i = 0; i < _allClassIds.length; ++i) {
            uint256 classId = _allClassIds[i];
            configs[i] = _classConfigsByVersion[classId][classVersion[classId]];
        }
        return configs;
    }

    function getAllSimpleFusionRecipes() external view onlyRole(DEFAULT_ADMIN_ROLE) returns (binderStructs.AllSimpleFusionRecipe[] memory) {
        binderStructs.AllSimpleFusionRecipe[] memory result = new binderStructs.AllSimpleFusionRecipe[](_allFusionPairs.length);
        for (uint256 i = 0; i < _allFusionPairs.length; ++i) {
            binderStructs.ClassPair memory pair = _allFusionPairs[i];
            (uint256 a, uint256 b) = _sortMi(pair.class1, pair.class2);
            result[i] = binderStructs.AllSimpleFusionRecipe({
                class1: a,
                class2: b,
                recipe: _fusionRecipe[a][b]
            });
        }
        return result;
    }

    // === Role management ===

    function changeConfigRole(address newConfigRole) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newConfigRole != address(0) && currentConfigAdmin != newConfigRole, "Invalid config role");
        revokeRole(CONFIG_ROLE, currentConfigAdmin);
        grantRole(CONFIG_ROLE, newConfigRole);
        currentConfigAdmin = newConfigRole;
        emit ConfigRoleChanged(msg.sender, newConfigRole);
    }

    function changeFusionMinterRole(address newFusionMinterRole) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newFusionMinterRole != address(0) && currentFusionMinter != newFusionMinterRole, "Invalid fusion minter");
        revokeRole(FUSION_MINTER, currentFusionMinter);
        grantRole(FUSION_MINTER, newFusionMinterRole);
        currentFusionMinter = newFusionMinterRole;
        emit FusionMinterRoleChanged(msg.sender, newFusionMinterRole);
    }

    // === Internal helpers ===

    function _addClassConfigVersion(
        uint256 classId,
        binderStructs.ClassConfig memory config,
        uint16 newVersion
    ) internal {
        _requireClass(classId);
        require(newVersion > classVersion[classId], "Invalid version");
        _validateClassConfig(config);
        _classConfigsByVersion[classId][newVersion] = config;
        _configVersionExists[classId][newVersion] = true;
        _classConfigVersions[classId].push(newVersion);
        classVersion[classId] = newVersion;
    }

    function _pageRarityIds(uint256 offset, uint256 limit) internal view returns (uint8[] memory) {
        uint256 sourceLength = _allRarityIds.length;
        if (offset >= sourceLength || limit == 0) return new uint8[](0);
        uint256 available = sourceLength - offset;
        uint256 pageLength = limit < available ? limit : available;
        uint8[] memory page = new uint8[](pageLength);
        for (uint256 i; i < pageLength; ++i) page[i] = _allRarityIds[offset + i];
        return page;
    }

    function _pageClassIds(uint256 offset, uint256 limit) internal view returns (uint256[] memory) {
        uint256 sourceLength = _allClassIds.length;
        if (offset >= sourceLength || limit == 0) return new uint256[](0);
        uint256 available = sourceLength - offset;
        uint256 pageLength = limit < available ? limit : available;
        uint256[] memory page = new uint256[](pageLength);
        for (uint256 i; i < pageLength; ++i) page[i] = _allClassIds[offset + i];
        return page;
    }

    function _pageClassVersions(uint256 classId, uint256 offset, uint256 limit) internal view returns (uint16[] memory) {
        uint16[] storage versions = _classConfigVersions[classId];
        uint256 sourceLength = versions.length;
        if (offset >= sourceLength || limit == 0) return new uint16[](0);
        uint256 available = sourceLength - offset;
        uint256 pageLength = limit < available ? limit : available;
        uint16[] memory page = new uint16[](pageLength);
        for (uint256 i; i < pageLength; ++i) page[i] = versions[offset + i];
        return page;
    }

    function _isClassEventMintEligible(uint256 classId, uint8 playerNationId, uint32 flags) internal view returns (bool) {
        if ((flags & ACQ_EVENT_MINT) == 0) return false;
        binderStructs.EventMintSchedule memory schedule = _eventMintSchedule[classId];
        if (!schedule.enabled || schedule.startTime == 0 || block.timestamp < schedule.startTime) return false;
        if (schedule.endTime != 0 && block.timestamp >= schedule.endTime) return false;

        uint8[] storage rotation = _eventNationRotation[classId];
        if (rotation.length == 0) return true;
        uint256 slot = (block.timestamp - schedule.startTime) / schedule.slotDuration;
        return playerNationId == rotation[slot % rotation.length];
    }

    function _addClassToPool(uint256 classId, uint8 nationId, uint8 rarityId) internal {
        _classesByNationRarity[nationId][rarityId].push(classId);
        _poolIndexPlusOne[nationId][rarityId][classId] = _classesByNationRarity[nationId][rarityId].length;
    }

    function _removeClassFromPool(uint256 classId, uint8 nationId, uint8 rarityId) internal {
        uint256 indexPlusOne = _poolIndexPlusOne[nationId][rarityId][classId];
        assert(indexPlusOne != 0);
        uint256[] storage classIds = _classesByNationRarity[nationId][rarityId];
        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = classIds.length - 1;
        if (index != lastIndex) {
            uint256 lastClassId = classIds[lastIndex];
            classIds[index] = lastClassId;
            _poolIndexPlusOne[nationId][rarityId][lastClassId] = index + 1;
        }
        classIds.pop();
        delete _poolIndexPlusOne[nationId][rarityId][classId];
    }

    function _removeNationMembership(uint256 classId, uint8 nationId, uint256 indexPlusOne) internal {
        uint8[] storage nations = _classNationMemberships[classId];
        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = nations.length - 1;
        if (index != lastIndex) {
            uint8 lastNationId = nations[lastIndex];
            nations[index] = lastNationId;
            _classNationIndexPlusOne[classId][lastNationId] = index + 1;
        }
        nations.pop();
        delete _classNationIndexPlusOne[classId][nationId];
    }

    function _removeClassId(uint256 classId) internal {
        uint256 index = _classIndexPlusOne[classId] - 1;
        uint256 lastIndex = _allClassIds.length - 1;
        if (index != lastIndex) {
            uint256 lastClassId = _allClassIds[lastIndex];
            _allClassIds[index] = lastClassId;
            _classIndexPlusOne[lastClassId] = index + 1;
        }
        _allClassIds.pop();
        delete _classIndexPlusOne[classId];
    }

    function _requireClass(uint256 classId) internal view {
        if (!_classExists[classId]) revert ClassDoesNotExist(classId);
    }

    function _requireRarity(uint8 rarityId) internal view {
        if (rarityId == 0) revert InvalidRarityId();
        if (!_rarityExists[rarityId]) revert RarityNotRegistered(rarityId);
    }

    function _requirePoolNation(uint8 nationId) internal view {
        if (nationId == 0) return;
        if (address(allegianceRegistry) == address(0) || !allegianceRegistry.isNationRegistered(nationId)) {
            revert InvalidNationId(nationId);
        }
    }

    function _validateClassConfig(binderStructs.ClassConfig memory config) internal pure {
        uint256 totalCapacity;
        for (uint256 i = 0; i < 8; ++i) {
            require(config.minStats[i] <= config.maxStats[i], "Invalid stat range");
            totalCapacity += config.maxStats[i] - config.minStats[i];
        }
        require(config.totalPoints <= totalCapacity, "Points exceed stat capacity");
        require(uint256(config.maxStats[4]) * config.hpPerVit <= type(uint16).max, "HP exceeds uint16");
        require(uint256(config.maxStats[5]) * config.mpPerWis <= type(uint16).max, "MP exceeds uint16");
    }

    function _sortMi(uint256 a, uint256 b) internal pure returns (uint256, uint256) {
        return a < b ? (a, b) : (b, a);
    }
}
