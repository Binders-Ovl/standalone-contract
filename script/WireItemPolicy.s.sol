// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../modular/Items/BindersTBAWhitelistExtension.sol";
import "../modular/interfaces/ICreatorTokenTransferValidatorV5.sol";

interface IItemPolicyConsole {
    function binderData() external view returns (address);
    function fusionMinter() external view returns (address);
    function book0fItems() external view returns (address);
    function binderInventory() external view returns (address);
    function equipment() external view returns (address);
    function tomeAndGrimoires() external view returns (address);
    function sItems() external view returns (address);
    function itemUseRouter() external view returns (address);
    function itemMetadataBuilder() external view returns (address);
    function itemStatsView() external view returns (address);
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
    function setItemIssuer(address collection, address issuer, bool allowed) external;
    function setItemTransferValidator(address collection, address validator) external;
    function configureItemTransferRuleset(
        address collection,
        uint8 rulesetId,
        address customRuleset,
        uint8 globalOptions,
        uint16 rulesetOptions
    ) external;
    function createItemTransferList(address collection, string calldata name) external returns (uint48 listId);
    function applyItemTransferList(address collection, uint48 listId) external;
    function addItemTransferListAccounts(address collection, uint48 listId, uint8 listType, address[] calldata accounts)
        external;
}

interface IFusionInventorySetter {
    function setBinderInventory(address inventory) external;
}

