// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IItemMetadataBuilder {
    function tokenURI(string memory itemName, string memory imageURI, uint16 libraryId, uint32 version)
        external
        pure
        returns (string memory);
}
