// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./ActivityEscrow.sol";
import "../interfaces/IBook0fLife.sol";
import "../interfaces/IBook0fItems.sol";
import "../interfaces/IEquipment.sol";
import "../interfaces/ITomeAndGrimoires.sol";
import "../interfaces/ISItems.sol";
import "../libraries/StatAllocationLib.sol";

/// @notice Independent Quest escrow: death first, then independent rewards and surviving side events.
contract Quest is ActivityEscrow {
    struct ClassSnapshot {
        uint256 classId;
        uint16 weight;
        uint16 version;
        uint8 rarityId;
        string name;
        string rarityName;
        binderStructs.ClassConfig config;
    }

    struct SelectedItem {
        address collection;
        uint16 libraryId;
        uint128 amount;
    }

    IBook0fLife public immutable life;
    IBook0fItems public immutable items;
    IEquipment public immutable equipment;
    ITomeAndGrimoires public immutable tomes;
    ISItems public immutable sItems;
    mapping(bytes32 => QuestItemReward[]) private _itemCandidates;
    mapping(bytes32 => ClassSnapshot[]) private _classCandidates;
    mapping(bytes32 => SelectedItem) private _selectedItem;
    mapping(bytes32 => uint16) private _startHP;
    mapping(bytes32 => uint32) public contextTable;
    mapping(bytes32 => uint256) public nftReward;
    mapping(address => uint256) public rewardPool;
    mapping(bytes32 => uint128) private _reservedCurrency;

    event RewardsFunded(address indexed asset, address indexed funder, uint256 amount);
    event QuestCurrencyCredited(bytes32 indexed activityId, address indexed beneficiary, uint256 amount);

    constructor(Dependencies memory deps) ActivityEscrow(deps, BinderIds.ACTIVITY_QUEST) {
        life = IBook0fLife(centralConsole.book0fLife());
        items = IBook0fItems(centralConsole.book0fItems());
        equipment = IEquipment(centralConsole.equipment());
        tomes = ITomeAndGrimoires(centralConsole.tomeAndGrimoires());
        sItems = ISItems(centralConsole.sItems());
        if (
            address(life).code.length == 0 || address(items).code.length == 0 || address(equipment).code.length == 0
                || address(tomes).code.length == 0 || address(sItems).code.length == 0
        ) revert InvalidActivity();
    }

    /// @notice Prefunding keeps settlement independent of a mutable treasury balance.
    function fundRewards(address asset, uint256 amount) external payable nonReentrant {
        if (amount == 0) revert InvalidPayment();
        _receivePayment(asset, amount);
        rewardPool[asset] += amount;
        emit RewardsFunded(asset, msg.sender, amount);
    }

    function startQuest(uint256 binderId, uint32 ruleId, uint32 optionalContext)
        external
        payable
        nonReentrant
        returns (bytes32 id)
    {
        binderStructs.QuestRule memory rule = book.getQuestRule(ruleId, 0);
        if (optionalContext != 0 && optionalContext != rule.contextTableId) revert InvalidActivity();
        id = _begin(binderId, 4, ruleId, rule.terms);
        contextTable[id] = rule.contextTableId;
        _startHP[id] = binderData.getNFTDetails(binderId).dynamicStats.currentHP;
        _snapshotArts(id, rule.artPoolId, rule.patternPoolId);
        if (rule.itemBps != 0) _snapshotItems(id, rule.itemTableId);
        if (rule.nftBps != 0) _snapshotClasses(id, rule.nftTableId);
        if (rule.currencyBps != 0) {
            address asset = _activities[id].goldAsset;
            if (rewardPool[asset] < rule.maxCurrency) revert InvalidPayment();
            rewardPool[asset] -= rule.maxCurrency;
            _reservedCurrency[id] = rule.maxCurrency;
        }
        _escrowAndPay(id);
    }

    function requestQuestResolution(bytes32 id) external payable nonReentrant {
        _request(id);
    }

    function finalizeQuest(bytes32 id) external nonReentrant {
        Activity storage record = _markSettled(id);
        binderStructs.QuestRule memory rule = book.getQuestRule(record.ruleId, record.ruleVersion);
        if (_chance(id, "QUEST_DEATH", rule.deathBps)) {
            record.dead = true;
            --pendingActivityCount;
            _settleCurrency(id, 0);
            binderData.settleQuestVitals(record.binderId, id, true, 0);
            emit ActivitySettled(id, false, true);
            return;
        }
        record.success = _chance(id, "QUEST_SUCCESS", rule.successBps);
        uint256 currency;
        if (record.success) {
            if (_chance(id, "QUEST_CURRENCY", rule.currencyBps)) {
                currency = uint256(rule.minCurrency)
                    + GrowthRollLib.expand(record.seed, id, "QUEST_CURRENCY_AMOUNT", 0)
                        % (uint256(rule.maxCurrency) - rule.minCurrency + 1);
            }
            if (_chance(id, "QUEST_STAT_REWARD", rule.statBps)) {
                _results[id] = GrowthRollLib.questStats(record.seed, id, rule.profile);
            }
        }
        _settleCurrency(id, currency);
        growth.settleQuest(id);
        uint16 damage;
        if (_chance(id, "QUEST_INJURY", rule.injuryBps)) {
            damage =
                rule.injuryIsPercent ? uint16(uint256(_startHP[id]) * rule.injuryAmount / 10_000) : rule.injuryAmount;
        }
        binderData.settleQuestVitals(record.binderId, id, false, damage);
        _settleArts(id, rule.artBps, rule.patternBps);
        if (record.success) {
            if (_chance(id, "QUEST_ITEM", rule.itemBps)) _issueItem(id);
            if (_chance(id, "QUEST_NFT", rule.nftBps)) _issueBinder(id);
        }
        emit ActivitySettled(id, record.success, false);
    }

    function claimQuestBinder(bytes32 id) external nonReentrant {
        _claim(id);
    }

    function rescueQuest(bytes32 id) external nonReentrant {
        _rescue(id);
    }

    function itemReward(bytes32 id) external view returns (address, address, uint16, uint128) {
        SelectedItem storage item = _selectedItem[id];
        return (item.collection, _activities[id].beneficiary, item.libraryId, item.amount);
    }

    function _chance(bytes32 id, bytes32 domain, uint16 bps) private view returns (bool) {
        return GrowthRollLib.chance(GrowthRollLib.expand(_activities[id].seed, id, domain, 0), bps);
    }

    function _settleCurrency(bytes32 id, uint256 amount) private {
        Activity storage record = _activities[id];
        uint256 reserve = _reservedCurrency[id];
        if (amount > reserve) revert InvalidPayment();
        delete _reservedCurrency[id];
        rewardPool[record.goldAsset] += reserve - amount;
        if (amount != 0) {
            credits[record.goldAsset][record.beneficiary] += amount;
            emit QuestCurrencyCredited(id, record.beneficiary, amount);
        }
    }

    function _onRescue(bytes32 id) internal override {
        _settleCurrency(id, 0);
    }

    function _snapshotItems(bytes32 id, uint32 tableId) private {
        QuestItemReward[] memory candidates = book.getItemRewardTable(tableId, 0);
        for (uint256 i; i < candidates.length; ++i) {
            QuestItemReward memory item = candidates[i];
            bool enabled = item.family == ItemFamily.EQUIPMENT
                ? items.isEqEnabled(item.libraryId)
                : item.family == ItemFamily.TOME_OR_GRIMOIRE
                    ? items.isTomeEnabled(item.libraryId)
                    : items.isSItemEnabled(item.libraryId);
            if (enabled) _itemCandidates[id].push(item);
        }
    }

    function _snapshotClasses(bytes32 id, uint32 tableId) private {
        binderStructs.QuestClassReward[] memory candidates = book.getNftRewardTable(tableId, 0);
        for (uint256 i; i < candidates.length; ++i) {
            uint256 classId = candidates[i].classId;
            if (!life.classExists(classId) || !life.hasClassAcquisition(classId, uint32(1) << 2)) continue;
            ClassSnapshot memory entry;
            entry.classId = classId;
            entry.weight = candidates[i].weight;
            entry.version = life.getClassVersion(classId);
            // An incompletely wired class must not become an unmintable pending reward.
            if (binderData.classVersion(classId) != entry.version) continue;
            entry.rarityId = life.getClassRarityId(classId);
            entry.name = life.getClassName(classId);
            entry.rarityName = life.getRarityName(entry.rarityId);
            entry.config = life.getClassConfigAtVersion(classId, entry.version);
            _classCandidates[id].push(entry);
        }
    }

    function _issueItem(bytes32 id) private {
        QuestItemReward[] storage candidates = _itemCandidates[id];
        if (candidates.length == 0) return;
        uint16[8] memory weights;
        for (uint256 i; i < candidates.length; ++i) {
            weights[i] = candidates[i].weight;
        }
        bytes32 seed = _activities[id].seed;
        QuestItemReward memory item =
            candidates[GrowthRollLib.pick(GrowthRollLib.expand(seed, id, "QUEST_ITEM_SELECT", 0), weights, 0)];
        uint128 amount = uint128(
            uint256(item.minAmount)
                + GrowthRollLib.expand(seed, id, "QUEST_ITEM_AMOUNT", 0) % (uint256(item.maxAmount) - item.minAmount + 1)
        );
        address collection = item.family == ItemFamily.EQUIPMENT
            ? address(equipment)
            : item.family == ItemFamily.TOME_OR_GRIMOIRE ? address(tomes) : address(sItems);
        _selectedItem[id] = SelectedItem(collection, item.libraryId, amount);
        address beneficiary = _activities[id].beneficiary;
        if (item.family == ItemFamily.EQUIPMENT) equipment.mintToWallet(beneficiary, item.libraryId, id);
        else if (item.family == ItemFamily.TOME_OR_GRIMOIRE) tomes.mintToWallet(beneficiary, item.libraryId, id);
        else sItems.mintToWallet(beneficiary, item.libraryId, amount, id);
    }

    function _issueBinder(bytes32 id) private {
        ClassSnapshot[] storage candidates = _classCandidates[id];
        if (candidates.length == 0) return;
        uint16[8] memory weights;
        for (uint256 i; i < candidates.length; ++i) {
            weights[i] = candidates[i].weight;
        }
        bytes32 seed = _activities[id].seed;
        ClassSnapshot memory selected =
            candidates[GrowthRollLib.pick(GrowthRollLib.expand(seed, id, "QUEST_NFT_SELECT", 0), weights, 0)];
        binderStructs.NFTMetadata memory meta;
        meta.name = selected.name;
        meta.classId = selected.classId;
        meta.rarityId = selected.rarityId;
        meta.configVersion = selected.version;
        meta.staticStats =
            StatAllocationLib.allocate(selected.config, bytes32(GrowthRollLib.expand(seed, id, "QUEST_NFT_STATS", 0)));
        uint16 hp = uint16(meta.staticStats.stats[4]) * selected.config.hpPerVit;
        uint16 mp = uint16(meta.staticStats.stats[5]) * selected.config.mpPerWis;
        meta.dynamicStats = binderStructs.DynamicStats(hp, mp, hp, mp);
        nftReward[id] = binderData.mintQuestReward(_activities[id].binderId, id, meta, selected.rarityName);
    }
}
