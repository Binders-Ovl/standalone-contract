// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Read and configuration surface for the canonical Binders module registry.
interface ICentralConsole {
    struct WiringStatus {
        bool binderDataMetadataMatch;
        bool binderSkillsPairMatch;
        bool metadataDependenciesMatch;
        bool metadataRefreshAuthorityMatch;
        bool bookLifeDependenciesMatch;
        bool book0fRealmsConfigured;
        bool battleFactoryMatch;
        bool battleFactoryDependenciesMatch;
        bool battleActivityControllerMatch;
        bool fusionDependenciesMatch;
        bool fusionActivityControllerMatch;
        bool binderLogicCanonicalAndAccepting;
        bool scaleDependenciesAndAuthorityMatch;
        bool allegianceDependenciesMatch;
        bool graveyardConfigured;
        bool consoleAuthorityMatch;
    }

    function binderData() external view returns (address);
    function binderSkills() external view returns (address);
    function binderMetadata() external view returns (address);
    function book0fLife() external view returns (address);
    function book0fArts() external view returns (address);
    function book0fRealms() external view returns (address);
    function binderLogic() external view returns (address);
    function fusionMinter() external view returns (address);
    function scaleOfBalance() external view returns (address);
    function battleFactory() external view returns (address);
    function battleFactoryVersion() external view returns (uint32);
    function allegianceRegistry() external view returns (address);
    function activityModule(uint8 activityId) external view returns (address);

    function canonicalModule(bytes32 moduleId) external view returns (address);
    function isCanonicalModule(address moduleAddress) external view returns (bool);

    function setBinderSkills(address moduleAddress) external;
    function configureBinderSkills(address moduleAddress, address compatibleMetadata) external;
    function setBinderMetadata(address moduleAddress) external;
    function setBook0fLife(address moduleAddress) external;
    function setBook0fArts(address moduleAddress) external;
    function setBook0fRealms(address moduleAddress) external;
    function setBinderLogic(address moduleAddress) external;
    function finalizeBinderLogicRetirement(address oldLogic) external;
    function setFusionMinter(address moduleAddress) external;
    function finalizeFusionMinterRetirement(address oldMinter) external;
    function setScaleOfBalance(address moduleAddress) external;
    function setBattleFactory(address moduleAddress, uint32 implementationVersion) external;
    function setAllegianceRegistry(address moduleAddress) external;
    function setActivityModule(uint8 activityId, address moduleAddress) external;
    function getWiringStatus() external view returns (WiringStatus memory);
    function isFullyWired() external view returns (bool);
}
