// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Read surface for wiring diagnostics.
interface IBinderLogic {
    function binderData() external view returns (address);
    function book0fLife() external view returns (address);
    function allegianceRegistry() external view returns (address);
    function acceptingRequests() external view returns (bool);
    function pendingMintCount() external view returns (uint256);
    function setBook0fLife(address book) external;
    function setAllegianceRegistry(address registry) external;
    function setAcceptingRequests(bool accepting) external;
    function CONFIG_ROLE() external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
}
