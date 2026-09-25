// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./IItemCollection.sol";

interface ISItems is IItemCollection {
    function mintToWallet(address to, uint16 libraryId, uint128 amount, bytes32 provenance) external;
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function protocolTransfer(address from, address to, uint16 sItemId, uint128 amount, bytes calldata data) external;
    function burnForProtocol(address from, uint16 sItemId, uint128 amount) external;
}
