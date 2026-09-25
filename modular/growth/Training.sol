// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./ActivityEscrow.sol";

/// @notice Hard escrow for Drill, xDrill and Errantry; it never owns Quest custody.
contract Training is ActivityEscrow {
    constructor(Dependencies memory deps) ActivityEscrow(deps, BinderIds.ACTIVITY_TRAINING) {}

    /// @dev For Drill, profileId selects stat 0..7 under Drill rule 1.
    /// Use startDrill to select another versioned Drill rule.
    function startTraining(uint256 binderId, uint8 kind, uint32 profileId)
        external
        payable
        nonReentrant
        returns (bytes32)
    {
        if (kind == 1) {
            if (profileId >= 8) revert InvalidActivity();
            return _start(binderId, kind, 1, uint8(profileId));
        }
        return _start(binderId, kind, profileId, 0);
    }

    function startDrill(uint256 binderId, uint32 ruleId, uint8 stat) external payable nonReentrant returns (bytes32) {
        if (stat >= 8) revert InvalidActivity();
        return _start(binderId, 1, ruleId, stat);
    }

    function _start(uint256 binderId, uint8 kind, uint32 ruleId, uint8 stat) private returns (bytes32 id) {
        if (kind == 0 || kind > 3) revert InvalidActivity();
        if (kind <= 2 && growth.trainingUses(binderId) >= 3) revert InvalidActivity();
        binderStructs.TrainingRule memory rule = book.getTrainingRule(kind, ruleId, 0);
        id = _begin(binderId, kind, ruleId, rule.terms);
        _activities[id].selectedStat = stat;
        if (kind == 3) _snapshotArts(id, rule.artPoolId, rule.patternPoolId);
        _escrowAndPay(id);
        if (kind <= 2) growth.consumeTrainingUse(id);
    }

    function requestTrainingResolution(bytes32 id) external payable nonReentrant {
        _request(id);
    }

    function finalizeTraining(bytes32 id) external nonReentrant {
        Activity storage record = _markSettled(id);
        binderStructs.TrainingRule memory rule = book.getTrainingRule(record.kind, record.ruleId, record.ruleVersion);
        int32[8] memory changes;
        bool success;
        if (record.kind == 1) {
            (success, changes) =
                GrowthRollLib.drill(record.seed, rule.successBps, record.selectedStat, rule.minGain, rule.maxGain);
        } else if (record.kind == 2) {
            (success, changes) = GrowthRollLib.xDrill(record.seed, rule.successBps, rule.profile);
        } else {
            (success, changes) = GrowthRollLib.errantry(record.seed, id, rule.successBps, rule.profile);
        }
        record.success = success;
        _results[id] = changes;
        growth.settleTraining(id);
        if (record.kind == 3 && success) _settleArts(id, rule.artBps, rule.patternBps);
        emit ActivitySettled(id, success, false);
    }

    function claimTrainedBinder(bytes32 id) external nonReentrant {
        _claim(id);
    }

    function rescueTraining(bytes32 id) external nonReentrant {
        _rescue(id);
    }
}
