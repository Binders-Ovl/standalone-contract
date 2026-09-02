// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./supportContract/binderStructs.sol";
import "@openzeppelin/contracts-4.8/access/AccessControl.sol";
import "./interfaces/IBinderData.sol";
import "./interfaces/IBook0fLife.sol";

contract ScaleOfBalance is AccessControl {
    IBinderData public binderData;
    IBook0fLife public book0fLife;

    // Events
    event logClassConfigUpdated(
        string indexed className,
        binderStructs.ClassConfig indexed config,
        uint256 indexed timestamp,
        uint256 blockNumber
    );
    event logFusionRecipeSet(
        uint256 class1, uint256 class2, uint256[] classIds, uint16[] multiProbChance, uint16 successChance
    );
    event upgradeSuccesful(address indexed user, uint256 indexed tokenId);
    event upgradeFailed(address indexed user, uint256 indexed tokenId, string reason);

    constructor(address _binderData, address _book0fLife) {
        binderData = IBinderData(_binderData);
        book0fLife = IBook0fLife(_book0fLife);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // ================== PUBLIC FUNCTIONS ==================
    // 1. Upgrade NFT By user
    function upgradeNFT(uint256 tokenId) external {
        _upgradeNFTFor(msg.sender, tokenId);
    }

    // 2. Batch upgrade NFTs by user
    function batchUpgradeNFTs(uint256[] calldata tokenIds) external {
        // -- Expecting specific list of token to upgrade
        // ---- and the List shud be provided by game frontEnd!
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];

            try this.upgradeNFTFromBatch(msg.sender, tokenId) {
                // Success
            } catch Error(string memory reason) {
                // Failed
                emit upgradeFailed(msg.sender, tokenId, reason);
            } catch {
                emit upgradeFailed(msg.sender, tokenId, "Unknown Error");
            }
        }
    }

    // Self-only adapter keeps the original batch caller explicit while
    // preserving per-token try/catch behavior.
    function upgradeNFTFromBatch(address user, uint256 tokenId) external {
        require(msg.sender == address(this), "Only self");
        _upgradeNFTFor(user, tokenId);
    }

    // ================== CORE FUNCTIONALITY ==================
    function _upgradeNFTFor(address user, uint256 tokenId) internal {
        require(binderData.ownerOf(tokenId) == user, "Not owner");
        require(binderData.getUnitState(tokenId).idle, "Unit is active");

        // Gatekeep Ready to Arm
        binderStructs.NFTMetadata memory meta = binderData.getNFTDetails(tokenId);
        uint16 latestVersion = _getSyncedClassVersion(meta.classId);
        require(meta.configVersion < latestVersion, "Already upgraded");

        _upgradeNFTInternal(tokenId, meta);

        emit upgradeSuccesful(user, tokenId);
    }

    function _upgradeNFTInternal(uint256 tokenId, binderStructs.NFTMetadata memory meta) internal {
        // 1. Get the NFT's actual historical config and the current config
        binderStructs.ClassConfig memory oldConfig =
            book0fLife.getClassConfigAtVersion(meta.classId, meta.configVersion);
        binderStructs.ClassConfig memory newConfig = book0fLife.getClassConfig(meta.classId);

        // 3. Calculate new stats
        bytes32 redistributionSeed = keccak256(
            abi.encode(
                "UPGRADE_STATS",
                tokenId,
                meta.classId,
                meta.configVersion,
                newConfig.minStats,
                newConfig.maxStats,
                newConfig.totalPoints,
                meta.staticStats.stats
            )
        );
        binderStructs.StaticStats memory newStats =
            _calculateStats(oldConfig, newConfig, meta.staticStats, redistributionSeed);

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
        binderData.updateNFTStats(tokenId, newStats, dynStats);
    }

    // ================== ADMIN FUNCTIONS ==================
    // 1. Update Class Config and mirror to binderData && book0fLife
    function updateClassConfig(uint256 classId, binderStructs.ClassConfig calldata newConfig)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        // Rules and requirements
        require(classId != 0, "Invalid classId");
        require(book0fLife.classExists(classId), "Class does not exist");

        for (uint8 s = 0; s < 8; s++) {
            require(newConfig.minStats[s] <= newConfig.maxStats[s], "Invalid stat range");
        }

        uint16 totalDelta;
        for (uint8 d = 0; d < 8; d++) {
            totalDelta += (newConfig.maxStats[d] - newConfig.minStats[d]);
        }
        // Gating the possible Total point to be 2/3 max of Maximum all Stats
        require(newConfig.totalPoints < (totalDelta * 67) / 100, "totalPoints must be Lower than total delta");

        // Keep Book0fLife and BinderData synchronized; do not hide a desync.
        uint16 currentVersion = _getSyncedClassVersion(classId);
        require(currentVersion < type(uint16).max, "Version overflow");
        uint16 newVersion = currentVersion + 1;

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
    function addNewClass(
        uint256 classId,
        string calldata name,
        uint8 rarityId,
        binderStructs.ClassConfig calldata config
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // Requirement and Rules
        require(classId != 0, "Invalid classId");
        require(!book0fLife.classExists(classId), "Class already exists");

        for (uint8 s = 0; s < 8; s++) {
            require(config.maxStats[s] >= config.minStats[s], "maxStat must be >= minStat");
        }

        uint16 totalDelta;
        for (uint8 d = 0; d < 8; d++) {
            totalDelta += config.maxStats[d] - config.minStats[d];
        }
        // Ensure the configuration provides meaningful stat distribution space by Gating the possible Total point to be 2/3 max of Maximum all Stats
        require(config.totalPoints <= (totalDelta * 67) / 100, "totalPoints must be Lower than sum of stat deltas");

        book0fLife.addNewClass(classId, name, rarityId, config, 1);
        binderData.setClassVersion(classId, 1);
    }

    function setClassRarityId(uint256 classId, uint8 rarityId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        book0fLife.setClassRarityId(classId, rarityId);
    }

    function registerRarity(uint8 rarityId, string calldata displayName) external onlyRole(DEFAULT_ADMIN_ROLE) {
        book0fLife.registerRarity(rarityId, displayName);
    }

    function setRarityName(uint8 rarityId, string calldata displayName) external onlyRole(DEFAULT_ADMIN_ROLE) {
        book0fLife.setRarityName(rarityId, displayName);
        // The rarity display name is renderer input for all matching NFTs.
        binderData.refreshAllMetadata();
    }

    function setBookAllegianceRegistry(address registry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        book0fLife.setAllegianceRegistry(registry);
    }

    function assignClassToNation(uint256 classId, uint8 nationId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        book0fLife.assignClassToNation(classId, nationId);
    }

    function removeClassFromNation(uint256 classId, uint8 nationId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        book0fLife.removeClassFromNation(classId, nationId);
    }

    function setClassAcquisitionFlags(uint256 classId, uint32 flags) external onlyRole(DEFAULT_ADMIN_ROLE) {
        book0fLife.setClassAcquisitionFlags(classId, flags);
    }

    function enableClassAcquisition(uint256 classId, uint32 flagMask) external onlyRole(DEFAULT_ADMIN_ROLE) {
        book0fLife.enableClassAcquisition(classId, flagMask);
    }

    function disableClassAcquisition(uint256 classId, uint32 flagMask) external onlyRole(DEFAULT_ADMIN_ROLE) {
        book0fLife.disableClassAcquisition(classId, flagMask);
    }

    function setEventMintSchedule(uint256 classId, binderStructs.EventMintSchedule calldata schedule)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        book0fLife.setEventMintSchedule(classId, schedule);
    }

    function setEventNationRotation(uint256 classId, uint8[] calldata nationIds)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        book0fLife.setEventNationRotation(classId, nationIds);
    }

    function _getSyncedClassVersion(uint256 classId) internal view returns (uint16) {
        uint16 bookVersion = book0fLife.getClassVersion(classId);
        uint16 dataVersion = binderData.classVersion(classId);
        require(bookVersion == dataVersion, "Version desync");
        return dataVersion;
    }

    // 3. SetFusionRecipe and its probability
    function setFusionRecipe(
        uint256 class1,
        uint256 class2,
        uint256[] calldata classIds,
        uint16[] calldata multiProbChance,
        uint16 successChance
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
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
        binderStructs.StaticStats memory oldStats,
        bytes32 redistributionSeed
    ) internal pure returns (binderStructs.StaticStats memory) {
        binderStructs.StaticStats memory newStats;
        uint256 allocatedPoints;

        // Phase 1: Linear scaling
        for (uint256 i = 0; i < 8; i++) {
            uint256 oldMin = oldConfig.minStats[i];
            uint256 oldMax = oldConfig.maxStats[i];
            uint256 newMin = newConfig.minStats[i];
            uint256 newMax = newConfig.maxStats[i];

            if (oldMax <= oldMin) {
                // Edge Case handling just incase I messed up and make it have 0 scaling range
                newStats.stats[i] = uint8(newMin);
            } else {
                uint256 oldRange = oldMax - oldMin;
                uint256 newRange = newMax - newMin;
                uint256 oldExtra = uint256(oldStats.stats[i]) > oldMin ? uint256(oldStats.stats[i]) - oldMin : 0;
                uint256 scaledExtra = (oldExtra * newRange) / oldRange;
                if (scaledExtra > newRange) scaledExtra = newRange;
                newStats.stats[i] = uint8(newMin + scaledExtra);
            }
            allocatedPoints += uint256(newStats.stats[i]) - newMin;
        }

        // Phase 2: Point redistribution
        int256 delta = int256(uint256(newConfig.totalPoints)) - int256(allocatedPoints);
        if (delta == 0) return newStats;

        bool addMode = delta > 0;
        uint256 remainingPoints = delta > 0 ? uint256(delta) : uint256(-delta);
        for (uint256 step = 0; step < remainingPoints; step++) {
            uint8 statIndex = _selectRedistributionStat(newStats, newConfig, addMode, redistributionSeed, step);

            if (addMode) {
                newStats.stats[statIndex]++;
            } else {
                newStats.stats[statIndex]--;
            }
        }

        return newStats;
    }

    function _selectRedistributionStat(
        binderStructs.StaticStats memory stats,
        binderStructs.ClassConfig memory config,
        bool addMode,
        bytes32 seed,
        uint256 step
    ) internal pure returns (uint8) {
        uint8[8] memory eligibleStats;
        uint256[8] memory weights;
        uint8 eligibleCount;
        uint256 totalWeight;

        for (uint8 i = 0; i < 8; i++) {
            uint256 current = stats.stats[i];
            uint256 minStat = config.minStats[i];
            uint256 maxStat = config.maxStats[i];
            uint256 extra = current - minStat;
            uint256 range = maxStat - minStat;
            uint256 available = addMode ? maxStat - current : extra;

            if (available == 0) continue;

            eligibleStats[eligibleCount] = i;
            // Additions favor already-earned allocations; removals favor lower
            // relative allocations so stronger existing stats are less likely
            // to lose their preserved upgrade advantage.
            weights[eligibleCount] = addMode ? extra + 1 : range - extra + 1;
            totalWeight += weights[eligibleCount];
            eligibleCount++;
        }

        require(eligibleCount > 0, "No eligible stat");

        uint256 selection = uint256(keccak256(abi.encode(seed, step))) % totalWeight;
        for (uint8 i = 0; i < eligibleCount; i++) {
            if (selection < weights[i]) return eligibleStats[i];
            selection -= weights[i];
        }

        revert("Invalid stat selection");
    }

    // ================== HELPER FUNCTIONS ==================
    function _preserveRatio(uint16 current, uint16 oldMax, uint16 newMax) internal pure returns (uint16) {
        if (oldMax == 0 || current == 0) return 0;
        if (oldMax == newMax) return current;
        return uint16((uint256(current) * newMax) / oldMax);
    }
}
