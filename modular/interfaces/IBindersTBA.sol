// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal ERC-6551 identity surface used by Binders integrations.
interface IBindersTBA {
    function token() external view returns (uint256 chainId, address tokenContract, uint256 tokenId);
}
