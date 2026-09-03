// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Narrow configuration/read surface used by CentralConsole.
interface IScaleOfBalance {
    function binderData() external view returns (address);
    function book0fLife() external view returns (address);
    function setBook0fLife(address book) external;
}
