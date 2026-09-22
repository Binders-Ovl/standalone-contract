// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ERC6551Registry} from "@erc6551/ERC6551Registry.sol";
import {BindersTBA} from "../modular/Items/BindersTBA.sol";

contract BindersTBATest is Test {
    function testCounterfactualAccountKeepsIdentityButRejectsArbitraryExecution() public {
        ERC6551Registry registry = new ERC6551Registry();
        BindersTBA implementation = new BindersTBA();
        bytes32 salt = keccak256("BINDERS_ERC6551_V1");
        address expected = registry.account(address(implementation), salt, block.chainid, address(this), 1);
        address account = registry.createAccount(address(implementation), salt, block.chainid, address(this), 1);
        assertEq(account, expected);
        (uint256 chainId, address token, uint256 tokenId) = BindersTBA(payable(account)).token();
        assertEq(chainId, block.chainid);
        assertEq(token, address(this));
        assertEq(tokenId, 1);

        vm.expectRevert(BindersTBA.ArbitraryExecutionDisabled.selector);
        BindersTBA(payable(account)).execute(address(this), 0, "", 0);
    }
}
