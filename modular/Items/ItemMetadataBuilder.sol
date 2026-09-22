// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-4.8/utils/Base64.sol";
import "@openzeppelin/contracts-4.8/utils/Strings.sol";
import "../interfaces/IItemMetadataBuilder.sol";
import "../libraries/JsonStringLib.sol";

/// @notice One compact renderer shared by all item collections.
contract ItemMetadataBuilder is IItemMetadataBuilder {
    using Strings for uint256;

    function tokenURI(string memory itemName, string memory imageURI, uint16 libraryId, uint32 version)
        external
        pure
        override
        returns (string memory)
    {
        return string.concat(
            "data:application/json;base64,",
            Base64.encode(
                bytes(
                    string.concat(
                        '{"name":"',
                        JsonStringLib.escape(itemName),
                        '","image":"',
                        JsonStringLib.escape(imageURI),
                        '","attributes":[{"trait_type":"Item ID","value":',
                        uint256(libraryId).toString(),
                        '},{"trait_type":"Config Version","value":',
                        uint256(version).toString(),
                        "}]}"
                    )
                )
            )
        );
    }
}
