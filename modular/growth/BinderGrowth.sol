// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../interfaces/IBinderData.sol";
import "../interfaces/IBinderInventory.sol";
import "../interfaces/IItemStatsView.sol";
import "../interfaces/IGrowthActivity.sol";
import "../supportContract/binderIds.sol";
import "./GrowthRollLib.sol";

/// @notice Permanent deltas only. Controllers prove their own settled, still-bound activity.
contract BinderGrowth is IItemStatsView {
    address public immutable centralConsole;
    IBinderData public immutable binderData;
    IBinderInventory public immutable inventory;
    mapping(uint256 => int32[8]) private _growth;
    mapping(uint256 => uint8) public trainingUses;
    mapping(uint256 => uint256) public completedErrantryCount;
    mapping(bytes32 => uint8) private _applied;

    error InvalidGrowthProof();
    error TrainingUsesExhausted();

    event TrainingUseConsumed(uint256 indexed binderId, bytes32 indexed activityId, uint8 used);
    event GrowthSettled(uint256 indexed binderId, bytes32 indexed activityId, int32[8] growthDelta, uint32[8] swg);

    constructor(address console, address data, address inventoryAddress) {
        if (console.code.length == 0 || data.code.length == 0 || inventoryAddress.code.length == 0) {
            revert InvalidGrowthProof();
        }
        centralConsole = console;
        binderData = IBinderData(data);
        inventory = IBinderInventory(inventoryAddress);
    }

    function getGrowthDelta(uint256 binderId) external view returns (int32[8] memory) {
        binderData.ownerOf(binderId);
        return _growth[binderId];
    }

    function getSwg(uint256 binderId) public view returns (uint32[8] memory stats) {
        uint8[8] memory base = binderData.getNFTDetails(binderId).staticStats.stats;
        for (uint256 i; i < 8; ++i) {
            int256 value = int256(uint256(base[i])) + _growth[binderId][i];
            stats[i] = value < 1 ? 1 : uint32(uint256(value));
        }
    }

    function statsWithGrowth(uint256 binderId) external view returns (uint32[8] memory) {
        return getSwg(binderId);
    }

    function getTrueStats(uint256 binderId) external view returns (int64[8] memory stats) {
        uint32[8] memory swg = getSwg(binderId);
        int32[8] memory equipment = inventory.equipmentModifiers(binderId);
        for (uint256 i; i < 8; ++i) {
            stats[i] = int64(uint64(swg[i])) + equipment[i];
        }
    }

    function consumeTrainingUse(bytes32 activityId) external {
        (uint256 binderId, uint8 kind) = _proof(activityId, BinderIds.ACTIVITY_TRAINING, 1);
        if (kind > 2 || _applied[activityId] != 0) revert InvalidGrowthProof();
        if (trainingUses[binderId] >= 3) revert TrainingUsesExhausted();
        _applied[activityId] = 1;
        emit TrainingUseConsumed(binderId, activityId, ++trainingUses[binderId]);
    }

    function settleTraining(bytes32 activityId) external {
        _settle(activityId, BinderIds.ACTIVITY_TRAINING);
    }

    function settleQuest(bytes32 activityId) external {
        _settle(activityId, BinderIds.ACTIVITY_QUEST);
    }

    function _settle(bytes32 activityId, uint8 activityKind) private {
        (uint256 binderId, uint8 kind) = _proof(activityId, activityKind, 4);
        uint8 flags = _applied[activityId];
        if ((flags & 2) != 0 || (kind <= 2 && (flags & 1) == 0)) revert InvalidGrowthProof();
        _applied[activityId] = flags | 2;
        if (kind == 3) ++completedErrantryCount[binderId];
        int32[8] memory changes = IGrowthActivity(msg.sender).growthResult(activityId);
        uint8[8] memory base = binderData.getNFTDetails(binderId).staticStats.stats;
        uint32[8] memory swg;
        int32[8] memory applied;
        for (uint256 i; i < 8; ++i) {
            int32 previous = _growth[binderId][i];
            (_growth[binderId][i], swg[i]) = GrowthRollLib.applyDelta(base[i], previous, changes[i]);
            applied[i] = _growth[binderId][i];
        }
        inventory.reconcileEquipment(binderId);
        emit GrowthSettled(binderId, activityId, applied, swg);
    }

    function _proof(bytes32 activityId, uint8 activityKind, uint8 phase)
        private
        view
        returns (uint256 binderId, uint8 kind)
    {
        address beneficiary;
        uint8 actualPhase;
        (binderId, beneficiary, kind, actualPhase) = IGrowthActivity(msg.sender).activityProof(activityId);
        if (
            actualPhase != phase || beneficiary == address(0) || kind == 0 || kind > 4
                || (activityKind == BinderIds.ACTIVITY_QUEST ? kind != 4 : kind == 4)
                || binderData.activeGrowthController(binderId) != msg.sender
                || binderData.activeGrowthActivity(binderId) != activityId || binderData.ownerOf(binderId) != msg.sender
                || binderData.getUnitState(binderId).activity.activityId != activityKind
        ) {
            revert InvalidGrowthProof();
        }
    }
}
