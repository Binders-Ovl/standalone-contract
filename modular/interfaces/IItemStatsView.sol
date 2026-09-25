// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./IBinderData.sol";

interface IItemStatsView {
    function binderData() external view returns (IBinderData);
    function statsWithGrowth(uint256 binderId) external view returns (uint32[8] memory);
}
