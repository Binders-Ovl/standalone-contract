// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../modular/Items/BinderInventory.sol";
import "../modular/Items/ItemMetadataBuilder.sol";
import "../modular/Items/ItemStatsView.sol";
import "../modular/Items/ItemUseRouter.sol";
import "../modular/shelf/Book0fItems.sol";

interface IItemFoundationConsole {
    function binderData() external view returns (address);
    function book0fArts() external view returns (address);
}

/// @notice Deploys the Book, Inventory, Router, and view foundation after DeployERC6551Infrastructure.
/// @dev Run DeployItemCollections afterwards to deploy ERC-C collections and wire the complete item graph.
contract DeployItemSystem is Script {
    bytes32 internal constant TBA_SALT = keccak256("BINDERS_ERC6551_V1");

    struct Deployment {
        address registry;
        address tbaImplementation;
        bytes32 tbaSalt;
        address book;
        address inventory;
        address router;
        address metadataBuilder;
        address statsView;
    }

    function run() external returns (Deployment memory deployment) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address consoleAddress = vm.envAddress("CENTRAL_CONSOLE");
        address registry = vm.envAddress("ERC6551_REGISTRY");
        address tbaImplementation = vm.envAddress("TBA_IMPLEMENTATION");
        _requireCodeHash(registry, vm.envBytes32("ERC6551_REGISTRY_CODEHASH"));
        _requireCodeHash(tbaImplementation, vm.envBytes32("TBA_IMPLEMENTATION_CODEHASH"));

        vm.startBroadcast(deployerKey);
        deployment = _deploy(consoleAddress, vm.envAddress("SCALE_OF_BALANCE"), registry, tbaImplementation);
        vm.stopBroadcast();
    }

    function _deploy(address consoleAddress, address scaleAddress, address registry, address tbaImplementation)
        private
        returns (Deployment memory deployment)
    {
        IItemFoundationConsole controlPlane = IItemFoundationConsole(consoleAddress);
        deployment.registry = registry;
        deployment.tbaImplementation = tbaImplementation;
        deployment.tbaSalt = TBA_SALT;
        deployment.book = address(new Book0fItems(consoleAddress, scaleAddress, controlPlane.book0fArts()));
        deployment.metadataBuilder = address(new ItemMetadataBuilder());
        deployment.statsView = address(new ItemStatsView(controlPlane.binderData()));
        deployment.inventory = address(
            new BinderInventory(
                consoleAddress,
                controlPlane.binderData(),
                deployment.book,
                registry,
                tbaImplementation,
                deployment.statsView
            )
        );
        deployment.router = address(new ItemUseRouter(controlPlane.binderData(), deployment.book, deployment.inventory));
    }

    function _requireCodeHash(address target, bytes32 expectedCodeHash) private view {
        require(
            target.code.length != 0 && expectedCodeHash != bytes32(0) && target.codehash == expectedCodeHash,
            "Unverified code"
        );
    }
}
