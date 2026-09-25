// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../shelf/Book0fGrowth.sol";

/// @notice Typed balance edits shared by Console and Scale; their resolvers enforce existing roles.
abstract contract GrowthBookConfigurator {
    function _growthBookForConfig() internal view virtual returns (Book0fGrowth);

    function addDrillRule(binderStructs.TrainingRule calldata rule) external returns (uint32) {
        return _growthBookForConfig().addDrillRule(rule);
    }

    function updateDrillRule(uint32 id, binderStructs.TrainingRule calldata rule) external {
        _growthBookForConfig().updateDrillRule(id, rule);
    }

    function deactivateDrillRule(uint32 id) external {
        _growthBookForConfig().deactivateDrillRule(id);
    }

    function addXDrillProfile(binderStructs.TrainingRule calldata rule) external returns (uint32) {
        return _growthBookForConfig().addXDrillProfile(rule);
    }

    function updateXDrillProfile(uint32 id, binderStructs.TrainingRule calldata rule) external {
        _growthBookForConfig().updateXDrillProfile(id, rule);
    }

    function deactivateXDrillProfile(uint32 id) external {
        _growthBookForConfig().deactivateXDrillProfile(id);
    }

    function addErrantryRule(binderStructs.TrainingRule calldata rule) external returns (uint32) {
        return _growthBookForConfig().addErrantryRule(rule);
    }

    function updateErrantryRule(uint32 id, binderStructs.TrainingRule calldata rule) external {
        _growthBookForConfig().updateErrantryRule(id, rule);
    }

    function deactivateErrantryRule(uint32 id) external {
        _growthBookForConfig().deactivateErrantryRule(id);
    }

    function addQuestRule(binderStructs.QuestRule calldata rule) external returns (uint32) {
        return _growthBookForConfig().addQuestRule(rule);
    }

    function updateQuestRule(uint32 id, binderStructs.QuestRule calldata rule) external {
        _growthBookForConfig().updateQuestRule(id, rule);
    }

    function deactivateQuestRule(uint32 id) external {
        _growthBookForConfig().deactivateQuestRule(id);
    }

    function setItemRewardTable(uint32 id, QuestItemReward[] calldata entries) external {
        _growthBookForConfig().setItemRewardTable(id, entries);
    }

    function setNftRewardTable(uint32 id, binderStructs.QuestClassReward[] calldata entries) external {
        _growthBookForConfig().setNftRewardTable(id, entries);
    }
}
