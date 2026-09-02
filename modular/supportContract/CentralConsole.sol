// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-4.8/access/AccessControl.sol";
import "./binderIds.sol";
import "./Errors.sol";
import "../interfaces/ICentralConsole.sol";
import "../interfaces/IBinderMetadata.sol";
import "../interfaces/IBinderSkills.sol";

/// @notice Canonical Binders module registry and configuration control plane.
/// @dev It deliberately has no arbitrary call primitive and owns no NFT, Book,
/// learned-skill, or battle gameplay state. BinderData is bound once at deployment.
contract CentralConsole is AccessControl, ICentralConsole {
    bytes32 public constant CONFIG_ROLE = keccak256("CONFIG_ROLE");

    address public immutable override binderData;
    address public override binderSkills;
    address public override binderMetadata;
    address public override book0fLife;
    address public override book0fArts;
    address public override book0fRealms;
    address public override binderLogic;
    address public override fusionMinter;
    address public override scaleOfBalance;
    address public override battleFactory;
    uint32 public override battleFactoryVersion;
    address public override allegianceRegistry;
    mapping(uint8 => address) public override activityModule;

    event CanonicalModuleUpdated(bytes32 indexed moduleId, address indexed previousModule, address indexed newModule);
    event BattleFactoryVersionUpdated(
        address indexed previousFactory,
        address indexed newFactory,
        uint32 previousVersion,
        uint32 newVersion
    );
    event ActivityModuleUpdated(uint8 indexed activityId, address indexed previousModule, address indexed newModule);

    constructor(address initialOwner, address binderDataAddress) {
        if (initialOwner == address(0)) revert InvalidInitialOwner(initialOwner);
        _requireContract(BinderIds.MODULE_BINDER_DATA, binderDataAddress);

        binderData = binderDataAddress;
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
        _grantRole(CONFIG_ROLE, initialOwner);

        emit CanonicalModuleUpdated(BinderIds.MODULE_BINDER_DATA, address(0), binderDataAddress);
    }

    function setBinderSkills(address moduleAddress) external override onlyRole(CONFIG_ROLE) {
        _setBinderSkills(moduleAddress);
    }

    function setBinderMetadata(address moduleAddress) external override onlyRole(CONFIG_ROLE) {
        address metadataBinderData;
        try IBinderMetadata(moduleAddress).binderData() returns (address resolvedBinderData) {
            metadataBinderData = resolvedBinderData;
        } catch {
            revert CanonicalPairMismatch(binderData, address(0));
        }
        if (metadataBinderData != binderData) revert CanonicalPairMismatch(binderData, metadataBinderData);
        _setModule(BinderIds.MODULE_BINDER_METADATA, binderMetadata, moduleAddress);
        binderMetadata = moduleAddress;
    }

    function setBook0fLife(address moduleAddress) external override onlyRole(CONFIG_ROLE) {
        _setModule(BinderIds.MODULE_BOOK_OF_LIFE, book0fLife, moduleAddress);
        book0fLife = moduleAddress;
    }

    function setBook0fArts(address moduleAddress) external override onlyRole(CONFIG_ROLE) {
        _setModule(BinderIds.MODULE_BOOK_OF_ARTS, book0fArts, moduleAddress);
        book0fArts = moduleAddress;
    }

    function setBook0fRealms(address moduleAddress) external override onlyRole(CONFIG_ROLE) {
        _setModule(BinderIds.MODULE_BOOK_OF_REALMS, book0fRealms, moduleAddress);
        book0fRealms = moduleAddress;
    }

    function setBinderLogic(address moduleAddress) external override onlyRole(CONFIG_ROLE) {
        _setModule(BinderIds.MODULE_BINDER_LOGIC, binderLogic, moduleAddress);
        binderLogic = moduleAddress;
    }

    function setFusionMinter(address moduleAddress) external override onlyRole(CONFIG_ROLE) {
        _setModule(BinderIds.MODULE_FUSION_MINTER, fusionMinter, moduleAddress);
        fusionMinter = moduleAddress;
    }

    function setScaleOfBalance(address moduleAddress) external override onlyRole(CONFIG_ROLE) {
        _setModule(BinderIds.MODULE_SCALE_OF_BALANCE, scaleOfBalance, moduleAddress);
        scaleOfBalance = moduleAddress;
    }

    function setBattleFactory(address moduleAddress, uint32 implementationVersion) external override onlyRole(CONFIG_ROLE) {
        _requireContract(BinderIds.MODULE_BATTLE_FACTORY, moduleAddress);
        uint32 previousVersion = battleFactoryVersion;
        if (implementationVersion == 0 || implementationVersion <= previousVersion) {
            revert InvalidModuleVersion(BinderIds.MODULE_BATTLE_FACTORY, previousVersion, implementationVersion);
        }

        address previousFactory = battleFactory;
        battleFactory = moduleAddress;
        battleFactoryVersion = implementationVersion;
        emit CanonicalModuleUpdated(BinderIds.MODULE_BATTLE_FACTORY, previousFactory, moduleAddress);
        emit BattleFactoryVersionUpdated(previousFactory, moduleAddress, previousVersion, implementationVersion);
    }

    function setAllegianceRegistry(address moduleAddress) external override onlyRole(CONFIG_ROLE) {
        _setModule(BinderIds.MODULE_ALLEGIANCE_REGISTRY, allegianceRegistry, moduleAddress);
        allegianceRegistry = moduleAddress;
    }

    /// @notice Registers the canonical module for a future activity type.
    /// @dev This registry does not replace BinderData's controller authorization;
    /// runtime activity wiring remains an explicit, narrow later operation.
    function setActivityModule(uint8 activityId, address moduleAddress) external override onlyRole(CONFIG_ROLE) {
        if (activityId == BinderIds.ACTIVITY_IDLE) revert InvalidActivityModuleId(activityId);
        _requireContract(bytes32(uint256(activityId)), moduleAddress);

        address previousModule = activityModule[activityId];
        activityModule[activityId] = moduleAddress;
        emit ActivityModuleUpdated(activityId, previousModule, moduleAddress);
    }

    function canonicalModule(bytes32 moduleId) external view override returns (address) {
        if (moduleId == BinderIds.MODULE_BINDER_DATA) return binderData;
        if (moduleId == BinderIds.MODULE_BINDER_SKILLS) return binderSkills;
        if (moduleId == BinderIds.MODULE_BINDER_METADATA) return binderMetadata;
        if (moduleId == BinderIds.MODULE_BOOK_OF_LIFE) return book0fLife;
        if (moduleId == BinderIds.MODULE_BOOK_OF_ARTS) return book0fArts;
        if (moduleId == BinderIds.MODULE_BOOK_OF_REALMS) return book0fRealms;
        if (moduleId == BinderIds.MODULE_BINDER_LOGIC) return binderLogic;
        if (moduleId == BinderIds.MODULE_FUSION_MINTER) return fusionMinter;
        if (moduleId == BinderIds.MODULE_SCALE_OF_BALANCE) return scaleOfBalance;
        if (moduleId == BinderIds.MODULE_BATTLE_FACTORY) return battleFactory;
        if (moduleId == BinderIds.MODULE_ALLEGIANCE_REGISTRY) return allegianceRegistry;
        revert UnknownCanonicalModule(moduleId);
    }

    function isCanonicalModule(address moduleAddress) external view override returns (bool) {
        return moduleAddress != address(0)
            && (
                moduleAddress == binderData || moduleAddress == binderSkills || moduleAddress == binderMetadata
                    || moduleAddress == book0fLife || moduleAddress == book0fArts || moduleAddress == book0fRealms
                    || moduleAddress == binderLogic || moduleAddress == fusionMinter || moduleAddress == scaleOfBalance
                    || moduleAddress == battleFactory || moduleAddress == allegianceRegistry
            );
    }

    function _setBinderSkills(address moduleAddress) internal {
        _setModule(BinderIds.MODULE_BINDER_SKILLS, binderSkills, moduleAddress);
        address skillsBinderData;
        try IBinderSkills(moduleAddress).binderData() returns (address resolvedBinderData) {
            skillsBinderData = resolvedBinderData;
        } catch {
            revert CanonicalPairMismatch(binderData, address(0));
        }
        if (skillsBinderData != binderData) revert CanonicalPairMismatch(binderData, skillsBinderData);
        binderSkills = moduleAddress;
    }

    function _setModule(bytes32 moduleId, address previousModule, address newModule) internal {
        _requireContract(moduleId, newModule);
        emit CanonicalModuleUpdated(moduleId, previousModule, newModule);
    }

    function _requireContract(bytes32 moduleId, address moduleAddress) internal view {
        if (moduleAddress == address(0) || moduleAddress.code.length == 0) {
            revert InvalidModuleAddress(moduleId, moduleAddress);
        }
    }
}
