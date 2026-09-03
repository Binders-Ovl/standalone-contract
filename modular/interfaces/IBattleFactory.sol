// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Provenance check consumed by future BinderData battle settlement paths.
interface IBattleFactory {
    function centralConsole() external view returns (address);
    function battleImplementation() external view returns (address);
    function isBattleProxy(address proxy) external view returns (bool);

    /// @notice Stable Battle activity gateway used by official clones at close.
    function endBattle(uint256[] calldata tokenIds) external;
}
