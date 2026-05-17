// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-4.8/access/AccessControl.sol";
import "./supportContract/binderStructs.sol";


contract Book0fLife is AccessControl {
    // Class data
    mapping(uint256 => string) private _classNames;
    mapping(uint256 => string) private _rarities;
    mapping(uint256 => binderStructs.ClassConfig) private _classConfigs;
    mapping(uint256 => uint16) public classVersion;

    // Track Class Ids and Fusion Keys
    uint256[] private _allClassIds;
    mapping(uint256 => bool) private _classExists;

    // Track Fusion Recipes && Fusion recipe: sorted(class1, class2) → outcome
    binderStructs.ClassPair[] private _allFusionPairs;
    mapping(uint256 => mapping(uint256 => bool)) private _fusionPairExists;
    mapping(uint256 => mapping(uint256 => binderStructs.FusionRecipe)) private _fusionRecipe;

    // Events
    event ConfigRoleChanged(address indexed triggeredBy, address indexed newConfigAdmin);
    event FusionMinterRoleChanged(address indexed triggeredBy, address indexed newFusionMinter);

    bytes32 public constant CONFIG_ROLE = keccak256("CONFIG_ROLE");
    bytes32 public constant FUSION_MINTER = keccak256("FUSION_MINTER");

    address public currentConfigAdmin;
    address public currentFusionMinter;

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(CONFIG_ROLE, msg.sender);
        _grantRole(FUSION_MINTER, msg.sender);
    }

    // === Class Setup ===

    function addNewClass(
        uint256 classId, string calldata name, string calldata rarity, binderStructs.ClassConfig calldata config, uint16 version
    ) external onlyRole(CONFIG_ROLE) {
        require(classId != 0, "Invalid classId");
        require(bytes(_classNames[classId]).length == 0, "Already exists");

        _classNames[classId] = name;
        _rarities[classId] = rarity;
        _classConfigs[classId] = config;
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

        _classConfigs[classId] = binderStructs.ClassConfig({
            minStats: minStats,
            maxStats: maxStats,
            totalPoints: totalPoints,
            hpPerVit: hpPerVit,
            mpPerWis: mpPerWis
        });

        classVersion[classId] = newVersion;
    }

    function removeClass(uint256 classId) external onlyRole(CONFIG_ROLE) {
        delete _classNames[classId];
        delete _rarities[classId];
        delete _classConfigs[classId];
        delete classVersion[classId];
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
            _allFusionPairs.push(binderStructs.ClassPair(class1, class2));
            _fusionPairExists[a][b] = true;
        } 
    }

    function removeFusionRecipe(uint256 class1, uint256 class2) external onlyRole(CONFIG_ROLE) {
        (uint256 a, uint256 b) = _sortMi(class1, class2);
        delete _fusionRecipe[a][b];
    }

    // === View Access ===

    function getClassName(uint256 classId) external view returns (string memory) {
        return _classNames[classId];
    }

    function getClassRarity(uint256 classId) external view returns (string memory) {
        return _rarities[classId];
    }

    function getClassConfig(uint256 classId) external view returns (binderStructs.ClassConfig memory) {
        return _classConfigs[classId];
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
            configs[i] = _classConfigs[_allClassIds[i]];
        }
        return configs;
    }

    function getAllSimpleFusionRecipes() external view onlyRole(DEFAULT_ADMIN_ROLE) returns (binderStructs.AllSimpleFusionRecipe[] memory) {
        uint256 len = _allFusionPairs.length;
        binderStructs.AllSimpleFusionRecipe[] memory result = new binderStructs.AllSimpleFusionRecipe[](len);
        for (uint i = 0; i < len; i++) {
            binderStructs.ClassPair memory pair = _allFusionPairs[i];
            binderStructs.FusionRecipe memory recipe = _fusionRecipe[pair.class1][pair.class2];


            result[i] = binderStructs.AllSimpleFusionRecipe({
                class1: pair.class1,
                class2: pair.class2,
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
