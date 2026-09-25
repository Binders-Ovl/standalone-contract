// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./IItemCollection.sol";

interface IEquipment is IItemCollection {
    function mintToWallet(address to, uint16 libraryId, bytes32 provenance) external returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function eqIdOf(uint256 tokenId) external view returns (uint16);
    function protocolTransfer(address from, address to, uint256 tokenId) external;
    function burnForProtocol(uint256 tokenId) external;
}
