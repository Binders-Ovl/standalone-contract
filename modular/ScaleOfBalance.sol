// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./BinderData.sol";
import "./Book0fLife.sol";
import "./supportContract/binderStructs.sol";
import "@openzeppelin/contracts-4.8/access/AccessControl.sol";

contract ScaleOfBalance is AccessControl {
    BinderData public binderData;
    Book0fLife public book0fLife;

        // Track historical configurations for each class
    mapping(uint256 => binderStructs.ClassConfig[]) public classConfigHistory;
    
        // Events
    event logClassConfigUpdated(string indexed className, binderStructs.ClassConfig indexed config, uint256 indexed timestamp, uint256 blockNumber);
    event logFusionRecipeSet(uint256 class1, uint256 class2, uint256[] classIds, uint16[] multiProbChance, uint16 successChance);
    event upgradeSuccesful(address indexed user, uint256 indexed tokenId);
    event upgradeFailed(address indexed user, uint256 indexed tokenId, string reason);


    constructor(address _binderData, address _book0fLife) {
        binderData = BinderData(_binderData);
        book0fLife = Book0fLife(_book0fLife);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // ================== PUBLIC FUNCTIONS ==================
    // 1. Upgrade NFT By user
    function upgradeNFT(uint256 tokenId) external {
        require(binderData.ownerOf(tokenId) == msg.sender, "Not owner");

        //Gatekeep Ready to Arm
        binderStructs.NFTMetadata memory meta = binderData.getNFTDetails(tokenId);
        require(meta.configVersion != binderData.classVersion(meta.classId), "Already upgraded"); // Replace readyToArm to This to check if NFT updated or not

        // require(!binderData.getNFTDetails(tokenId).isReadyToArm, "Already upgraded"); // I need Change this as it is not defined in Structs
        _upgradeNFTInternal(tokenId);

        emit upgradeSuccesful(msg.sender, tokenId);
    }

    // 2. Batch upgrade NFTs by user
    function batchUpgradeNFTs(uint256[] calldata tokenIds) external {
        // -- Expecting specific list of token to upgrade 
        // ---- and the List shud be provided by game frontEnd!
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];

            try this.upgradeNFT(tokenId){
                // Success
            } catch Error(string memory reason) {
                // Failed
                emit upgradeFailed(msg.sender, tokenId, reason);
            } catch {
                emit upgradeFailed(msg.sender, tokenId, "Unknown Error");
            }
        }
    }


    // ================== CORE FUNCTIONALITY ==================
    function _upgradeNFTInternal(uint256 tokenId) internal {

        // 1. Get NFT metadata
        binderStructs.NFTMetadata memory meta = binderData.getNFTDetails(tokenId);
        
        // 2. Get configs
        binderStructs.ClassConfig memory oldConfig = classConfigHistory[meta.classId][classConfigHistory[meta.classId].length - 1];
        binderStructs.ClassConfig memory newConfig = book0fLife.getClassConfig(meta.classId);

        // 3. Calculate new stats
        binderStructs.StaticStats memory newStats = _calculateStats(
            oldConfig,
            newConfig,
            meta.staticStats
        );

        // 4. Calculate new HP/MP with ratio preservation
        uint16 newMaxHP = uint16(newStats.stats[4]) * newConfig.hpPerVit;
        uint16 newMaxMP = uint16(newStats.stats[5]) * newConfig.mpPerWis;

        uint16 newCurrentHP = _preserveRatio(meta.dynamicStats.currentHP, meta.dynamicStats.maxHP, newMaxHP);
        uint16 newCurrentMP = _preserveRatio(meta.dynamicStats.currentMP, meta.dynamicStats.maxMP, newMaxMP);

        binderStructs.DynamicStats memory dynStats = binderStructs.DynamicStats({
            maxHP: newMaxHP,
            maxMP: newMaxMP,
            currentHP: newCurrentHP,
            currentMP: newCurrentMP
        });
        // 5. Update Base contract
        binderData.updateNFTStats(
            tokenId,
            newStats,
            dynStats
        );
    }


    // ================== ADMIN FUNCTIONS ==================
    // 1. Update Class Config and mirror to binderData && book0fLife
    function updateClassConfig(uint256 classId, binderStructs.ClassConfig calldata newConfig) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // Rules and requirements
        require(classId !=0, "Invalid classId");
        require(bytes(book0fLife.getClassName(classId)).length > 0, "Class does not exist");

        for (uint8 s = 0; s < 8; s++) {
            require(newConfig.minStats[s] <= newConfig.maxStats[s], "Invalid stat range");
        }

        uint16 totalDelta;
        for (uint8 d = 0; d < 8; d++) {
            totalDelta += (newConfig.maxStats[d] - newConfig.minStats[d]);
        }
        // Gating the possible Total point to be 2/3 max of Maximum all Stats
        require(newConfig.totalPoints < (totalDelta * 67) / 100 , "totalPoints must be Lower than total delta");

        // Define versioning from both contracts
        uint16 bookVer = book0fLife.getClassVersion(classId);
        uint16 dataVer = binderData.classVersion(classId);

        // Save old config to history
        classConfigHistory[classId].push(book0fLife.getClassConfig(classId));

        // Update version
        uint16 newVersion;

        if (bookVer == dataVer) {
            newVersion = bookVer +1;
        } else {
            newVersion = (bookVer > dataVer ? bookVer : dataVer) + 1;
        }
        
        // Push new config to base contract
        book0fLife.upgradeClassConfig(
            classId,
            newConfig.totalPoints,
            newConfig.minStats,
            newConfig.maxStats,
            newConfig.hpPerVit,
            newConfig.mpPerWis,
            newVersion
        );

        // Mirror version to binderData
        binderData.setClassVersion(classId, newVersion);

        emit logClassConfigUpdated(book0fLife.getClassName(classId), newConfig, block.timestamp, block.number);
    }

    // 2. Add new Class Function
    function addNewClass(uint256 classId, string calldata name, string calldata rarity, binderStructs.ClassConfig calldata config) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // Requirement and Rules
        require(classId != 0, "Invalid classId");
        require(bytes(book0fLife.getClassName(classId)).length == 0, "Class already exists");

        for (uint8 s = 0; s < 8; s++) {
            require(config.maxStats[s] >= config.minStats[s], "maxStat must be >= minStat");
        }

        uint16 totalDelta;
        for (uint8 d = 0; d < 8; d++) {
            totalDelta += config.maxStats[d] - config.minStats[d];
        }
        // Ensure the configuration provides meaningful stat distribution space by Gating the possible Total point to be 2/3 max of Maximum all Stats
        require(config.totalPoints <= (totalDelta * 67) / 100, "totalPoints must be Lower than sum of stat deltas");

        book0fLife.addNewClass(classId, name, rarity, config, 1);
        binderData.setClassVersion(classId, 1);
    }

    // 3. SetFusionRecipe and its probability
    function setFusionRecipe(uint256 class1, uint256 class2, uint256[] calldata classIds, uint16[] calldata multiProbChance, uint16 successChance) external onlyRole(DEFAULT_ADMIN_ROLE) {
        book0fLife.setFusionRecipe(class1, class2, classIds, multiProbChance, successChance);
        // Removed for now, @dev forget why he put it in first place
        // bytes32 ingredients = keccak256(abi.encodePacked(class1, class2));
        emit logFusionRecipeSet(class1, class2, classIds, multiProbChance, successChance);
    }

    // ================== STAT CALCULATION ==================
    // 1. Internal function for stat calculation
    function _calculateStats(
        binderStructs.ClassConfig memory oldConfig,
        binderStructs.ClassConfig memory newConfig,
        binderStructs.StaticStats memory oldStats
    ) internal pure returns (binderStructs.StaticStats memory) {binderStructs.StaticStats memory newStats;
        uint256 totalPoints;

        // Phase 1: Linear scaling
        for (uint i = 0; i < 8; i++) {
            uint256 oldMin = oldConfig.minStats[i];
            uint256 oldMax = oldConfig.maxStats[i];
            uint256 newMin = newConfig.minStats[i];
            uint256 newMax = newConfig.maxStats[i];

            if (oldMax <= oldMin) { // Edge Case handling just incase I messed up and make it have 0 scaling range
                newStats.stats[i] = uint8(newMin);
            } else {
                uint256 scaled = (uint256(oldStats.stats[i] - oldMin) * (newMax - newMin)) / (oldMax - oldMin);
                newStats.stats[i] = uint8(newMin + scaled);
            }
            totalPoints += newStats.stats[i];
        }

        // Phase 2: Point redistribution
        int256 delta = int256(uint256(newConfig.totalPoints)) - int256(totalPoints);
        if (delta != 0) {
            bool addMode = delta > 0;
            uint256 absDelta = delta < 0 ? uint256(-delta) : uint256(delta);
            uint8 iterations = uint8(absDelta); // Assumes delta Will never exceed 255

            for (uint256 i = 0; i < iterations; i++) {
                uint8 statIndex = uint8(i % 8);

                if (addMode) {    // if delta is positive, increase the stat
                    if (newStats.stats[statIndex] < newConfig.maxStats[statIndex]) {
                        newStats.stats[statIndex]++;
                        delta--;
                    }
                } else {            // if delta is negative, decrease the stat
                    if (newStats.stats[statIndex] > newConfig.minStats[statIndex]) {
                        newStats.stats[statIndex]--;
                        delta++;
                    }
                }

                if (delta == 0) break;
            }
        }

        return newStats;
    }

    // ================== HELPER FUNCTIONS ==================
    function _preserveRatio(
        uint16 current,
        uint16 oldMax,
        uint16 newMax
    ) internal pure returns (uint16) {
        if (oldMax == 0 || current == 0) return 0;
        if (oldMax == newMax) return current;
        return uint16((uint256(current) * newMax) / oldMax);
    }
}
