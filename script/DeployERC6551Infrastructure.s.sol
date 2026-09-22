// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "@erc6551/ERC6551Registry.sol";
import "../modular/Items/BindersTBA.sol";

/// @notice Deploys the pinned reference registry and the Binders-restricted account implementation.
/// @dev The versioned salt is fixed in BinderInventory so every deployment record can reproduce an account address.
contract DeployERC6551Infrastructure is Script {
    bytes32 internal constant TBA_SALT = keccak256("BINDERS_ERC6551_V1");

    struct Deployment {
        address registry;
        address implementation;
        bytes32 salt;
        uint256 chainId;
    }

    function run() external returns (Deployment memory deployment) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        deployment.registry = address(new ERC6551Registry());
        deployment.implementation = address(new BindersTBA());
        deployment.salt = TBA_SALT;
        deployment.chainId = block.chainid;
        vm.stopBroadcast();
    }
}
