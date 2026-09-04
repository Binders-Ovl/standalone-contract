// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "../modular/BinderData.sol";
import "../modular/Book0fLife.sol";
import "../modular/Battle/BattleFactory.sol";
import "../modular/Battle/BattleProxy.sol";
import "../modular/FusionMinter.sol";
import "../modular/supportContract/CentralConsole.sol";

/// @notice Enforces Monad's deployed-code cap while retaining EIP-170 as an ERC721C planning reference.
contract RuntimeSizeTest is Test {
    uint256 internal constant MONAD_MAX_RUNTIME_BYTES = 128 * 1024;
    uint256 internal constant EIP170_REFERENCE_RUNTIME_BYTES = 24_576;
    /// @dev Deliberate early warning line: this leaves 476 bytes before the
    /// hard cap and is intentionally much stricter than deployability.
    uint256 internal constant BINDER_DATA_WARNING_RUNTIME_BYTES = 24_100;

    function testNonImmutableCoreRuntimeCodeRemainsDeployable() public pure {
        uint256 binderDataBytes = type(BinderData).runtimeCode.length;
        console2.log("BinderData runtime bytes", binderDataBytes);
        console2.log("BinderData EIP-170 reference headroom", EIP170_REFERENCE_RUNTIME_BYTES - binderDataBytes);
        if (binderDataBytes >= BINDER_DATA_WARNING_RUNTIME_BYTES) {
            console2.log("WARNING: BinderData crossed the ERC721C planning threshold");
        }
        assertLt(type(Book0fLife).runtimeCode.length, MONAD_MAX_RUNTIME_BYTES);
        assertLt(binderDataBytes, MONAD_MAX_RUNTIME_BYTES);
        assertLt(type(BattleProxy).runtimeCode.length, MONAD_MAX_RUNTIME_BYTES);
        assertLt(type(FusionMinter).runtimeCode.length, MONAD_MAX_RUNTIME_BYTES);
    }

    function testImmutableCoreRuntimeCodeRemainsDeployable() public {
        BinderData binderData = new BinderData(address(this), "");
        CentralConsole centralConsole = new CentralConsole(address(this), address(binderData));
        BattleProxy implementation = new BattleProxy();
        BattleFactory factory = new BattleFactory(address(this), address(centralConsole), address(implementation));

        assertLt(address(centralConsole).code.length, MONAD_MAX_RUNTIME_BYTES);
        assertLt(address(factory).code.length, MONAD_MAX_RUNTIME_BYTES);
    }
}
