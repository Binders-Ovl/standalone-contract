// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-4.8/access/AccessControl.sol";
import "./supportContract/binderStructs.sol";


contract Book0fLife is AccessControl {
    // Class data
    mapping(uint256 => string) private _classNames;
    mapping(uint256 => string) private _rarities;
    mapping(uint256 => uint16) public classRarityId;
    mapping(uint256 => mapping(uint16 => binderStructs.ClassConfig)) private _classConfigsByVersion;
    mapping(uint256 => mapping(uint16 => bool)) private _configVersionExists;
    mapping(uint256 => uint16) public classVersion;

    // Transitional rarity/pool index. The current mint path still uses string rarity labels.
    mapping(uint16 => uint256[]) private _classesByRarityId;
    mapping(uint256 => uint256) private _rarityIndexPlusOne;

    /*
     * Reserved rarity/pool ID ranges:
     *   0       = Neutral / Global
     *   1-10    = Weatonia
     *   11-20   = Urtaka
     *   21-30   = Mitrevar
     *   31-40   = Listhar
     *   41-50   = Maritime / Archipelago
     *   51-60   = Empire faction
     *   61-70   = Northern high-tech faction
     *   80-199  = Reserved for new nations
     *   200-249 = Global special pools
     *   250-299 = Seasonal/event pools
     */

    // Track Class Ids and Fusion Keys
    uint256[] private _allClassIds;
    mapping(uint256 => bool) private _classExists;

    // Track Fusion Recipes && Fusion recipe: sorted(class1, class2) → outcome
    binderStructs.ClassPair[] private _allFusionPairs;
    mapping(uint256 => mapping(uint256 => bool)) private _fusionPairExists;
    // Stores array index + 1 so zero means no tracked pair.
    mapping(uint256 => mapping(uint256 => uint256)) private _fusionPairIndex;
    mapping(uint256 => mapping(uint256 => binderStructs.FusionRecipe)) private _fusionRecipe;

    // Events
    event ConfigRoleChanged(address indexed triggeredBy, address indexed newConfigAdmin);
    event FusionMinterRoleChanged(address indexed triggeredBy, address indexed newFusionMinter);

    bytes32 public constant CONFIG_ROLE = keccak256("CONFIG_ROLE");
    bytes32 public constant FUSION_MINTER = keccak256("FUSION_MINTER");

    address public currentConfigAdmin;
    address public currentFusionMinter;

    constructor() {
        address deployer = msg.sender;
        currentConfigAdmin = deployer;
        currentFusionMinter = deployer;

        _grantRole(DEFAULT_ADMIN_ROLE, deployer);
        _grantRole(CONFIG_ROLE, deployer);
        _grantRole(FUSION_MINTER, deployer);
    }

    // === Class Setup ===

    function addNewClass(
        uint256 classId, string calldata name, string calldata rarity, binderStructs.ClassConfig calldata config, uint16 version
    ) external onlyRole(CONFIG_ROLE) {
        require(classId != 0, "Invalid classId");
        require(bytes(_classNames[classId]).length == 0, "Already exists");
        require(version > 0, "Invalid version");
        _validateClassConfig(config);

        _classNames[classId] = name;
        _rarities[classId] = rarity;
        _addClassToRarityId(classId, 0);
        _classConfigsByVersion[classId][version] = config;
        _configVersionExists[classId][version] = true;
        classVersion[classId] = version;

        if (!_classExists[classId]) {
            _allClassIds.push(classId);
            _classExists[classId] = true;
        }
    }

    function upgradeClassConfig(
        uint256 classId, uint16 totalPoints, uint8[8] calldata minStats,
        uint8[8] calldata maxStats, uint16 hpPerVit, uint16 mpPerWis, uint16 newVersion
    ) external onlyRole(CONFIG_ROLE) {
        require(bytes(_classNames[classId]).length > 0, "Class does not exist");
        require(newVersion > classVersion[classId], "Invalid version");

        binderStructs.ClassConfig memory newConfig = binderStructs.ClassConfig({
            minStats: minStats,
            maxStats: maxStats,
            totalPoints: totalPoints,
            hpPerVit: hpPerVit,
            mpPerWis: mpPerWis
        });
        _validateClassConfig(newConfig);

        _classConfigsByVersion[classId][newVersion] = newConfig;
        _configVersionExists[classId][newVersion] = true;
        classVersion[classId] = newVersion;
    }

    /// @dev Enforces the arithmetic invariants required by all stat allocators.
    function _validateClassConfig(binderStructs.ClassConfig memory config) internal pure {
        uint256 totalCapacity;

        for (uint256 i = 0; i < 8; i++) {
            uint256 minStat = config.minStats[i];
            uint256 maxStat = config.maxStats[i];
            require(minStat <= maxStat, "Invalid stat range");
            totalCapacity += maxStat - minStat;
        }

        require(config.totalPoints <= totalCapacity, "Points exceed stat capacity");
        require(uint256(config.maxStats[4]) * config.hpPerVit <= type(uint16).max, "HP exceeds uint16");
        require(uint256(config.maxStats[5]) * config.mpPerWis <= type(uint16).max, "MP exceeds uint16");
    }

    function removeClass(uint256 classId) external onlyRole(CONFIG_ROLE) {
        require(bytes(_classNames[classId]).length > 0, "Class does not exist");
        _removeClassFromRarityId(classId);
        delete _classNames[classId];
        delete _rarities[classId];
        delete classVersion[classId];
    }

    /// @notice Assigns a class to a rarity/pool ID without changing its display label.
    /// @dev This transitional index will be refactored with the full rarityId migration.
    function setClassRarityId(uint256 classId, uint16 newRarityId) external onlyRole(CONFIG_ROLE) {
        require(bytes(_classNames[classId]).length > 0, "Class does not exist");
        uint16 oldRarityId = classRarityId[classId];
        if (oldRarityId == newRarityId) return;

        _removeClassFromRarityId(classId);
        _addClassToRarityId(classId, newRarityId);
    }

    function _addClassToRarityId(uint256 classId, uint16 rarityId) internal {
        _classesByRarityId[rarityId].push(classId);
        _rarityIndexPlusOne[classId] = _classesByRarityId[rarityId].length;
        classRarityId[classId] = rarityId;
    }

    function _removeClassFromRarityId(uint256 classId) internal {
        uint16 rarityId = classRarityId[classId];
        uint256[] storage classIds = _classesByRarityId[rarityId];
        uint256 index = _rarityIndexPlusOne[classId] - 1;
        uint256 lastIndex = classIds.length - 1;

        if (index != lastIndex) {
            uint256 lastClassId = classIds[lastIndex];
            classIds[index] = lastClassId;
            _rarityIndexPlusOne[lastClassId] = index + 1;
        }

        classIds.pop();
        delete _rarityIndexPlusOne[classId];
        delete classRarityId[classId];
    }

    // === Fusion Recipes === 

    /**@dev Adds or overwrites a fusion recipe for a given pair of classes
     *      will overwrite any existing recipe for the given pair
     *      ToBe called by configRole thru scaleOfBalance.sol
     */
    function setFusionRecipe(
        uint256 class1, uint256 class2, uint256[] calldata classIds, uint16[] calldata multiProbChance, uint16 successChance
    ) external onlyRole(CONFIG_ROLE) {
        require(successChance > 0 && successChance <= 10000, "Invalid successChance");
        require(classIds.length > 0, "Invalid outcomes");
        require(classIds.length == multiProbChance.length, "Mismatched outcomes");


        (uint256 a, uint256 b) = _sortMi(class1, class2);

        // Reset old Recipe due to usage of .push
        delete _fusionRecipe[a][b].outcomes;

        // Weight Validation to be > 0, and constructing FusionOutcome[]
        uint256 totalWeight = 0;
        
        /* Refactor it due to .solc inability to compile memory[] write to storage[]
        binderStructs.FusionOutcome[] memory outcomes = new binderStructs.FusionOutcome[](classIds.length); */

        for (uint i = 0; i < classIds.length; i++) {
            require(classIds[i] != 0, "Invalid ClassId");
            require(multiProbChance[i] > 0, " need > 0");
            
            //.using Push helper to manually reWrite eaach array value to storage
            _addFusionOutcome(a, b, classIds[i], multiProbChance[i]);

            /* * Same Refactoring due to inability to compile memory[] to storage[] 
            outcomes[i] = binderStructs.FusionOutcome({
                outcomeClassId: classIds[i],
                multiProbChance: multiProbChance[i] */

            totalWeight += multiProbChance[i]; // the whole total weight shud be 10,000 or 100%
        }

        require(totalWeight == 10000, "total need to be 10,000");

        //Setting succesCchance Separately
        _fusionRecipe[a][b].successChance = successChance;



        /* Refactoring due to inability to write memory[] to storage[]
            _fusionRecipe[a][b] = binderStructs.FusionRecipe({
            outcomes: outcomes,
            successChance: successChance
        }); */

        // Pair Tracker
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
            uint256 pairIndex = _fusionPairIndex[a][b] - 1;
            uint256 lastIndex = _allFusionPairs.length - 1;

            if (pairIndex != lastIndex) {
                binderStructs.ClassPair memory lastPair = _allFusionPairs[lastIndex];
                _allFusionPairs[pairIndex] = lastPair;
                _fusionPairIndex[lastPair.class1][lastPair.class2] = pairIndex + 1;
            }

            _allFusionPairs.pop();
            delete _fusionPairIndex[a][b];
            _fusionPairExists[a][b] = false;
        }
    }

    // === View Access ===

    function getClassName(uint256 classId) external view returns (string memory) {
        return _classNames[classId];
    }

    function getClassRarity(uint256 classId) external view returns (string memory) {
        return _rarities[classId];
    }

    /// @notice Returns all active class IDs assigned to a transitional rarity/pool ID.
    /// @dev This will change or be refactored to accommodate nation-specific pools in the future.
    function getClassesByRarityId(uint16 rarityId) external view returns (uint256[] memory) {
        return _classesByRarityId[rarityId];
    }

    /// @notice Compatibility lookup for the current string-based mint path.
    /// @dev Option B will replace this with rarityId-based selection after pool assignments are finalized.
    function getClassesByRarity(string calldata rarity) external view returns (uint256[] memory) {
        bytes32 rarityHash = keccak256(bytes(rarity));
        uint256 matchCount;

        for (uint256 i = 0; i < _allClassIds.length; i++) {
            uint256 classId = _allClassIds[i];
            if (
                bytes(_classNames[classId]).length > 0 &&
                keccak256(bytes(_rarities[classId])) == rarityHash
            ) {
                matchCount++;
            }
        }

        uint256[] memory classIds = new uint256[](matchCount);
        uint256 resultIndex;
        for (uint256 i = 0; i < _allClassIds.length; i++) {
            uint256 classId = _allClassIds[i];
            if (
                bytes(_classNames[classId]).length > 0 &&
                keccak256(bytes(_rarities[classId])) == rarityHash
            ) {
                classIds[resultIndex++] = classId;
            }
        }

        return classIds;
    }

    function getClassConfig(uint256 classId) external view returns (binderStructs.ClassConfig memory) {
        return _classConfigsByVersion[classId][classVersion[classId]];
    }

    function getClassConfigAtVersion(uint256 classId, uint16 version)
        external
        view
        returns (binderStructs.ClassConfig memory)
    {
        require(_configVersionExists[classId][version], "Unknown config version");
        return _classConfigsByVersion[classId][version];
    }

    function getFusionRecipe(uint256 class1, uint256 class2) external view returns (binderStructs.FusionRecipe memory) {
        require(
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender) || msg.sender == currentFusionMinter, 
            "Access denied"
        );
        (uint256 a, uint256 b) = _sortMi(class1, class2);
        return _fusionRecipe[a][b];
    }

    function getClassVersion(uint256 classId) external view returns (uint16) {
        return classVersion[classId];
    }

    // === Get All Data ===

    function getAllClasses() external view onlyRole(DEFAULT_ADMIN_ROLE) returns (binderStructs.ClassMeta[] memory) {
        uint256 len = _allClassIds.length;
        binderStructs.ClassMeta[] memory result = new binderStructs.ClassMeta[](len);
        for (uint i = 0; i < len; i++) {
            uint256 id = _allClassIds[i];
            result[i] = binderStructs.ClassMeta({
                classId: id,
                name: _classNames[id],
                rarity: _rarities[id]
            });
        }
        return result;
    }

     function getAllClassConfigs() external view onlyRole(DEFAULT_ADMIN_ROLE) returns (binderStructs.ClassConfig[] memory) {
        uint256 len = _allClassIds.length;
        binderStructs.ClassConfig[] memory configs = new binderStructs.ClassConfig[](len);
        for (uint i = 0; i < len; i++) {
            uint256 classId = _allClassIds[i];
            configs[i] = _classConfigsByVersion[classId][classVersion[classId]];
        }
        return configs;
    }

    function getAllSimpleFusionRecipes() external view onlyRole(DEFAULT_ADMIN_ROLE) returns (binderStructs.AllSimpleFusionRecipe[] memory) {
        uint256 len = _allFusionPairs.length;
        binderStructs.AllSimpleFusionRecipe[] memory result = new binderStructs.AllSimpleFusionRecipe[](len);
        for (uint i = 0; i < len; i++) {
            binderStructs.ClassPair memory pair = _allFusionPairs[i];
            (uint256 a, uint256 b) = _sortMi(pair.class1, pair.class2);
            binderStructs.FusionRecipe memory recipe = _fusionRecipe[a][b];

            result[i] = binderStructs.AllSimpleFusionRecipe({
                class1: a,
                class2: b,
                recipe: recipe
            });
        }
        return result;
    }

    // === Internal ===

    //.sorting Helper
    function _sortMi(uint256 a, uint256 b) internal pure returns (uint256, uint256) {
        return a < b ? (a, b) : (b, a);
    }

    //.helper for write memory to storage
    function _addFusionOutcome(uint256 a, uint256 b, uint256 classId, uint16 chance) internal {
        _fusionRecipe[a][b].outcomes.push(binderStructs.FusionOutcome({
            outcomeClassId: classId,
            multiProbChance: chance
        }));
    }
    

    // === Admin Functions ===

    function changeConfigRole(address newConfigRole) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newConfigRole != address(0), "Invalid address");
        require(currentConfigAdmin != newConfigRole, "Same address");

        revokeRole(CONFIG_ROLE, currentConfigAdmin);
        grantRole(CONFIG_ROLE, newConfigRole);

        currentConfigAdmin = newConfigRole;

        emit ConfigRoleChanged(msg.sender, newConfigRole);
    }

    function changeFusionMinterRole(address newFusionMinterRole) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newFusionMinterRole!= address(0), "Invalid address");
        require(currentFusionMinter!= newFusionMinterRole, "Same address");

        revokeRole(FUSION_MINTER, currentFusionMinter);
        grantRole(FUSION_MINTER, newFusionMinterRole);

        currentFusionMinter = newFusionMinterRole;

        emit FusionMinterRoleChanged(msg.sender, newFusionMinterRole);
    }
}
