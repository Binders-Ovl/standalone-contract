// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../supportContract/binderStructs.sol";
import "../Items/ItemStruct.sol";
import "../growth/GrowthRollLib.sol";

/// @notice Immutable historical rules; only the current Console and Scale can configure new versions.
contract Book0fGrowth {
    bytes32 public constant GROWTH_CONFIG_ROLE = keccak256("GROWTH_CONFIG_ROLE");
    address public centralConsole;
    address public scaleOfBalance;
    mapping(uint8 => uint32) private _nextId;
    mapping(uint8 => mapping(uint32 => uint16)) public currentVersion;
    mapping(uint8 => mapping(uint32 => mapping(uint16 => binderStructs.TrainingRule))) private _training;
    mapping(uint32 => mapping(uint16 => binderStructs.QuestRule)) private _quest;
    mapping(uint32 => uint16) public itemTableVersion;
    mapping(uint32 => uint16) public nftTableVersion;
    mapping(uint32 => mapping(uint16 => QuestItemReward[])) private _items;
    mapping(uint32 => mapping(uint16 => binderStructs.QuestClassReward[])) private _classes;

    error UnauthorizedGrowthConfig();
    error InvalidGrowthRule();

    event GrowthRuleConfigured(uint8 indexed kind, uint32 indexed ruleId, uint16 indexed version, bool enabled);
    event RewardTableConfigured(uint8 indexed family, uint32 indexed tableId, uint16 version);

    constructor(address console, address scale) {
        if (console.code.length == 0 || scale.code.length == 0) revert InvalidGrowthRule();
        centralConsole = console;
        scaleOfBalance = scale;
    }

    modifier onlyConfig() {
        if (msg.sender != centralConsole && msg.sender != scaleOfBalance) revert UnauthorizedGrowthConfig();
        _;
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return role == GROWTH_CONFIG_ROLE && (account == centralConsole || account == scaleOfBalance);
    }

    function setAuthorities(address console, address scale) external {
        if (msg.sender != centralConsole) revert UnauthorizedGrowthConfig();
        if (console.code.length == 0 || scale.code.length == 0) revert InvalidGrowthRule();
        centralConsole = console;
        scaleOfBalance = scale;
    }

    function addDrillRule(binderStructs.TrainingRule calldata rule) external onlyConfig returns (uint32 id) {
        id = ++_nextId[1];
        _storeTraining(1, id, rule);
    }

    function updateDrillRule(uint32 id, binderStructs.TrainingRule calldata rule) external onlyConfig {
        _requireRule(1, id);
        _storeTraining(1, id, rule);
    }

    function deactivateDrillRule(uint32 id) external onlyConfig {
        _requireRule(1, id);
        binderStructs.TrainingRule memory rule = _training[1][id][currentVersion[1][id]];
        rule.terms.enabled = false;
        _storeTraining(1, id, rule);
    }

    function addXDrillProfile(binderStructs.TrainingRule calldata rule) external onlyConfig returns (uint32 id) {
        id = ++_nextId[2];
        _storeTraining(2, id, rule);
    }

    function updateXDrillProfile(uint32 id, binderStructs.TrainingRule calldata rule) external onlyConfig {
        _requireRule(2, id);
        _storeTraining(2, id, rule);
    }

    function deactivateXDrillProfile(uint32 id) external onlyConfig {
        _requireRule(2, id);
        binderStructs.TrainingRule memory rule = _training[2][id][currentVersion[2][id]];
        rule.terms.enabled = false;
        _storeTraining(2, id, rule);
    }

    function addErrantryRule(binderStructs.TrainingRule calldata rule) external onlyConfig returns (uint32 id) {
        id = ++_nextId[3];
        _storeTraining(3, id, rule);
    }

    function updateErrantryRule(uint32 id, binderStructs.TrainingRule calldata rule) external onlyConfig {
        _requireRule(3, id);
        _storeTraining(3, id, rule);
    }

    function deactivateErrantryRule(uint32 id) external onlyConfig {
        _requireRule(3, id);
        binderStructs.TrainingRule memory rule = _training[3][id][currentVersion[3][id]];
        rule.terms.enabled = false;
        _storeTraining(3, id, rule);
    }

    function addQuestRule(binderStructs.QuestRule calldata rule) external onlyConfig returns (uint32 id) {
        id = ++_nextId[4];
        _storeQuest(id, rule);
    }

    function updateQuestRule(uint32 id, binderStructs.QuestRule calldata rule) external onlyConfig {
        _requireRule(4, id);
        _storeQuest(id, rule);
    }

    function deactivateQuestRule(uint32 id) external onlyConfig {
        _requireRule(4, id);
        binderStructs.QuestRule memory rule = _quest[id][currentVersion[4][id]];
        rule.terms.enabled = false;
        _storeQuest(id, rule);
    }

    function getTrainingRule(uint8 kind, uint32 id, uint16 version)
        external
        view
        returns (binderStructs.TrainingRule memory rule)
    {
        if (kind < 1 || kind > 3) revert InvalidGrowthRule();
        if (version == 0) version = currentVersion[kind][id];
        rule = _training[kind][id][version];
        if (rule.terms.version == 0) revert InvalidGrowthRule();
    }

    function getQuestRule(uint32 id, uint16 version) external view returns (binderStructs.QuestRule memory rule) {
        if (version == 0) version = currentVersion[4][id];
        rule = _quest[id][version];
        if (rule.terms.version == 0) revert InvalidGrowthRule();
    }

    function setItemRewardTable(uint32 id, QuestItemReward[] calldata entries) external onlyConfig {
        if (id == 0 || entries.length == 0 || entries.length > 8) revert InvalidGrowthRule();
        uint16 version = ++itemTableVersion[id];
        for (uint256 i; i < entries.length; ++i) {
            QuestItemReward calldata entry = entries[i];
            if (
                entry.libraryId == 0 || entry.weight == 0 || entry.minAmount == 0 || entry.minAmount > entry.maxAmount
                    || (entry.family != ItemFamily.SITEM && (entry.minAmount != 1 || entry.maxAmount != 1))
            ) {
                revert InvalidGrowthRule();
            }
            _items[id][version].push(entry);
        }
        emit RewardTableConfigured(0, id, version);
    }

    function setNftRewardTable(uint32 id, binderStructs.QuestClassReward[] calldata entries) external onlyConfig {
        if (id == 0 || entries.length == 0 || entries.length > 8) revert InvalidGrowthRule();
        uint16 version = ++nftTableVersion[id];
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].classId == 0 || entries[i].weight == 0) revert InvalidGrowthRule();
            _classes[id][version].push(entries[i]);
        }
        emit RewardTableConfigured(1, id, version);
    }

    function getItemRewardTable(uint32 id, uint16 version) external view returns (QuestItemReward[] memory) {
        if (version == 0) version = itemTableVersion[id];
        if (version == 0 || version > itemTableVersion[id]) revert InvalidGrowthRule();
        return _items[id][version];
    }

    function getNftRewardTable(uint32 id, uint16 version)
        external
        view
        returns (binderStructs.QuestClassReward[] memory)
    {
        if (version == 0) version = nftTableVersion[id];
        if (version == 0 || version > nftTableVersion[id]) revert InvalidGrowthRule();
        return _classes[id][version];
    }

    function _storeTraining(uint8 kind, uint32 id, binderStructs.TrainingRule memory rule) private {
        _terms(rule.terms);
        _bps(rule.successBps);
        _bps(rule.artBps);
        _bps(rule.patternBps);
        if ((rule.artBps != 0 && rule.artPoolId == 0) || (rule.patternBps != 0 && rule.patternPoolId == 0)) {
            revert InvalidGrowthRule();
        }
        if (kind != 3 && (rule.artBps != 0 || rule.patternBps != 0)) revert InvalidGrowthRule();
        if (kind == 1) {
            if (rule.minGain == 0 || rule.minGain > rule.maxGain || rule.maxGain > uint32(type(int32).max)) {
                revert InvalidGrowthRule();
            }
        } else {
            GrowthRollLib.validateProfile(rule.profile);
            if (
                rule.profile.minDeltas[0] <= 0 || rule.profile.maxDeltas[2] >= 0
                    || (kind == 2 ? rule.profile.minDeltas[1] <= 0 : rule.profile.maxDeltas[1] >= 0)
            ) {
                revert InvalidGrowthRule();
            }
        }
        uint16 version = ++currentVersion[kind][id];
        rule.terms.version = version;
        _training[kind][id][version] = rule;
        emit GrowthRuleConfigured(kind, id, version, rule.terms.enabled);
    }

    function _storeQuest(uint32 id, binderStructs.QuestRule memory rule) private {
        _terms(rule.terms);
        _bps(rule.deathBps);
        _bps(rule.successBps);
        _bps(rule.currencyBps);
        _bps(rule.itemBps);
        _bps(rule.statBps);
        _bps(rule.nftBps);
        _bps(rule.injuryBps);
        _bps(rule.artBps);
        _bps(rule.patternBps);
        if (
            rule.minCurrency > rule.maxCurrency || (rule.currencyBps != 0 && rule.maxCurrency == 0)
                || (rule.itemBps != 0 && itemTableVersion[rule.itemTableId] == 0)
                || (rule.nftBps != 0 && nftTableVersion[rule.nftTableId] == 0) || (rule.artBps != 0 && rule.artPoolId == 0)
                || (rule.patternBps != 0 && rule.patternPoolId == 0) || (rule.injuryIsPercent && rule.injuryAmount > 10_000)
        ) revert InvalidGrowthRule();
        // A disabled stat category needs no meaningless weight table.
        if (rule.statBps != 0) GrowthRollLib.validateProfile(rule.profile);
        uint16 version = ++currentVersion[4][id];
        rule.terms.version = version;
        _quest[id][version] = rule;
        emit GrowthRuleConfigured(4, id, version, rule.terms.enabled);
    }

    function _terms(binderStructs.GrowthTerms memory terms) private pure {
        if (terms.duration == 0 || terms.entropyRescueDelay == 0) revert InvalidGrowthRule();
    }

    function _bps(uint16 value) private pure {
        if (value > 10_000) revert InvalidGrowthRule();
    }

    function _requireRule(uint8 kind, uint32 id) private view {
        if (currentVersion[kind][id] == 0) revert InvalidGrowthRule();
    }
}
