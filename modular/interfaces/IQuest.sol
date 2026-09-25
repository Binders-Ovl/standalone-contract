// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IQuestReward} from "./IGrowthActivity.sol";

interface IQuest is IQuestReward {
    function startQuest(uint256 binderId, uint32 ruleId, uint32 optionalContext) external payable returns (bytes32);
    function requestQuestResolution(bytes32 activityId) external payable;
    function finalizeQuest(bytes32 activityId) external;
    function claimQuestBinder(bytes32 activityId) external;
    function rescueQuest(bytes32 activityId) external;
    function fundRewards(address asset, uint256 amount) external payable;
    function withdrawCredit(address asset) external;
}
