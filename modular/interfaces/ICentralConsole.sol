// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Read and configuration surface for the canonical Binders module registry.
interface ICentralConsole {
    function isGrowthWired() external view returns (bool);
    function binderGrowth() external view returns (address);
    function book0fGrowth() external view returns (address);
    function training() external view returns (address);
    function quest() external view returns (address);

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
        bool scaleBalanceAuthorityMatch;
        bool allegianceDependenciesMatch;
        bool graveyardConfigured;
        bool consoleAuthorityMatch;
    }

    struct ItemWiringStatus {
        bool bookAuthorityMatch;
        bool inventoryDependenciesMatch;
        bool collectionsMatch;
        bool collectionOwnershipMatch;
        bool routerDependenciesMatch;
        bool skillsDependenciesMatch;
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
    function book0fItems() external view returns (address);
    function binderInventory() external view returns (address);
    function equipment() external view returns (address);
    function tomeAndGrimoires() external view returns (address);
    function sItems() external view returns (address);
    function itemUseRouter() external view returns (address);
    function itemMetadataBuilder() external view returns (address);
    function itemStatsView() external view returns (address);
    function goldAsset() external view returns (address);
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
    function configureItemSystem(
        address bookAddress,
        address inventoryAddress,
        address equipmentAddress,
        address tomeAddress,
        address sItemAddress,
        address routerAddress,
        address metadataBuilderAddress,
        address statsViewAddress,
        address entropyAddress,
        address entropyProvider
    ) external;
    function setGoldAsset(address asset) external;
    function setItemIssuer(address collection, address issuer, bool allowed) external;
    function setItemTransferValidator(address collection, address validator) external;
    function configureItemTransferRuleset(
        address collection,
        uint8 rulesetId,
        address customRuleset,
        uint8 globalOptions,
        uint16 rulesetOptions
    ) external;
    function applyItemTransferList(address collection, uint48 listId) external;
    function createItemTransferList(address collection, string calldata name) external returns (uint48 listId);
    function addItemTransferListAccounts(address collection, uint48 listId, uint8 listType, address[] calldata accounts)
        external;
    function addItemTransferListCodeHashes(
        address collection,
        uint48 listId,
        uint8 listType,
        bytes32[] calldata codehashes
    ) external;
    function setItemBaseImageURI(address collection, string calldata value) external;
    function setItemImageURI(address collection, uint16 libraryId, string calldata value) external;
    function setActivityModule(uint8 activityId, address moduleAddress) external;
    function getWiringStatus() external view returns (WiringStatus memory);
    function getItemWiringStatus() external view returns (ItemWiringStatus memory);
    function isFullyWired() external view returns (bool);
}
