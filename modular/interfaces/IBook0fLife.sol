// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../supportContract/binderStructs.sol";

/// @notice Cross-module API for current Book0fLife definitions and configuration.
interface IBook0fLife {
    function allegianceRegistry() external view returns (address);
    function setAllegianceRegistry(address registry) external;
    function setFusionMinter(address fusionMinter) external;
    function registerRarity(uint8 rarityId, string calldata displayName) external;
    function setRarityName(uint8 rarityId, string calldata displayName) external;
    function addNewClass(
        uint256 classId,
        string calldata name,
        uint8 rarityId,
        binderStructs.ClassConfig calldata config,
        uint16 version
    ) external;
    function upgradeClassConfig(
        uint256 classId,
        uint16 totalPoints,
        uint8[8] calldata minStats,
        uint8[8] calldata maxStats,
        uint16 hpPerVit,
        uint16 mpPerWis,
        uint16 newVersion
    ) external;
    function setClassRarityId(uint256 classId, uint8 newRarityId) external;
    function assignClassToNation(uint256 classId, uint8 nationId) external;
    function removeClassFromNation(uint256 classId, uint8 nationId) external;
    function setClassAcquisitionFlags(uint256 classId, uint32 flags) external;
    function enableClassAcquisition(uint256 classId, uint32 flagMask) external;
    function disableClassAcquisition(uint256 classId, uint32 flagMask) external;
    function setEventMintSchedule(uint256 classId, binderStructs.EventMintSchedule calldata schedule) external;
    function setEventNationRotation(uint256 classId, uint8[] calldata nationIds) external;
    function setFusionRecipe(
        uint256 class1,
        uint256 class2,
        uint256[] calldata classIds,
        uint16[] calldata multiProbChance,
        uint16 successChance
    ) external;

    function isRarityRegistered(uint8 rarityId) external view returns (bool);
    function classExists(uint256 classId) external view returns (bool);
    function isClassMintEligible(uint256 classId, uint8 playerNationId) external view returns (bool);
    function getClassName(uint256 classId) external view returns (string memory);
    function getClassRarityId(uint256 classId) external view returns (uint8);
    function getRarityName(uint8 rarityId) external view returns (string memory);
    function getClassesByNationRarity(uint8 nationId, uint8 rarityId) external view returns (uint256[] memory);
    function getClassConfig(uint256 classId) external view returns (binderStructs.ClassConfig memory);
    function getClassConfigAtVersion(uint256 classId, uint16 version)
        external
        view
        returns (binderStructs.ClassConfig memory);
    function getClassVersion(uint256 classId) external view returns (uint16);
    function getFusionRecipe(uint256 class1, uint256 class2)
        external
        view
        returns (binderStructs.FusionRecipe memory);
    function hasClassAcquisition(uint256 classId, uint32 flagMask) external view returns (bool);
}
