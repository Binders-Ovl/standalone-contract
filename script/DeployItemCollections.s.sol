// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../modular/Items/Equipment.sol";
import "../modular/Items/SItems.sol";
import "../modular/Items/TomeAndGrimoires.sol";

/// @notice Deploys the three ERC-C collections after DeployItemSystem.
/// @dev Run WireItemPolicy next; keeping deployment separate avoids mixing the validator's ERC-C dependency tree with BinderData.
contract DeployItemCollections is Script {
    struct Deployment {
        address equipment;
        address tomes;
        address sItems;
    }

    function run() external returns (Deployment memory deployment) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address validator = vm.envAddress("CREATOR_TOKEN_VALIDATOR");
        _requireCodeHash(validator, vm.envBytes32("CREATOR_TOKEN_VALIDATOR_CODEHASH"));
        address book = vm.envAddress("BOOK_OF_ITEMS");
        address metadataBuilder = vm.envAddress("ITEM_METADATA_BUILDER");
        _requireCode(book);
        _requireCode(metadataBuilder);

        vm.startBroadcast(deployerKey);
        address controlPlane = vm.envAddress("CENTRAL_CONSOLE");
        deployment.equipment = address(new Equipment(controlPlane, validator, book, metadataBuilder));
        deployment.tomes = address(new TomeAndGrimoires(controlPlane, validator, book, metadataBuilder));
        deployment.sItems = address(new SItems(controlPlane, validator, book, metadataBuilder));
        vm.stopBroadcast();
    }

    function _requireCode(address target) private view {
        require(target.code.length != 0, "Missing code");
    }

    function _requireCodeHash(address target, bytes32 expectedCodeHash) private view {
        require(
            target.code.length != 0 && expectedCodeHash != bytes32(0) && target.codehash == expectedCodeHash,
            "Unverified code"
        );
    }
}
