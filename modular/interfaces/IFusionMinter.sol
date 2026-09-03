// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Narrow configuration/read surface used by CentralConsole.
interface IFusionMinter {
    function binderData() external view returns (address);
    function book0fLife() external view returns (address);
    function pendingFusionCount() external view returns (uint256);
}
