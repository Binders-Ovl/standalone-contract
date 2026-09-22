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
import "../interfaces/IBook0fArts.sol";
import "../interfaces/IBook0fRealms.sol";
import "../interfaces/IFusionMinter.sol";
import "../interfaces/IBinderLogic.sol";
import "../interfaces/IScaleOfBalance.sol";
import "../interfaces/IBattleFactory.sol";
import "../interfaces/IBook0fItems.sol";
import "../interfaces/IBinderInventory.sol";
import "../interfaces/IEquipment.sol";
import "../interfaces/ITomeAndGrimoires.sol";
import "../interfaces/ISItems.sol";
import "../interfaces/IItemUseRouter.sol";
import "../interfaces/IItemStatsView.sol";
import "../interfaces/ICreatorTokenTransferValidatorV5.sol";
import "@openzeppelin/contracts-4.8/access/IAccessControl.sol";
import "./WiringDiagnostics.sol";
import "./ItemBookConfigurator.sol";

/// @notice Canonical Binders module registry and configuration control plane.
/// @dev It deliberately has no arbitrary call primitive and owns no NFT, Book,
/// learned-skill, or battle gameplay state. BinderData is bound once at deployment.
contract CentralConsole is AccessControl, ICentralConsole, ItemBookConfigurator {
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
    address public override book0fItems;
    address public override binderInventory;
    address public override equipment;
    address public override tomeAndGrimoires;
    address public override sItems;
    address public override itemUseRouter;
    address public override itemMetadataBuilder;
    address public override itemStatsView;
    address public override goldAsset;
    mapping(uint8 => address) public override activityModule;
    WiringDiagnostics private immutable wiringDiagnostics;

    event CanonicalModuleUpdated(bytes32 indexed moduleId, address indexed previousModule, address indexed newModule);
    event BattleFactoryVersionUpdated(
        address indexed previousFactory, address indexed newFactory, uint32 previousVersion, uint32 newVersion
    );
    event ActivityModuleUpdated(uint8 indexed activityId, address indexed previousModule, address indexed newModule);
    event ItemSystemConfigured(
        address indexed book, address indexed inventory, address equipment, address tomes, address sItems
    );
    event ItemTransferPolicyUpdated(address indexed collection, address indexed validator, uint48 listId);
    event GoldAssetUpdated(address indexed previousAsset, address indexed newAsset);
    event ItemIssuerConfigured(address indexed collection, address indexed issuer, bool allowed);

    error PendingMintsPreventRetirement(address logic, uint256 pendingCount);
    error PendingFusionsPreventRetirement(address minter, uint256 pendingCount);
    error ModuleStillCanonical(address module);
    error InvalidItemSystem(address component);
    error UnknownItemCollection(address collection);

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
        _wireReplacementBook0fArts(moduleAddress);
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
        _wireReplacementBook0fArts(newBook);
        book0fArts = newBook;
        binderMetadata = compatibleMetadata;
        emit CanonicalModuleUpdated(BinderIds.MODULE_BOOK_OF_ARTS, oldBook, newBook);
        emit CanonicalModuleUpdated(BinderIds.MODULE_BINDER_METADATA, oldMetadata, compatibleMetadata);
        if (IBinderData(binderData).binderMetadataAddress() != compatibleMetadata) {
            revert CanonicalPairMismatch(compatibleMetadata, IBinderData(binderData).binderMetadataAddress());
        }
    }

    function setBook0fRealms(address moduleAddress) external override onlyRole(CONFIG_ROLE) {
        _wireReplacementBook0fRealms(moduleAddress);
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
        _configureScaleTargets(moduleAddress);
        _setScaleBalanceAuthorities(previousScale, moduleAddress);
        if (book0fItems != address(0)) {
            IBook0fItems(book0fItems).setItemsConfigAuthority(previousScale, moduleAddress);
            bytes32 itemsRole = IBook0fItems(book0fItems).ITEMS_CONFIG_ROLE();
            if (!IAccessControl(book0fItems).hasRole(itemsRole, moduleAddress)) {
                revert CanonicalPairMismatch(moduleAddress, address(0));
            }
        }
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

    function _configureScaleTargets(address scale) private {
        if (book0fItems != address(0) && IScaleOfBalance(scale).book0fItems() != book0fItems) {
            _requireScaleConfigAuthority(scale);
            IScaleOfBalance(scale).setBook0fItems(book0fItems);
        }
        if (book0fArts != address(0) && IScaleOfBalance(scale).book0fArts() != book0fArts) {
            _requireScaleConfigAuthority(scale);
            IScaleOfBalance(scale).setBook0fArts(book0fArts);
        }
        if (book0fRealms != address(0) && IScaleOfBalance(scale).book0fRealms() != book0fRealms) {
            _requireScaleConfigAuthority(scale);
            IScaleOfBalance(scale).setBook0fRealms(book0fRealms);
        }
    }

    function _wireReplacementBook0fArts(address newBook) private {
        address activeScale = scaleOfBalance;
        if (activeScale == address(0)) return;

        if (IScaleOfBalance(activeScale).book0fArts() != newBook) {
            _requireScaleConfigAuthority(activeScale);
            IScaleOfBalance(activeScale).setBook0fArts(newBook);
        }
        IBook0fArts(newBook).setScaleOfBalanceAuthority(address(0), activeScale);
        if (book0fArts != address(0) && book0fArts != newBook) {
            IBook0fArts(book0fArts).setScaleOfBalanceAuthority(activeScale, address(0));
        }
        _requireBalanceAuthority(newBook, activeScale, IBook0fArts(newBook).BALANCE_ROLE());
    }

    function _wireReplacementBook0fRealms(address newBook) private {
        _requireContract(BinderIds.MODULE_BOOK_OF_REALMS, newBook);
        address activeScale = scaleOfBalance;
        if (activeScale == address(0)) return;

        if (IScaleOfBalance(activeScale).book0fRealms() != newBook) {
            _requireScaleConfigAuthority(activeScale);
            IScaleOfBalance(activeScale).setBook0fRealms(newBook);
        }
        IBook0fRealms(newBook).setScaleOfBalanceAuthority(address(0), activeScale);
        if (book0fRealms != address(0) && book0fRealms != newBook) {
            IBook0fRealms(book0fRealms).setScaleOfBalanceAuthority(activeScale, address(0));
        }
        _requireBalanceAuthority(newBook, activeScale, IBook0fRealms(newBook).BALANCE_ROLE());
    }

    function _setScaleBalanceAuthorities(address previousScale, address newScale) private {
        if (book0fArts != address(0)) {
            IBook0fArts(book0fArts).setScaleOfBalanceAuthority(previousScale, newScale);
            _requireBalanceAuthority(book0fArts, newScale, IBook0fArts(book0fArts).BALANCE_ROLE());
        }
        if (book0fRealms != address(0)) {
            IBook0fRealms(book0fRealms).setScaleOfBalanceAuthority(previousScale, newScale);
            _requireBalanceAuthority(book0fRealms, newScale, IBook0fRealms(book0fRealms).BALANCE_ROLE());
        }
    }

    function _requireScaleConfigAuthority(address scale) private view {
        if (!IAccessControl(scale).hasRole(IScaleOfBalance(scale).CONFIG_ROLE(), address(this))) {
            revert CanonicalPairMismatch(address(this), address(0));
        }
    }

    function _requireBalanceAuthority(address book, address scale, bytes32 balanceRole) private view {
        if (!IAccessControl(book).hasRole(balanceRole, scale)) revert CanonicalPairMismatch(scale, address(0));
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

    /// @notice Atomically wires the fixed item graph. This Console owns the ERC-C collections, so no arbitrary
    /// call surface is required to configure their inventory, metadata, or transfer policy paths.
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
    ) external override onlyRole(CONFIG_ROLE) {
        _requireContract(BinderIds.MODULE_BOOK_OF_ITEMS, bookAddress);
        _requireContract(BinderIds.MODULE_BINDER_INVENTORY, inventoryAddress);
        _requireContract(BinderIds.MODULE_EQUIPMENT, equipmentAddress);
        _requireContract(BinderIds.MODULE_TOME_AND_GRIMOIRES, tomeAddress);
        _requireContract(BinderIds.MODULE_SITEMS, sItemAddress);
        _requireContract(BinderIds.MODULE_ITEM_USE_ROUTER, routerAddress);
        _requireContract(BinderIds.MODULE_ITEM_METADATA_BUILDER, metadataBuilderAddress);
        _requireContract(BinderIds.MODULE_ITEM_STATS_VIEW, statsViewAddress);
        if (binderSkills == address(0) || book0fArts == address(0)) revert InvalidItemSystem(address(0));
        if (book0fItems != address(0) && book0fItems != bookAddress) revert InvalidItemSystem(bookAddress);
        if (binderInventory != address(0) && binderInventory != inventoryAddress) {
            revert InvalidItemSystem(inventoryAddress);
        }

        IBook0fItems itemBook = IBook0fItems(bookAddress);
        if (
            address(itemBook.book0fArts()) != book0fArts
                || !IAccessControl(bookAddress).hasRole(itemBook.ITEMS_CONFIG_ROLE(), address(this))
        ) revert InvalidItemSystem(bookAddress);

        IBinderInventory inventory = IBinderInventory(inventoryAddress);
        if (
            inventory.centralConsole() != address(this) || _inventoryBinderData(inventoryAddress) != binderData
                || address(inventory.book()) != bookAddress
        ) revert InvalidItemSystem(inventoryAddress);
        _validateItemCollection(equipmentAddress);
        _validateItemCollection(tomeAddress);
        _validateItemCollection(sItemAddress);
        if (
            address(IItemUseRouter(routerAddress).binderData()) != binderData
                || address(IItemUseRouter(routerAddress).book()) != bookAddress
                || address(IItemUseRouter(routerAddress).inventory()) != inventoryAddress
                || address(IItemStatsView(statsViewAddress).binderData()) != binderData
        ) revert InvalidItemSystem(routerAddress);

        if (address(inventory.equipment()) == address(0)) {
            inventory.setCollections(equipmentAddress, tomeAddress, sItemAddress);
        } else if (
            address(inventory.equipment()) != equipmentAddress || address(inventory.tomes()) != tomeAddress
                || address(inventory.sItems()) != sItemAddress
        ) {
            revert InvalidItemSystem(inventoryAddress);
        }
        IEquipment(equipmentAddress).setInventory(inventoryAddress);
        ITomeAndGrimoires(tomeAddress).setInventory(inventoryAddress);
        ISItems(sItemAddress).setInventory(inventoryAddress);
        inventory.setStatsView(statsViewAddress);
        inventory.setBinderSkills(binderSkills);
        inventory.setItemUseRouter(routerAddress);
        IBinderData(binderData).setItemUseRouter(itemUseRouter, routerAddress);
        IBinderSkills(binderSkills).setTomeLearningDependencies(
            bookAddress, inventoryAddress, entropyAddress, entropyProvider
        );

        _setModule(BinderIds.MODULE_BOOK_OF_ITEMS, book0fItems, bookAddress);
        _setModule(BinderIds.MODULE_BINDER_INVENTORY, binderInventory, inventoryAddress);
        _setModule(BinderIds.MODULE_EQUIPMENT, equipment, equipmentAddress);
        _setModule(BinderIds.MODULE_TOME_AND_GRIMOIRES, tomeAndGrimoires, tomeAddress);
        _setModule(BinderIds.MODULE_SITEMS, sItems, sItemAddress);
        _setModule(BinderIds.MODULE_ITEM_USE_ROUTER, itemUseRouter, routerAddress);
        _setModule(BinderIds.MODULE_ITEM_METADATA_BUILDER, itemMetadataBuilder, metadataBuilderAddress);
        _setModule(BinderIds.MODULE_ITEM_STATS_VIEW, itemStatsView, statsViewAddress);
        book0fItems = bookAddress;
        binderInventory = inventoryAddress;
        equipment = equipmentAddress;
        tomeAndGrimoires = tomeAddress;
        sItems = sItemAddress;
        itemUseRouter = routerAddress;
        itemMetadataBuilder = metadataBuilderAddress;
        itemStatsView = statsViewAddress;
        if (scaleOfBalance != address(0)) _configureScaleTargets(scaleOfBalance);
        emit ItemSystemConfigured(bookAddress, inventoryAddress, equipmentAddress, tomeAddress, sItemAddress);
    }

    function _itemBookForConfig() internal view override onlyRole(CONFIG_ROLE) returns (IBook0fItems) {
        if (book0fItems == address(0)) revert InvalidItemSystem(book0fItems);
        return IBook0fItems(book0fItems);
    }

    function setGoldAsset(address asset) external override onlyRole(CONFIG_ROLE) {
        if (asset != address(0) && asset.code.length == 0) revert InvalidItemSystem(asset);
        emit GoldAssetUpdated(goldAsset, asset);
        goldAsset = asset;
    }

    function setItemIssuer(address collection, address issuer, bool allowed) external override onlyRole(CONFIG_ROLE) {
        _itemCollection(collection).setIssuer(issuer, allowed);
        emit ItemIssuerConfigured(collection, issuer, allowed);
    }

    function setItemTransferValidator(address collection, address validator) external override onlyRole(CONFIG_ROLE) {
        if (validator != address(0) && validator.code.length == 0) revert InvalidItemSystem(validator);
        _itemCollection(collection).setTransferValidator(validator);
        emit ItemTransferPolicyUpdated(collection, validator, 0);
    }

    function configureItemTransferRuleset(
        address collection,
        uint8 rulesetId,
        address customRuleset,
        uint8 globalOptions,
        uint16 rulesetOptions
    ) external override onlyRole(CONFIG_ROLE) {
        _itemCollection(collection).configureTransferRuleset(rulesetId, customRuleset, globalOptions, rulesetOptions);
        emit ItemTransferPolicyUpdated(collection, _itemCollection(collection).getTransferValidator(), 0);
    }

    function applyItemTransferList(address collection, uint48 listId) external override onlyRole(CONFIG_ROLE) {
        _itemCollection(collection).applyTransferList(listId);
        emit ItemTransferPolicyUpdated(collection, _itemCollection(collection).getTransferValidator(), listId);
    }

    function createItemTransferList(address collection, string calldata name)
        external
        override
        onlyRole(CONFIG_ROLE)
        returns (uint48 listId)
    {
        address validator = _itemCollection(collection).getTransferValidator();
        if (validator == address(0)) revert InvalidItemSystem(validator);
        listId = ICreatorTokenTransferValidatorV5(validator).createList(name);
        if (listId == 0 || ICreatorTokenTransferValidatorV5(validator).listOwners(listId) != address(this)) {
            revert InvalidItemSystem(validator);
        }
        emit ItemTransferPolicyUpdated(collection, validator, listId);
    }

    function addItemTransferListAccounts(address collection, uint48 listId, uint8 listType, address[] calldata accounts)
        external
        override
        onlyRole(CONFIG_ROLE)
    {
        ICreatorTokenTransferValidatorV5(_itemCollection(collection).getTransferValidator()).addAccountsToList(
            listId, listType, accounts
        );
    }

    function addItemTransferListCodeHashes(
        address collection,
        uint48 listId,
        uint8 listType,
        bytes32[] calldata codehashes
    ) external override onlyRole(CONFIG_ROLE) {
        ICreatorTokenTransferValidatorV5(_itemCollection(collection).getTransferValidator()).addCodeHashesToList(
            listId, listType, codehashes
        );
    }

    function setItemBaseImageURI(address collection, string calldata value) external override onlyRole(CONFIG_ROLE) {
        _itemCollection(collection).setBaseImageURI(value);
    }

    function setItemImageURI(address collection, uint16 libraryId, string calldata value)
        external
        override
        onlyRole(CONFIG_ROLE)
    {
        _itemCollection(collection).setImageURI(libraryId, value);
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
        if (moduleId == BinderIds.MODULE_BOOK_OF_ITEMS) return book0fItems;
        if (moduleId == BinderIds.MODULE_BINDER_INVENTORY) return binderInventory;
        if (moduleId == BinderIds.MODULE_EQUIPMENT) return equipment;
        if (moduleId == BinderIds.MODULE_TOME_AND_GRIMOIRES) return tomeAndGrimoires;
        if (moduleId == BinderIds.MODULE_SITEMS) return sItems;
        if (moduleId == BinderIds.MODULE_ITEM_USE_ROUTER) return itemUseRouter;
        if (moduleId == BinderIds.MODULE_ITEM_METADATA_BUILDER) return itemMetadataBuilder;
        if (moduleId == BinderIds.MODULE_ITEM_STATS_VIEW) return itemStatsView;
        revert UnknownCanonicalModule(moduleId);
    }

    function isCanonicalModule(address moduleAddress) external view override returns (bool) {
        return moduleAddress != address(0)
            && (
                moduleAddress == binderData || moduleAddress == binderSkills || moduleAddress == binderMetadata
                    || moduleAddress == book0fLife || moduleAddress == book0fArts || moduleAddress == book0fRealms
                    || moduleAddress == binderLogic || moduleAddress == fusionMinter || moduleAddress == scaleOfBalance
                    || moduleAddress == battleFactory || moduleAddress == allegianceRegistry || moduleAddress == book0fItems
                    || moduleAddress == binderInventory || moduleAddress == equipment || moduleAddress == tomeAndGrimoires
                    || moduleAddress == sItems || moduleAddress == itemUseRouter || moduleAddress == itemMetadataBuilder
                    || moduleAddress == itemStatsView
            );
    }

    function getWiringStatus() external view override returns (WiringStatus memory status) {
        return _wiringStatus();
    }

    function isFullyWired() external view override returns (bool) {
        return wiringDiagnostics.isFullyWired(_wiringStatus());
    }

    function getItemWiringStatus() external view override returns (ItemWiringStatus memory status) {
        if (book0fItems == address(0) || binderInventory == address(0)) return status;
        IBook0fItems itemBook = IBook0fItems(book0fItems);
        status.bookAuthorityMatch = address(itemBook.book0fArts()) == book0fArts
            && IAccessControl(book0fItems).hasRole(itemBook.ITEMS_CONFIG_ROLE(), address(this));
        IBinderInventory inventory = IBinderInventory(binderInventory);
        status.inventoryDependenciesMatch = inventory.centralConsole() == address(this)
            && _inventoryBinderData(binderInventory) == binderData && address(inventory.book()) == book0fItems;
        status.collectionsMatch = address(inventory.equipment()) == equipment
            && address(inventory.tomes()) == tomeAndGrimoires && address(inventory.sItems()) == sItems;
        status.collectionOwnershipMatch = equipment != address(0) && tomeAndGrimoires != address(0)
            && sItems != address(0) && IEquipment(equipment).owner() == address(this)
            && ITomeAndGrimoires(tomeAndGrimoires).owner() == address(this) && ISItems(sItems).owner() == address(this);
        status.routerDependenciesMatch = itemUseRouter != address(0)
            && address(IItemUseRouter(itemUseRouter).binderData()) == binderData
            && address(IItemUseRouter(itemUseRouter).book()) == book0fItems
            && address(IItemUseRouter(itemUseRouter).inventory()) == binderInventory;
        status.skillsDependenciesMatch = binderSkills != address(0)
            && address(IBinderSkills(binderSkills).book0fItems()) == book0fItems
            && address(IBinderSkills(binderSkills).binderInventory()) == binderInventory;
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

    function _validateItemCollection(address collection) private view {
        IItemCollection candidate = IItemCollection(collection);
        if (candidate.owner() != address(this)) revert InvalidItemSystem(collection);
    }

    function _inventoryBinderData(address inventory) private view returns (address data) {
        (bool ok, bytes memory result) = inventory.staticcall(abi.encodeWithSignature("binderData()"));
        if (!ok || result.length != 32) return address(0);
        data = abi.decode(result, (address));
    }

    function _itemCollection(address collection) private view returns (IItemCollection) {
        if (
            collection == address(0)
                || (collection != equipment && collection != tomeAndGrimoires && collection != sItems)
        ) {
            revert UnknownItemCollection(collection);
        }
        return IItemCollection(collection);
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
