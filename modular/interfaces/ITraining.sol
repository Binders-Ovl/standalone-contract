// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IGrowthActivity} from "./IGrowthActivity.sol";

interface ITraining is IGrowthActivity {
    function startTraining(uint256 binderId, uint8 kind, uint32 profileId) external payable returns (bytes32);
    function startDrill(uint256 binderId, uint32 ruleId, uint8 selectedStat) external payable returns (bytes32);
    function requestTrainingResolution(bytes32 activityId) external payable;
    function finalizeTraining(bytes32 activityId) external;
    function claimTrainedBinder(bytes32 activityId) external;
    function rescueTraining(bytes32 activityId) external;
    function withdrawCredit(address asset) external;
}
