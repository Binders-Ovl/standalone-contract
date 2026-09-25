// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IItemStatsView} from "./IItemStatsView.sol";

interface IBinderGrowth is IItemStatsView {
    function getGrowthDelta(uint256 binderId) external view returns (int32[8] memory);
    function getSwg(uint256 binderId) external view returns (uint32[8] memory);
    function getTrueStats(uint256 binderId) external view returns (int64[8] memory);
    function trainingUses(uint256 binderId) external view returns (uint8);
    function completedErrantryCount(uint256 binderId) external view returns (uint256);
    function consumeTrainingUse(bytes32 activityId) external;
    function settleTraining(bytes32 activityId) external;
    function settleQuest(bytes32 activityId) external;
}
