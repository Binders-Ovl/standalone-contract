// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Final metadata renderer API used by BinderData.tokenURI.
interface IBinderMetadata {
    /// @notice Canonical BinderData collection used by this renderer/lens.
    /// @dev CentralConsole uses this immutable getter to reject a renderer
    /// pointed at a different collection during a cutover.
    function binderData() external view returns (address);
    function binderSkills() external view returns (address);
    function book0fLife() external view returns (address);
    function book0fArts() external view returns (address);

    function tokenURI(uint256 tokenId) external view returns (string memory);
}
