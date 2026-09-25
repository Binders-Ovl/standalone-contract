// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {binderStructs} from "../supportContract/binderStructs.sol";
import {QuestItemReward} from "../Items/ItemStruct.sol";

interface IBook0fGrowth {
    function getTrainingRule(uint8 kind, uint32 id, uint16 version)
        external
        view
        returns (binderStructs.TrainingRule memory);
    function getQuestRule(uint32 id, uint16 version) external view returns (binderStructs.QuestRule memory);
    function getItemRewardTable(uint32 id, uint16 version) external view returns (QuestItemReward[] memory);
    function getNftRewardTable(uint32 id, uint16 version)
        external
        view
        returns (binderStructs.QuestClassReward[] memory);
    function addDrillRule(binderStructs.TrainingRule calldata rule) external returns (uint32);
    function updateDrillRule(uint32 id, binderStructs.TrainingRule calldata rule) external;
    function deactivateDrillRule(uint32 id) external;
    function addXDrillProfile(binderStructs.TrainingRule calldata rule) external returns (uint32);
    function updateXDrillProfile(uint32 id, binderStructs.TrainingRule calldata rule) external;
    function deactivateXDrillProfile(uint32 id) external;
    function addErrantryRule(binderStructs.TrainingRule calldata rule) external returns (uint32);
    function updateErrantryRule(uint32 id, binderStructs.TrainingRule calldata rule) external;
    function deactivateErrantryRule(uint32 id) external;
    function addQuestRule(binderStructs.QuestRule calldata rule) external returns (uint32);
    function updateQuestRule(uint32 id, binderStructs.QuestRule calldata rule) external;
    function deactivateQuestRule(uint32 id) external;
    function setItemRewardTable(uint32 id, QuestItemReward[] calldata entries) external;
    function setNftRewardTable(uint32 id, binderStructs.QuestClassReward[] calldata entries) external;
}