/// @notice Wires collections to CentralConsole and pins their V5 whitelist policy.
contract WireItemPolicy is Script {
    bytes32 internal constant TBA_SALT = keccak256("BINDERS_ERC6551_V1");
    uint8 internal constant RULESET_ID_FIXED = 255;
    uint8 internal constant LIST_TYPE_WHITELIST = 1;
    uint8 internal constant LIST_TYPE_WHITELIST_EXTENSION = 3;
    uint16 internal constant WHITELIST_BLOCK_ALL_OTC_AND_SMART_WALLETS = 9;

    struct Deployment {
        address whitelistExtension;
        uint48 equipmentListId;
        uint48 tomeListId;
        uint48 sItemListId;
    }

    struct WireInput {
        address registry;
        address tbaImplementation;
        address validator;
        address whitelistRuleset;
        address book;
        address inventory;
        address metadataBuilder;
        address statsView;
        address router;
        address equipment;
        address tomes;
        address sItems;
    }

    function run() external returns (Deployment memory deployment) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        WireInput memory input = _loadInput();
        _requireCodeHash(input.registry, vm.envBytes32("ERC6551_REGISTRY_CODEHASH"));
        _requireCodeHash(input.tbaImplementation, vm.envBytes32("TBA_IMPLEMENTATION_CODEHASH"));
        _requireCodeHash(input.validator, vm.envBytes32("CREATOR_TOKEN_VALIDATOR_CODEHASH"));
        _requireCodeHash(input.whitelistRuleset, vm.envBytes32("CREATOR_TOKEN_WHITELIST_RULESET_CODEHASH"));

        vm.startBroadcast(deployerKey);
        deployment = _wire(IItemPolicyConsole(vm.envAddress("CENTRAL_CONSOLE")), input, vm.addr(deployerKey));
        vm.stopBroadcast();
    }

    function _wire(IItemPolicyConsole controlPlane, WireInput memory input, address initialIssuer)
        private
        returns (Deployment memory deployment)
    {
        _requireAllCode(input);
        deployment.whitelistExtension = address(
            new BindersTBAWhitelistExtension(
                input.registry, input.tbaImplementation, controlPlane.binderData(), TBA_SALT
            )
        );
        controlPlane.configureItemSystem(
            input.book,
            input.inventory,
            input.equipment,
            input.tomes,
            input.sItems,
            input.router,
            input.metadataBuilder,
            input.statsView,
            vm.envOr("ENTROPY_ADDRESS", address(0)),
            vm.envOr("ENTROPY_PROVIDER", address(0))
        );
        deployment.equipmentListId =
            _configurePolicy(controlPlane, input.equipment, input, deployment.whitelistExtension, initialIssuer);
        deployment.tomeListId =
            _configurePolicy(controlPlane, input.tomes, input, deployment.whitelistExtension, initialIssuer);
        deployment.sItemListId =
            _configurePolicy(controlPlane, input.sItems, input, deployment.whitelistExtension, initialIssuer);
        controlPlane.setItemIssuer(input.equipment, initialIssuer, true);
        controlPlane.setItemIssuer(input.tomes, initialIssuer, true);
        controlPlane.setItemIssuer(input.sItems, initialIssuer, true);

        address fusionMinter = controlPlane.fusionMinter();
        if (fusionMinter != address(0)) IFusionInventorySetter(fusionMinter).setBinderInventory(input.inventory);
        _assertWiring(controlPlane, input);
    }

    function _configurePolicy(
        IItemPolicyConsole controlPlane,
        address collection,
        WireInput memory input,
        address extension,
        address initialIssuer
    ) private returns (uint48 listId) {
        controlPlane.setItemTransferValidator(collection, input.validator);
        controlPlane.configureItemTransferRuleset(
            collection, RULESET_ID_FIXED, input.whitelistRuleset, 0, WHITELIST_BLOCK_ALL_OTC_AND_SMART_WALLETS
        );
        listId = controlPlane.createItemTransferList(collection, "Binders Item Policy");
        controlPlane.applyItemTransferList(collection, listId);
        address[] memory permitted = new address[](3);
        permitted[0] = collection;
        permitted[1] = controlPlane.binderInventory();
        permitted[2] = initialIssuer;
        controlPlane.addItemTransferListAccounts(collection, listId, LIST_TYPE_WHITELIST, permitted);
        address[] memory extensions = new address[](1);
        extensions[0] = extension;
        controlPlane.addItemTransferListAccounts(collection, listId, LIST_TYPE_WHITELIST_EXTENSION, extensions);
    }

    function _assertWiring(IItemPolicyConsole controlPlane, WireInput memory input) private view {
        require(
            controlPlane.book0fItems() == input.book && controlPlane.binderInventory() == input.inventory
                && controlPlane.equipment() == input.equipment && controlPlane.tomeAndGrimoires() == input.tomes
                && controlPlane.sItems() == input.sItems && controlPlane.itemUseRouter() == input.router
                && controlPlane.itemMetadataBuilder() == input.metadataBuilder
                && controlPlane.itemStatsView() == input.statsView,
            "Item wiring mismatch"
        );
        _assertPolicy(input.validator, input.equipment);
        _assertPolicy(input.validator, input.tomes);
        _assertPolicy(input.validator, input.sItems);
    }

    function _assertPolicy(address validator, address collection) private view {
        ICreatorTokenTransferValidatorV5.CollectionSecurityPolicy memory policy =
            ICreatorTokenTransferValidatorV5(validator).getCollectionSecurityPolicy(collection);
        require(
            policy.rulesetId == RULESET_ID_FIXED && policy.listId != 0
                && policy.rulesetOptions == WHITELIST_BLOCK_ALL_OTC_AND_SMART_WALLETS,
            "Item policy mismatch"
        );
    }

    function _loadInput() private returns (WireInput memory input) {
        input.registry = vm.envAddress("ERC6551_REGISTRY");
        input.tbaImplementation = vm.envAddress("TBA_IMPLEMENTATION");
        input.validator = vm.envAddress("CREATOR_TOKEN_VALIDATOR");
        input.whitelistRuleset = vm.envAddress("CREATOR_TOKEN_WHITELIST_RULESET");
        input.book = vm.envAddress("BOOK_OF_ITEMS");
        input.inventory = vm.envAddress("BINDER_INVENTORY");
        input.metadataBuilder = vm.envAddress("ITEM_METADATA_BUILDER");
        input.statsView = vm.envAddress("ITEM_STATS_VIEW");
        input.router = vm.envAddress("ITEM_USE_ROUTER");
        input.equipment = vm.envAddress("EQUIPMENT");
        input.tomes = vm.envAddress("TOME_AND_GRIMOIRES");
        input.sItems = vm.envAddress("SITEMS");
    }

    function _requireAllCode(WireInput memory input) private view {
        require(
            input.book.code.length != 0 && input.inventory.code.length != 0 && input.metadataBuilder.code.length != 0
                && input.statsView.code.length != 0 && input.router.code.length != 0 && input.equipment.code.length != 0
                && input.tomes.code.length != 0 && input.sItems.code.length != 0,
            "Missing code"
        );
    }

    function _requireCodeHash(address target, bytes32 expectedCodeHash) private view {
        require(
            target.code.length != 0 && expectedCodeHash != bytes32(0) && target.codehash == expectedCodeHash,
            "Unverified code"
        );
    }
}
