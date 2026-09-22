// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@erc6551/examples/simple/ERC6551Account.sol";
import "@openzeppelin/contracts-4.8/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts-4.8/token/ERC1155/IERC1155Receiver.sol";
import "@openzeppelin/contracts-4.8/utils/introspection/IERC165.sol";

/// @notice ERC-6551 identity and receivers for a Binder; recognised-item movement remains Inventory-controlled.
contract BindersTBA is ERC6551Account, IERC721Receiver, IERC1155Receiver {
    error ArbitraryExecutionDisabled();

    function execute(address, uint256, bytes calldata, uint8) external payable override returns (bytes memory) {
        revert ArbitraryExecutionDisabled();
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure override(ERC6551Account, IERC165) returns (bool) {
        return interfaceId == type(IERC721Receiver).interfaceId || interfaceId == type(IERC1155Receiver).interfaceId
            || interfaceId == 0x6faff5f1;
    }
}
