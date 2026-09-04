// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-4.8/access/AccessControl.sol";
import "./binderIds.sol";
import "./Errors.sol";
import "../interfaces/ICentralConsole.sol";
import "../interfaces/IBinderMetadata.sol";
import "../interfaces/IBinderSkills.sol";
import "../interfaces/IBinderData.sol";
import "../interfaces/IBook0fLife.sol";
import "../interfaces/IFusionMinter.sol";
import "../interfaces/IBinderLogic.sol";
import "../interfaces/IScaleOfBalance.sol";
import "../interfaces/IBattleFactory.sol";
import "./WiringDiagnostics.sol";

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
    WiringDiagnostics private immutable wiringDiagnostics;

    event CanonicalModuleUpdated(bytes32 indexed moduleId, address indexed previousModule, address indexed newModule);
    event BattleFactoryVersionUpdated(
        address indexed previousFactory, address indexed newFactory, uint32 previousVersion, uint32 newVersion
    );
    event ActivityModuleUpdated(uint8 indexed activityId, address indexed previousModule, address indexed newModule);

    error PendingMintsPreventRetirement(address logic, uint256 pendingCount);
    error PendingFusionsPreventRetirement(address minter, uint256 pendingCount);
    error ModuleStillCanonical(address module);

    constructor(address initialOwner, address binderDataAddress) {
        if (initialOwner == address(0)) revert InvalidInitialOwner(initialOwner);
        _requireContract(BinderIds.MODULE_BINDER_DATA, binderDataAddress);

        binderData = binderDataAddress;
        wiringDiagnostics = new WiringDiagnostics();
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
        _grantRole(CONFIG_ROLE, initialOwner);

        emit CanonicalModuleUpdated(BinderIds.MODULE_BINDER_DATA, address(0), binderDataAddress);
    }

    function setBinderSkills(address moduleAddress) external override onlyRole(CONFIG_ROLE) {
        _configureBinderSkills(moduleAddress);
    }

    /// @notice Atomically replaces the persistent Skills proxy and immutable
    /// metadata renderer that reads it. This is required whenever the
    /// renderer currently installed in BinderData points to another Skills
    /// address.
    function configureBinderSkills(address moduleAddress, address compatibleMetadata)
        external
        override
        onlyRole(CONFIG_ROLE)
    {
        _validateBinderSkills(moduleAddress);
        _requireMetadataDependenciesForSkills(compatibleMetadata, moduleAddress, book0fLife, book0fArts);

        address previousSkills = binderSkills;
        address previousMetadata = binderMetadata;
        _stageBinderSkills(moduleAddress);
        IBinderData(binderData).setMetadataRefreshModule(previousSkills, moduleAddress);
        IBinderData(binderData).setBinderMetadata(compatibleMetadata);
        binderMetadata = compatibleMetadata;

        emit CanonicalModuleUpdated(BinderIds.MODULE_BINDER_SKILLS, previousSkills, moduleAddress);
        emit CanonicalModuleUpdated(BinderIds.MODULE_BINDER_METADATA, previousMetadata, compatibleMetadata);
    }

    function _configureBinderSkills(address moduleAddress) internal {
        _validateBinderSkills(moduleAddress);
        address previousModule = binderSkills;
        // A metadata renderer has immutable dependencies. It is safe to
        // perform a simple update only before renderer installation or for
        // re-registering the exact same proxy during Console migration.
        if (
            binderMetadata != address(0) && previousModule != address(0) && previousModule != moduleAddress
                && IBinderMetadata(binderMetadata).binderSkills() != moduleAddress
        ) {
            revert CanonicalSkillsMismatch(moduleAddress, IBinderMetadata(binderMetadata).binderSkills());
        }
        _stageBinderSkills(moduleAddress);
        IBinderData(binderData).setMetadataRefreshModule(previousModule, moduleAddress);
        emit CanonicalModuleUpdated(BinderIds.MODULE_BINDER_SKILLS, previousModule, moduleAddress);
    }

    function _validateBinderSkills(address moduleAddress) internal view {
        _requireContract(BinderIds.MODULE_BINDER_SKILLS, moduleAddress);
        address skillsBinderData;
        try IBinderSkills(moduleAddress).binderData() returns (address resolvedBinderData) {
            skillsBinderData = resolvedBinderData;
        } catch {
            revert CanonicalPairMismatch(binderData, address(0));
        }
        if (skillsBinderData != binderData) revert CanonicalPairMismatch(binderData, skillsBinderData);
    }

    function _stageBinderSkills(address moduleAddress) internal {
        // The registry is staged first solely so BinderSkills can verify the
        // new pairing in setCentralConsole. Any failure reverts this whole tx.
        binderSkills = moduleAddress;
        if (IBinderSkills(moduleAddress).centralConsole() != address(this)) {
            IBinderSkills(moduleAddress).setCentralConsole(address(this));
        }
        if (IBinderSkills(moduleAddress).centralConsole() != address(this)) {
            revert CanonicalSkillsMismatch(address(this), IBinderSkills(moduleAddress).centralConsole());
        }
    }

    function setBinderMetadata(address moduleAddress) external override onlyRole(CONFIG_ROLE) {
        configureBinderMetadata(moduleAddress);
    }

    /// @notice Atomically validates the renderer, updates BinderData's tokenURI
    /// target, records the canonical module, and verifies the final pointer.
    function configureBinderMetadata(address moduleAddress) public onlyRole(CONFIG_ROLE) {
        _requireContract(BinderIds.MODULE_BINDER_METADATA, moduleAddress);
        address metadataBinderData;
        try IBinderMetadata(moduleAddress).binderData() returns (address resolvedBinderData) {
            metadataBinderData = resolvedBinderData;
        } catch {
            revert CanonicalPairMismatch(binderData, address(0));
        }
        if (metadataBinderData != binderData) revert CanonicalPairMismatch(binderData, metadataBinderData);
        if (
            IBinderMetadata(moduleAddress).binderSkills() != binderSkills
                || IBinderMetadata(moduleAddress).book0fLife() != book0fLife
                || IBinderMetadata(moduleAddress).book0fArts() != book0fArts
        ) revert CanonicalPairMismatch(binderData, metadataBinderData);

        IBinderData(binderData).setBinderMetadata(moduleAddress);
        if (IBinderData(binderData).binderMetadataAddress() != moduleAddress) {
            revert CanonicalPairMismatch(moduleAddress, IBinderData(binderData).binderMetadataAddress());
        }
        _setModule(BinderIds.MODULE_BINDER_METADATA, binderMetadata, moduleAddress);
        binderMetadata = moduleAddress;
    }

    function setBook0fLife(address moduleAddress) external override onlyRole(CONFIG_ROLE) {
        _requireContract(BinderIds.MODULE_BOOK_OF_LIFE, moduleAddress);
        if (binderMetadata != address(0) && IBinderMetadata(binderMetadata).book0fLife() != moduleAddress) {
            revert CanonicalPairMismatch(moduleAddress, IBinderMetadata(binderMetadata).book0fLife());
        }
        if (fusionMinter != address(0) && IFusionMinter(fusionMinter).book0fLife() != moduleAddress) {
            revert CanonicalPairMismatch(moduleAddress, IFusionMinter(fusionMinter).book0fLife());
        }
        if (scaleOfBalance != address(0)) IScaleOfBalance(scaleOfBalance).setBook0fLife(moduleAddress);
        if (binderLogic != address(0)) IBinderLogic(binderLogic).setBook0fLife(moduleAddress);
        if (allegianceRegistry != address(0)) IBook0fLife(moduleAddress).setAllegianceRegistry(allegianceRegistry);
        _setModule(BinderIds.MODULE_BOOK_OF_LIFE, book0fLife, moduleAddress);
        book0fLife = moduleAddress;
    }

    function setBook0fArts(address moduleAddress) external override onlyRole(CONFIG_ROLE) {
        _requireContract(BinderIds.MODULE_BOOK_OF_ARTS, moduleAddress);
        if (binderMetadata != address(0) && IBinderMetadata(binderMetadata).book0fArts() != moduleAddress) {
            revert CanonicalPairMismatch(moduleAddress, IBinderMetadata(binderMetadata).book0fArts());
        }
        _setModule(BinderIds.MODULE_BOOK_OF_ARTS, book0fArts, moduleAddress);
        book0fArts = moduleAddress;
    }

    /// @notice Cuts over Book0fLife together with fresh compatible renderer
    /// and Fusion consumer instances. Existing Fusion minters remain
    /// authorized only to complete the requests they already custody.
    function configureBook0fLife(address newBook, address compatibleMetadata, address compatibleFusion)
        external
        onlyRole(CONFIG_ROLE)
    {
        _requireContract(BinderIds.MODULE_BOOK_OF_LIFE, newBook);
        _requireMetadataDependencies(compatibleMetadata, newBook, book0fArts);
        _requireContract(BinderIds.MODULE_FUSION_MINTER, compatibleFusion);
        if (IFusionMinter(compatibleFusion).binderData() != binderData) {
            revert CanonicalPairMismatch(binderData, IFusionMinter(compatibleFusion).binderData());
        }
        if (IFusionMinter(compatibleFusion).book0fLife() != newBook) {
            revert CanonicalPairMismatch(newBook, IFusionMinter(compatibleFusion).book0fLife());
        }

        IBook0fLife(newBook).setFusionMinter(compatibleFusion);
        if (scaleOfBalance != address(0)) IScaleOfBalance(scaleOfBalance).setBook0fLife(newBook);
        if (binderLogic != address(0)) IBinderLogic(binderLogic).setBook0fLife(newBook);
        if (allegianceRegistry != address(0)) IBook0fLife(newBook).setAllegianceRegistry(allegianceRegistry);
        IBinderData(binderData).setAuthorizedFusionMinter(compatibleFusion, true);
        IBinderData(binderData).setActivityController(BinderIds.ACTIVITY_FUSION, compatibleFusion);
        IBinderData(binderData).setBinderMetadata(compatibleMetadata);

        address oldBook = book0fLife;
        address oldMetadata = binderMetadata;
        address oldFusion = fusionMinter;
        book0fLife = newBook;
        binderMetadata = compatibleMetadata;
        fusionMinter = compatibleFusion;
        emit CanonicalModuleUpdated(BinderIds.MODULE_BOOK_OF_LIFE, oldBook, newBook);
        emit CanonicalModuleUpdated(BinderIds.MODULE_BINDER_METADATA, oldMetadata, compatibleMetadata);
        emit CanonicalModuleUpdated(BinderIds.MODULE_FUSION_MINTER, oldFusion, compatibleFusion);

        if (
            IBinderData(binderData).binderMetadataAddress() != compatibleMetadata
                || IBinderData(binderData).getActivityController(BinderIds.ACTIVITY_FUSION) != compatibleFusion
        ) revert CanonicalPairMismatch(compatibleMetadata, IBinderData(binderData).binderMetadataAddress());
    }

    /// @notice Cuts over Book0fArts and its immutable renderer dependency in
    /// the same transaction, so the registry never advertises a mismatched UI.
    function configureBook0fArts(address newBook, address compatibleMetadata) external onlyRole(CONFIG_ROLE) {
        _requireContract(BinderIds.MODULE_BOOK_OF_ARTS, newBook);
        _requireMetadataDependencies(compatibleMetadata, book0fLife, newBook);
        IBinderData(binderData).setBinderMetadata(compatibleMetadata);

        address oldBook = book0fArts;
        address oldMetadata = binderMetadata;
        book0fArts = newBook;
        binderMetadata = compatibleMetadata;
        emit CanonicalModuleUpdated(BinderIds.MODULE_BOOK_OF_ARTS, oldBook, newBook);
        emit CanonicalModuleUpdated(BinderIds.MODULE_BINDER_METADATA, oldMetadata, compatibleMetadata);
        if (IBinderData(binderData).binderMetadataAddress() != compatibleMetadata) {
            revert CanonicalPairMismatch(compatibleMetadata, IBinderData(binderData).binderMetadataAddress());
        }
    }

    function setBook0fRealms(address moduleAddress) external override onlyRole(CONFIG_ROLE) {
        _setModule(BinderIds.MODULE_BOOK_OF_REALMS, book0fRealms, moduleAddress);
        book0fRealms = moduleAddress;
    }

    function setBinderLogic(address moduleAddress) external override onlyRole(CONFIG_ROLE) {
        _requireContract(BinderIds.MODULE_BINDER_LOGIC, moduleAddress);
        if (IBinderLogic(moduleAddress).binderData() != binderData) {
            revert CanonicalPairMismatch(binderData, IBinderLogic(moduleAddress).binderData());
        }
        if (book0fLife != address(0) && IBinderLogic(moduleAddress).book0fLife() != book0fLife) {
            revert CanonicalPairMismatch(book0fLife, IBinderLogic(moduleAddress).book0fLife());
        }
        if (allegianceRegistry != address(0) && IBinderLogic(moduleAddress).allegianceRegistry() != allegianceRegistry)
        {
            revert CanonicalPairMismatch(allegianceRegistry, IBinderLogic(moduleAddress).allegianceRegistry());
        }
        if (!IBinderLogic(moduleAddress).hasRole(IBinderLogic(moduleAddress).CONFIG_ROLE(), address(this))) {
            revert CanonicalPairMismatch(address(this), address(0));
        }
        address previousModule = binderLogic;
        if (previousModule != address(0) && previousModule != moduleAddress) {
            IBinderLogic(previousModule).setAcceptingRequests(false);
        }
        if (!IBinderLogic(moduleAddress).acceptingRequests()) {
            IBinderLogic(moduleAddress).setAcceptingRequests(true);
        }
        IBinderData(binderData).setAuthorizedBinderLogic(moduleAddress, true);
        _setModule(BinderIds.MODULE_BINDER_LOGIC, previousModule, moduleAddress);
        binderLogic = moduleAddress;
        if (
            !IBinderData(binderData).authorizedBinderLogic(moduleAddress)
                || !IBinderLogic(moduleAddress).acceptingRequests()
                || (
                    previousModule != address(0) && previousModule != moduleAddress
                        && IBinderLogic(previousModule).acceptingRequests()
                )
        ) {
            revert CanonicalPairMismatch(moduleAddress, address(0));
        }
    }

    /// @notice Retires a disabled mint orchestrator once all of its entropy
    /// requests have reached a terminal state. BinderData also clears its
    /// legacy role so no historical authorization can survive retirement.
    function finalizeBinderLogicRetirement(address oldLogic) external onlyRole(CONFIG_ROLE) {
        if (oldLogic == address(0) || oldLogic == binderLogic) revert ModuleStillCanonical(oldLogic);
        if (IBinderLogic(oldLogic).acceptingRequests()) {
            revert CanonicalPairMismatch(address(0), oldLogic);
        }
        uint256 pendingCount = IBinderLogic(oldLogic).pendingMintCount();
        if (pendingCount != 0) revert PendingMintsPreventRetirement(oldLogic, pendingCount);
        IBinderData(binderData).setAuthorizedBinderLogic(oldLogic, false);
        if (IBinderData(binderData).authorizedBinderLogic(oldLogic)) {
            revert CanonicalPairMismatch(address(0), oldLogic);
        }
    }

    function setFusionMinter(address moduleAddress) external override onlyRole(CONFIG_ROLE) {
        _requireContract(BinderIds.MODULE_FUSION_MINTER, moduleAddress);
        address minterBinderData;
        try IFusionMinter(moduleAddress).binderData() returns (address resolvedBinderData) {
            minterBinderData = resolvedBinderData;
        } catch {
            revert CanonicalPairMismatch(binderData, address(0));
        }
        if (minterBinderData != binderData) revert CanonicalPairMismatch(binderData, minterBinderData);
        if (book0fLife == address(0) || IFusionMinter(moduleAddress).book0fLife() != book0fLife) {
            revert CanonicalPairMismatch(book0fLife, IFusionMinter(moduleAddress).book0fLife());
        }
        IBinderData(binderData).setAuthorizedFusionMinter(moduleAddress, true);
        IBinderData(binderData).setActivityController(BinderIds.ACTIVITY_FUSION, moduleAddress);
        if (IBook0fLife(book0fLife).currentFusionMinter() != moduleAddress) {
            IBook0fLife(book0fLife).setFusionMinter(moduleAddress);
        }
        _setModule(BinderIds.MODULE_FUSION_MINTER, fusionMinter, moduleAddress);
        fusionMinter = moduleAddress;
        if (
            !IBinderData(binderData).authorizedFusionMinter(moduleAddress)
                || IBinderData(binderData).getActivityController(BinderIds.ACTIVITY_FUSION) != moduleAddress
        ) {
            revert CanonicalPairMismatch(
                moduleAddress, IBinderData(binderData).getActivityController(BinderIds.ACTIVITY_FUSION)
            );
        }
    }

    /// @notice Retires an outgoing FusionMinter after every Binder it custody
    /// bound has either resolved or been rescued.
    function finalizeFusionMinterRetirement(address oldMinter) external onlyRole(CONFIG_ROLE) {
        if (oldMinter == address(0) || oldMinter == fusionMinter) revert ModuleStillCanonical(oldMinter);
        uint256 activeCount = IBinderData(binderData).activeFusionCountByMinter(oldMinter);
        if (activeCount != 0) revert PendingFusionsPreventRetirement(oldMinter, activeCount);
        uint256 pendingCount = IFusionMinter(oldMinter).pendingFusionCount();
        if (pendingCount != 0) revert PendingFusionsPreventRetirement(oldMinter, pendingCount);
        IBinderData(binderData).setAuthorizedFusionMinter(oldMinter, false);
        IBook0fLife(book0fLife).revokeFusionMinter(oldMinter);
        if (IBinderData(binderData).authorizedFusionMinter(oldMinter)) {
            revert CanonicalPairMismatch(address(0), oldMinter);
        }
    }

    function setScaleOfBalance(address moduleAddress) external override onlyRole(CONFIG_ROLE) {
        _requireContract(BinderIds.MODULE_SCALE_OF_BALANCE, moduleAddress);
        if (IScaleOfBalance(moduleAddress).binderData() != binderData) {
            revert CanonicalPairMismatch(binderData, IScaleOfBalance(moduleAddress).binderData());
        }
        if (book0fLife == address(0) || IScaleOfBalance(moduleAddress).book0fLife() != book0fLife) {
            revert CanonicalPairMismatch(book0fLife, IScaleOfBalance(moduleAddress).book0fLife());
        }
        IBinderData data = IBinderData(binderData);
        IBook0fLife life = IBook0fLife(book0fLife);
        address previousScale = scaleOfBalance;
        data.setScaleOfBalanceAuthority(previousScale, moduleAddress);
        life.setScaleOfBalanceAuthority(previousScale, moduleAddress);
        _setModule(BinderIds.MODULE_SCALE_OF_BALANCE, previousScale, moduleAddress);
        scaleOfBalance = moduleAddress;
        if (
            !data.hasRole(data.CONFIG_ROLE(), moduleAddress) || !life.hasRole(life.CONFIG_ROLE(), moduleAddress)
                || (
                    previousScale != address(0)
                        && (data.hasRole(data.CONFIG_ROLE(), previousScale) || life.hasRole(life.CONFIG_ROLE(), previousScale))
                )
        ) revert CanonicalPairMismatch(moduleAddress, address(0));
    }

    function setBattleFactory(address moduleAddress, uint32 implementationVersion)
        external
        override
        onlyRole(CONFIG_ROLE)
    {
        _requireContract(BinderIds.MODULE_BATTLE_FACTORY, moduleAddress);
        address factoryConsole;
        address implementation;
        try IBattleFactory(moduleAddress).centralConsole() returns (address resolvedConsole) {
            factoryConsole = resolvedConsole;
        } catch {
            revert CanonicalPairMismatch(address(this), address(0));
        }
        try IBattleFactory(moduleAddress).battleImplementation() returns (address resolvedImplementation) {
            implementation = resolvedImplementation;
        } catch {
            revert CanonicalPairMismatch(address(0), address(0));
        }
        if (factoryConsole != address(this)) revert CanonicalPairMismatch(address(this), factoryConsole);
        if (implementation.code.length == 0) {
            revert InvalidModuleAddress(BinderIds.MODULE_BATTLE_FACTORY, implementation);
        }
        uint32 previousVersion = battleFactoryVersion;
        if (implementationVersion == 0 || implementationVersion <= previousVersion) {
            revert InvalidModuleVersion(BinderIds.MODULE_BATTLE_FACTORY, previousVersion, implementationVersion);
        }

        address previousFactory = battleFactory;
        IBinderData(binderData).setAuthorizedBattleFactory(moduleAddress, true);
        IBinderData(binderData).setActivityController(BinderIds.ACTIVITY_BATTLE, moduleAddress);
        battleFactory = moduleAddress;
        battleFactoryVersion = implementationVersion;
        emit CanonicalModuleUpdated(BinderIds.MODULE_BATTLE_FACTORY, previousFactory, moduleAddress);
        emit BattleFactoryVersionUpdated(previousFactory, moduleAddress, previousVersion, implementationVersion);
        if (
            !IBinderData(binderData).authorizedBattleFactory(moduleAddress)
                || IBinderData(binderData).getActivityController(BinderIds.ACTIVITY_BATTLE) != moduleAddress
        ) {
            revert CanonicalPairMismatch(
                moduleAddress, IBinderData(binderData).getActivityController(BinderIds.ACTIVITY_BATTLE)
            );
        }
    }

    function setAllegianceRegistry(address moduleAddress) external override onlyRole(CONFIG_ROLE) {
        _requireContract(BinderIds.MODULE_ALLEGIANCE_REGISTRY, moduleAddress);
        if (book0fLife != address(0)) IBook0fLife(book0fLife).setAllegianceRegistry(moduleAddress);
        if (binderLogic != address(0)) IBinderLogic(binderLogic).setAllegianceRegistry(moduleAddress);
        _setModule(BinderIds.MODULE_ALLEGIANCE_REGISTRY, allegianceRegistry, moduleAddress);
        allegianceRegistry = moduleAddress;
    }

    /// @notice Registers and activates the canonical controller for a future activity type.
    function setActivityModule(uint8 activityId, address moduleAddress) external override onlyRole(CONFIG_ROLE) {
        if (
            activityId == BinderIds.ACTIVITY_IDLE || activityId == BinderIds.ACTIVITY_BATTLE
                || activityId == BinderIds.ACTIVITY_FUSION
        ) revert InvalidActivityModuleId(activityId);
        _requireContract(bytes32(uint256(activityId)), moduleAddress);

        address previousModule = activityModule[activityId];
        IBinderData(binderData).setActivityController(activityId, moduleAddress);
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

    function getWiringStatus() external view override returns (WiringStatus memory status) {
        return _wiringStatus();
    }

    function isFullyWired() external view override returns (bool) {
        return wiringDiagnostics.isFullyWired(_wiringStatus());
    }

    function _wiringStatus() internal view returns (WiringStatus memory) {
        WiringDiagnostics.WiringInput memory input = WiringDiagnostics.WiringInput({
            console: address(this),
            binderData: binderData,
            binderSkills: binderSkills,
            binderMetadata: binderMetadata,
            book0fLife: book0fLife,
            book0fArts: book0fArts,
            book0fRealms: book0fRealms,
            binderLogic: binderLogic,
            fusionMinter: fusionMinter,
            scaleOfBalance: scaleOfBalance,
            battleFactory: battleFactory,
            battleFactoryVersion: battleFactoryVersion,
            allegianceRegistry: allegianceRegistry
        });
        return wiringDiagnostics.collect(input);
    }

    function _setModule(bytes32 moduleId, address previousModule, address newModule) internal {
        _requireContract(moduleId, newModule);
        emit CanonicalModuleUpdated(moduleId, previousModule, newModule);
    }

    function _requireMetadataDependencies(address moduleAddress, address expectedBookLife, address expectedBookArts)
        internal
        view
    {
        _requireContract(BinderIds.MODULE_BINDER_METADATA, moduleAddress);
        if (
            IBinderMetadata(moduleAddress).binderData() != binderData
                || IBinderMetadata(moduleAddress).binderSkills() != binderSkills
                || IBinderMetadata(moduleAddress).book0fLife() != expectedBookLife
                || IBinderMetadata(moduleAddress).book0fArts() != expectedBookArts
        ) revert CanonicalPairMismatch(binderData, IBinderMetadata(moduleAddress).binderData());
    }

    function _requireMetadataDependenciesForSkills(
        address moduleAddress,
        address expectedSkills,
        address expectedBookLife,
        address expectedBookArts
    ) internal view {
        _requireContract(BinderIds.MODULE_BINDER_METADATA, moduleAddress);
        if (
            IBinderMetadata(moduleAddress).binderData() != binderData
                || IBinderMetadata(moduleAddress).binderSkills() != expectedSkills
                || IBinderMetadata(moduleAddress).book0fLife() != expectedBookLife
                || IBinderMetadata(moduleAddress).book0fArts() != expectedBookArts
        ) revert CanonicalSkillsMismatch(expectedSkills, IBinderMetadata(moduleAddress).binderSkills());
    }

    function _requireContract(bytes32 moduleId, address moduleAddress) internal view {
        if (moduleAddress == address(0) || moduleAddress.code.length == 0) {
            revert InvalidModuleAddress(moduleId, moduleAddress);
        }
    }
}
