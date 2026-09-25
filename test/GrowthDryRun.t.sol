// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GameDryRunTest} from "./GameDryRun.t.sol";
import {GrowthDeploymentBase} from "../script/DeployGrowth.s.sol";
import {InitializeGrowth} from "../initiate/InitializeGrowth.sol";
import {ActivityEscrow} from "../modular/growth/ActivityEscrow.sol";
import {Training} from "../modular/growth/Training.sol";
import {Quest} from "../modular/growth/Quest.sol";
import {GrowthRollLib} from "../modular/growth/GrowthRollLib.sol";
import {ITraining} from "../modular/interfaces/ITraining.sol";
import {IQuest} from "../modular/interfaces/IQuest.sol";
import {Book0fArts} from "../modular/shelf/Book0fArts.sol";
import {ScaleOfBalance} from "../modular/ScaleOfBalance.sol";
import {binderStructs} from "../modular/supportContract/binderStructs.sol";
import {QuestItemReward, ItemFamily, EqConfig, InventorySlot} from "../modular/Items/ItemStruct.sol";
import {ERC20} from "@openzeppelin/contracts-4.8/token/ERC20/ERC20.sol";

contract GrowthGold is ERC20 {
    constructor(address recipient) ERC20("Simulation Gold", "GOLD") {
        _mint(recipient, 100 ether);
    }
}

/// @notice Real CP5.1a deployment + the production growth deploy/wire path; only Pyth delivery is simulated.
/// Inherited dry runs also run with growth wired, checking backwards compatibility.
contract GrowthDryRunTest is GameDryRunTest, GrowthDeploymentBase {
    uint256 private constant ENTROPY_FEE = 0.0001 ether;
    GrowthDeployment private g;
    Book0fArts private arts;

    function setUp() public override {
        super.setUp();
        vm.deal(address(this), 100 ether);
        arts = Book0fArts(control.book0fArts());
        g = _deployGrowth(control, address(entropy), PROVIDER, BOB);
        InitializeGrowth.seed(control);
        uint32[] memory pool = new uint32[](2);
        pool[0] = 1;
        pool[1] = 2;
        control.setArtRewardPool(1, pool);
        pool = new uint32[](1);
        pool[0] = 3;
        control.setArtRewardPool(2, pool);
        _itemTable(ItemFamily.EQUIPMENT, 1);
        binderStructs.QuestClassReward[] memory classes = new binderStructs.QuestClassReward[](1);
        classes[0] = binderStructs.QuestClassReward(1, 1);
        control.setNftRewardTable(1, classes);
        life.enableClassAcquisition(1, 4);
        control.addQuestRule(InitializeGrowth.questRule(1, 1, 1, 2));
        g.quest.fundRewards{value: 2 ether}(address(0), 2 ether);
        vm.startPrank(ALICE);
        data.setApprovalForAll(address(g.training), true);
        data.setApprovalForAll(address(g.quest), true);
        vm.stopPrank();
        assertTrue(control.isGrowthWired());
        assertEq(control.growthWiringError(), 0);
    }

    function testTrainingLifecycleAndCallbackOnlyStoresSeed() public {
        uint256 tokenId = _mint(1);
        uint32 beforeStat = g.ledger.getSwg(tokenId)[0];
        bytes32 id = _startTraining(tokenId, 1, 0);
        assertEq(id, keccak256(abi.encode(address(g.training), tokenId, uint256(1))));
        assertEq(data.ownerOf(tokenId), address(g.training));
        assertEq(data.getUnitState(tokenId).activity.activityId, 3);
        assertEq(data.activeGrowthActivity(tokenId), id);
        assertEq(g.ledger.trainingUses(tokenId), 1);
        vm.expectRevert();
        g.training.requestTrainingResolution{value: ENTROPY_FEE}(id);
        vm.prank(ALICE);
        vm.expectRevert();
        g.training.claimTrainedBinder(id);
        vm.expectRevert();
        data.forceClearActivity(tokenId);
        vm.prank(address(g.training));
        vm.expectRevert();
        g.ledger.settleTraining(id);
        vm.prank(ALICE);
        vm.expectRevert();
        g.quest.startQuest{value: 0.05 ether}(tokenId, 1, 0);

        _requestTraining(id);
        uint64 sequence = g.training.getActivity(id).sequence;
        vm.expectRevert();
        g.training._entropyCallback(sequence, PROVIDER, bytes32(0));
        vm.expectRevert();
        entropy.fulfill(sequence, ALICE, bytes32(0));
        vm.expectRevert();
        g.training.requestTrainingResolution{value: ENTROPY_FEE}(id);
        entropy.fulfill(sequence, PROVIDER, bytes32(0));
        assertEq(g.ledger.getSwg(tokenId)[0], beforeStat);
        assertEq(data.ownerOf(tokenId), address(g.training));
        vm.expectRevert();
        entropy.fulfill(sequence, PROVIDER, bytes32(0));
        vm.prank(BOB);
        g.training.finalizeTraining(id);
        assertEq(g.ledger.getSwg(tokenId)[0], beforeStat + 1);
        vm.expectRevert();
        g.training.finalizeTraining(id);
        vm.prank(address(g.training));
        vm.expectRevert();
        g.ledger.settleTraining(id);
        vm.prank(BOB);
        vm.expectRevert();
        g.training.claimTrainedBinder(id);
        vm.prank(ALICE);
        g.training.claimTrainedBinder(id);
        assertEq(data.ownerOf(tokenId), ALICE);
        assertEq(data.activeGrowthCount(), 0);
        assertTrue(data.getUnitState(tokenId).idle);
    }

    function testSharedLifetimeUsesAndPaidFailures() public {
        uint256 tokenId = _mint(1);
        uint32[8] memory initial = g.ledger.getSwg(tokenId);
        for (uint256 i; i < 3; ++i) {
            bytes32 id = _startTraining(tokenId, i == 1 ? 2 : 1, i == 1 ? 1 : 0);
            _finishTraining(id, bytes32(uint256(8_000) << 192));
            assertFalse(g.training.getActivity(id).success);
            assertEq(g.ledger.trainingUses(tokenId), i + 1);
        }
        assertEq(abi.encode(g.ledger.getSwg(tokenId)), abi.encode(initial));
        assertEq(g.training.credits(address(0), BOB), 0.03 ether);
        vm.prank(ALICE);
        data.transferFrom(ALICE, BOB, tokenId);
        vm.prank(BOB);
        data.transferFrom(BOB, ALICE, tokenId);
        vm.prank(ALICE);
        vm.expectRevert();
        g.training.startTraining{value: 0.01 ether}(tokenId, 2, 1);
    }

    function testTrainingSnapshotsRuleAndGoldAsset() public {
        uint256 tokenId = _mint(1);
        bytes32 id = _startTraining(tokenId, 1, 0);
        binderStructs.TrainingRule memory changed = g.book.getTrainingRule(1, 1, 0);
        changed.minGain = 50;
        changed.maxGain = 50;
        changed.successBps = 10_000;
        control.updateDrillRule(1, changed);
        GrowthGold gold = new GrowthGold(ALICE);
        control.setGoldAsset(address(gold));
        uint32 beforeStat = g.ledger.getSwg(tokenId)[0];
        _finishTraining(id, bytes32(0));
        assertEq(g.ledger.getSwg(tokenId)[0], beforeStat + 1);
        assertEq(g.training.credits(address(0), BOB), 0.01 ether);
        vm.startPrank(ALICE);
        gold.approve(address(g.training), type(uint256).max);
        id = g.training.startTraining(tokenId, 1, 0);
        vm.stopPrank();
        control.setGoldAsset(address(0));
        _finishTraining(id, bytes32(0));
        assertEq(g.ledger.getSwg(tokenId)[0], beforeStat + 51);
        assertEq(gold.balanceOf(address(g.training)), changed.terms.price);
        assertEq(g.training.credits(address(gold), BOB), changed.terms.price);
        vm.prank(BOB);
        g.training.withdrawCredit(address(gold));
        assertEq(gold.balanceOf(BOB), changed.terms.price);
    }

    function testRescueTimeoutAccountingAndNoSeedEscape() public {
        uint256 tokenId = _mint(1);
        bytes32 id = _startTraining(tokenId, 1, 0);
        ActivityEscrow.Activity memory record = g.training.getActivity(id);
        vm.warp(uint256(record.maturesAt) + record.rescueDelay);
        vm.prank(ALICE);
        vm.expectRevert();
        g.training.rescueTraining(id); // Active, but no request was made.
        _requestTraining(id);
        record = g.training.getActivity(id);
        vm.warp(uint256(record.requestedAt) + record.rescueDelay - 1);
        vm.prank(ALICE);
        vm.expectRevert();
        g.training.rescueTraining(id);
        vm.warp(block.timestamp + 1);
        vm.prank(ALICE);
        g.training.rescueTraining(id);
        assertEq(data.ownerOf(tokenId), ALICE);
        assertEq(g.training.credits(address(0), ALICE), record.price);
        assertEq(g.ledger.trainingUses(tokenId), 1);
        vm.expectRevert();
        entropy.fulfill(record.sequence, PROVIDER, bytes32(0));
        id = _startTraining(tokenId, 1, 0);
        _requestTraining(id);
        entropy.fulfill(g.training.getActivity(id).sequence, PROVIDER, bytes32(uint256(8_000) << 192));
        vm.warp(block.timestamp + 2 days);
        vm.prank(ALICE);
        vm.expectRevert();
        g.training.rescueTraining(id);
        g.training.finalizeTraining(id);
        assertFalse(g.training.getActivity(id).success);
    }

    function testRetiredControllerFinishesOnlyItsExistingRecords() public {
        uint256 first = _mint(1);
        uint256 second = _mint(1);
        bytes32 requested = _startTraining(first, 1, 0);
        bytes32 unrequested = _startTraining(second, 1, 0);
        _requestTraining(requested);
        Training previous = g.training;
        Training replacement = new Training(_deps());
        control.configureGrowthSystem(address(g.book), address(g.ledger), address(replacement), address(g.quest));
        vm.prank(ALICE);
        vm.expectRevert();
        previous.startTraining{value: 0.01 ether}(first, 1, 0);
        vm.expectRevert();
        previous.requestTrainingResolution{value: ENTROPY_FEE}(unrequested);
        entropy.fulfill(previous.getActivity(requested).sequence, PROVIDER, bytes32(0));
        previous.finalizeTraining(requested);
        vm.prank(ALICE);
        previous.claimTrainedBinder(requested);
        ActivityEscrow.Activity memory record = previous.getActivity(unrequested);
        vm.warp(uint256(record.maturesAt) + record.rescueDelay);
        vm.prank(ALICE);
        previous.rescueTraining(unrequested);
        assertEq(data.ownerOf(first), ALICE);
        assertEq(data.ownerOf(second), ALICE);
        assertEq(data.activeGrowthCount(), 0);
        assertEq(previous.pendingActivityCount(), 0);
        assertEq(g.ledger.trainingUses(first), 1);
    }

    function testGrowthUnequipsFiveItemsInPlaceWithFullInventory() public {
        uint256 tokenId = _mint(1);
        uint8 base = data.getNFTDetails(tokenId).staticStats.stats[0];
        for (uint16 eqId = 1; eqId <= 5; ++eqId) {
            EqConfig memory cfg = items.getEq(eqId);
            cfg.statsReq[0] = base;
            control.updateEq(eqId, cfg);
            equipment.mintToBinder(tokenId, eqId, bytes32("growth-test"));
            vm.prank(ALICE);
            inventory.equip(tokenId, uint8(eqId - 1));
        }
        sItems.mintToBinder(tokenId, 1, 15 * 99, bytes32("full"));
        assertEq(_occupied(tokenId), 20);
        assertEq(g.ledger.getTrueStats(tokenId)[0], int64(uint64(base)) + 5);
        binderStructs.TrainingRule memory rule = g.book.getTrainingRule(2, 1, 0);
        rule.successBps = 10_000;
        rule.profile = _fixedProfile(1, 2, 0);
        rule.profile.minDeltas = [int32(3), 1, -10];
        rule.profile.maxDeltas = rule.profile.minDeltas;
        control.updateXDrillProfile(1, rule);
        bytes32 id = _startTraining(tokenId, 2, 1);
        _finishTraining(id, bytes32(0));
        uint256 expected = base > 10 ? base - 10 : 1;
        assertEq(g.ledger.getSwg(tokenId)[0], expected);
        assertEq(data.getNFTDetails(tokenId).staticStats.stats[0], base);
        assertEq(_occupied(tokenId), 20);
        for (uint8 i; i < 5; ++i) {
            InventorySlot memory slot = inventory.getSlot(tokenId, i);
            assertFalse(slot.equipped);
            assertTrue(slot.occupied);
            assertEq(equipment.ownerOf(slot.instanceTokenId), inventory.accountOf(tokenId));
        }
    }

    function testEquipmentCannotQualifyItsOwnRequirement() public {
        uint256 tokenId = _mint(1);
        EqConfig memory cfg = items.getEq(1);
        cfg.statsReq[0] = uint16(data.getNFTDetails(tokenId).staticStats.stats[0]) + 1;
        cfg.statsChgInc[0] = 100;
        control.updateEq(1, cfg);
        equipment.mintToBinder(tokenId, 1, bytes32(0));
        vm.prank(ALICE);
        vm.expectRevert();
        inventory.equip(tokenId, 0);
    }

    function testErrantryIsUnlimitedAndUsesBaseEligibility() public {
        uint256 tokenId = _mint(1);
        binderStructs.TrainingRule memory rule = _rewardErrantry();
        rule.artBps = 0;
        rule.patternBps = 0;
        control.updateErrantryRule(1, rule);
        bytes32 base = keccak256(abi.encode(data.getNFTDetails(tokenId).staticStats));
        for (uint256 i; i < 4; ++i) {
            _finishTraining(_startTraining(tokenId, 3, 1), bytes32(i));
        }
        assertEq(g.ledger.completedErrantryCount(tokenId), 4);
        assertEq(g.ledger.trainingUses(tokenId), 0);
        assertEq(keccak256(abi.encode(data.getNFTDetails(tokenId).staticStats)), base);
        assertEq(g.training.credits(address(0), BOB), 0.4 ether);
    }

    function testLiveArtDisableSkipsSelectedRewardWithoutReroll() public {
        uint256 tokenId = _mint(1);
        binderStructs.TrainingRule memory rule = _rewardErrantry();
        rule.patternBps = 0;
        control.updateErrantryRule(1, rule);
        bytes32 id = _startTraining(tokenId, 3, 1);
        _requestTraining(id);
        bytes32 seed = bytes32(uint256(123));
        uint32 selected = uint32(1 + GrowthRollLib.expand(seed, id, "ERRANTRY_ART", 1) % 2);
        arts.setArtEnabled(selected, false, 2);
        entropy.fulfill(g.training.getActivity(id).sequence, PROVIDER, seed);
        g.training.finalizeTraining(id);
        (, uint32 actual,) = g.training.skillReward(id, false);
        assertEq(actual, selected);
        assertEq(skills.getActiveSkillCount(tokenId) + skills.getPassiveSkillCount(tokenId), 0);
        assertEq(g.training.credits(address(0), ALICE), 0, "No fallback");
        assertEq(g.ledger.completedErrantryCount(tokenId), 1);
        vm.prank(ALICE);
        g.training.claimTrainedBinder(id);
    }

    function testActivityArtEligibilityFrozenButTomeRemainsLive() public {
        uint256 tokenId = _mint(1);
        uint32[] memory pool = new uint32[](1);
        pool[0] = 1;
        control.setArtRewardPool(1, pool);
        binderStructs.TrainingRule memory rule = _rewardErrantry();
        rule.patternBps = 0;
        control.updateErrantryRule(1, rule);
        bytes32 id = _startTraining(tokenId, 3, 1);
        binderStructs.ArtDefinition memory changed = arts.getArtDefinition(1);
        changed.version = 2;
        changed.minBaseStats[0] = 255;
        arts.updateArt(changed, new uint256[](0));
        _finishTraining(id, bytes32(0));
        assertEq(skills.getLearnedArtVersion(tokenId, 1), 1);
        uint256 second = _mint(1);
        uint256 tome = tomes.mintToBinder(second, 1, bytes32(0));
        vm.prank(ALICE);
        vm.expectRevert();
        skills.learnFromTome(second, tome);
    }

    function testPendingTomeCannotOverlapGrowth() public {
        uint256 tokenId = _mint(1);
        uint256 tome = tomes.mintToBinder(tokenId, 4, bytes32(0));
        vm.prank(ALICE);
        skills.learnFromTome{value: ENTROPY_FEE}(tokenId, tome);
        uint64 sequence = entropy.sequence();
        assertEq(skills.pendingTomeCount(tokenId), 1);
        vm.prank(ALICE);
        vm.expectRevert();
        g.training.startTraining{value: 0.01 ether}(tokenId, 1, 0);
        entropy.fulfill(sequence, PROVIDER, bytes32(uint256(5_000)));
        assertEq(skills.pendingTomeCount(tokenId), 0);
        _startTraining(tokenId, 1, 0);
    }

    function testQuestDeathDiscardsRewardsAndKeepsTbaAssets() public {
        uint256 tokenId = _mint(1);
        sItems.mintToBinder(tokenId, 1, 20 * 99, bytes32(0));
        binderStructs.QuestRule memory rule = _allRewards();
        rule.deathBps = 10_000;
        control.updateQuestRule(1, rule);
        uint256 reserve = g.quest.rewardPool(address(0));
        bytes32 id = _startQuest(tokenId);
        _resolveQuest(id, bytes32(0));
        assertEq(data.ownerOf(tokenId), GRAVEYARD);
        assertEq(data.getNFTDetails(tokenId).dynamicStats.currentHP, 0);
        assertEq(data.activeGrowthCount(), 0);
        assertEq(g.quest.nftReward(id), 0);
        assertEq(g.quest.credits(address(0), ALICE), 0);
        assertEq(g.quest.rewardPool(address(0)), reserve);
        assertEq(skills.getActiveSkillCount(tokenId) + skills.getPassiveSkillCount(tokenId), 0);
        assertEq(skills.getMoveSets(tokenId)[0], 0);
        assertEq(_occupied(tokenId), 20);
        assertEq(sItems.balanceOf(inventory.accountOf(tokenId), 1), 20 * 99);
        int32[8] memory zero;
        assertEq(abi.encode(g.ledger.getGrowthDelta(tokenId)), abi.encode(zero));
        vm.prank(ALICE);
        vm.expectRevert();
        g.quest.claimQuestBinder(id);
    }

    function testQuestAllRewardsInjuryAndFullInventory() public {
        uint256 tokenId = _mint(1);
        sItems.mintToBinder(tokenId, 1, 20 * 99, bytes32(0));
        binderStructs.QuestRule memory rule = _allRewards();
        rule.injuryAmount = 10_000;
        control.updateQuestRule(1, rule);
        bytes32 id = _startQuest(tokenId);
        assertEq(data.ownerOf(tokenId), address(g.quest));
        assertEq(data.getUnitState(tokenId).activity.activityId, 4);
        assertEq(g.training.pendingActivityCount(), 0);
        _resolveQuest(id, bytes32(0));
        assertEq(data.getNFTDetails(tokenId).dynamicStats.currentHP, 1);
        assertEq(equipment.ownerOf(1), ALICE);
        assertEq(_occupied(tokenId), 20);
        assertEq(data.ownerOf(g.quest.nftReward(id)), ALICE);
        assertEq(skills.getActiveSkillCount(tokenId) + skills.getPassiveSkillCount(tokenId), 1);
        assertEq(skills.getMoveSets(tokenId)[0], 3);
        uint256 credit = g.quest.credits(address(0), ALICE);
        assertGe(credit, rule.minCurrency);
        assertLe(credit, rule.maxCurrency);
        assertEq(g.quest.credits(address(0), BOB), rule.terms.price);
        vm.prank(ALICE);
        g.quest.claimQuestBinder(id);
        assertEq(data.ownerOf(tokenId), ALICE);
        uint256 wallet = ALICE.balance;
        vm.prank(ALICE);
        g.quest.withdrawCredit(address(0));
        assertEq(ALICE.balance, wallet + credit);
        assertFalse(data.authorizedBinderLogic(address(g.quest)));
        assertFalse(data.authorizedFusionMinter(address(g.quest)));
    }

    function testQuestFailureStillResolvesLivingSideEvents() public {
        uint256 tokenId = _mint(1);
        binderStructs.QuestRule memory rule = _allRewards();
        rule.successBps = 0;
        control.updateQuestRule(1, rule);
        uint16 hp = data.getNFTDetails(tokenId).dynamicStats.currentHP;
        bytes32 id = _startQuest(tokenId);
        _resolveQuest(id, bytes32(uint256(22)));
        assertFalse(g.quest.getActivity(id).success);
        assertLt(data.getNFTDetails(tokenId).dynamicStats.currentHP, hp);
        assertEq(g.quest.credits(address(0), ALICE), 0);
        assertEq(g.quest.nftReward(id), 0);
        (address collection,,,) = g.quest.itemReward(id);
        assertEq(collection, address(0));
        assertEq(skills.getActiveSkillCount(tokenId) + skills.getPassiveSkillCount(tokenId), 1);
        assertEq(skills.getMoveSets(tokenId)[0], 3);
    }

    function testAllItemFamiliesHonorPendingRewardsAfterDisable() public {
        binderStructs.QuestRule memory rule = _itemOnlyQuest();
        control.updateQuestRule(1, rule);
        for (uint8 family; family < 3; ++family) {
            uint256 tokenId = _mint(1);
            _itemTable(ItemFamily(family), 1);
            bytes32 id = _startQuest(tokenId);
            if (family == 0) control.deactivateEq(1);
            else if (family == 1) control.deactivateTome(1);
            else control.deactivateSItem(1);
            _resolveQuest(id, bytes32(0));
            if (family == 0) assertEq(equipment.ownerOf(1), ALICE);
            else if (family == 1) assertEq(tomes.ownerOf(1), ALICE);
            else assertEq(sItems.balanceOf(ALICE, 1), 1);
            // New activities do not include the disabled item in their snapshot.
            uint256 other = _mint(1);
            bytes32 later = _startQuest(other);
            _resolveQuest(later, bytes32(0));
            (address collection,,,) = g.quest.itemReward(later);
            assertEq(collection, address(0));
            // Neither arbitrary recipients nor duplicate issuance are authorized.
            vm.prank(address(g.quest));
            vm.expectRevert();
            equipment.mintToWallet(BOB, 1, id);
        }
    }

    function testRetiredQuestHonorsSnapshotWithoutGenericMintAuthority() public {
        control.updateQuestRule(1, _itemOnlyQuest());
        uint256 tokenId = _mint(1);
        bytes32 id = _startQuest(tokenId);
        _requestQuest(id);
        Quest previous = g.quest;
        Quest replacement = new Quest(_deps());
        control.configureGrowthSystem(address(g.book), address(g.ledger), address(g.training), address(replacement));
        control.deactivateEq(1);
        entropy.fulfill(previous.getActivity(id).sequence, PROVIDER, bytes32(0));
        previous.finalizeQuest(id);
        assertEq(equipment.ownerOf(1), ALICE);
        assertFalse(equipment.issuers(address(previous)));
        vm.prank(address(previous));
        vm.expectRevert();
        equipment.mintToWallet(ALICE, 1, id);
        vm.prank(address(previous));
        vm.expectRevert();
        equipment.mintToBinder(tokenId, 1, id);
        vm.prank(ALICE);
        previous.claimQuestBinder(id);
        assertEq(data.ownerOf(tokenId), ALICE);
    }

    function testQuestSnapshotContextRuleAndNftClassVersion() public {
        binderStructs.QuestRule memory rule = _itemOnlyQuest();
        rule.itemBps = 0;
        rule.nftBps = 10_000;
        rule.contextTableId = 77;
        control.updateQuestRule(1, rule);
        uint256 tokenId = _mint(1);
        vm.prank(ALICE);
        vm.expectRevert();
        g.quest.startQuest{value: rule.terms.price}(tokenId, 1, 78);
        bytes32 id = _startQuest(tokenId);
        assertEq(g.quest.contextTable(id), 77);
        binderStructs.ClassConfig memory cfg = life.getClassConfig(1);
        life.upgradeClassConfig(1, cfg.totalPoints, cfg.minStats, cfg.maxStats, cfg.hpPerVit, cfg.mpPerWis, 2);
        data.setClassVersion(1, 2);
        rule.deathBps = 10_000;
        rule.contextTableId = 99;
        control.updateQuestRule(1, rule);
        _resolveQuest(id, bytes32(0));
        uint256 rewarded = g.quest.nftReward(id);
        assertEq(data.ownerOf(rewarded), ALICE);
        assertEq(data.getConfigVersion(rewarded), 1);
        assertEq(g.quest.contextTable(id), 77);
        assertFalse(g.quest.getActivity(id).dead);
    }

    function testQuestLiveDisableSkipsArtAndPatternButOtherRewardsSettle() public {
        control.updateQuestRule(1, _allRewards());
        uint256 tokenId = _mint(1);
        bytes32 id = _startQuest(tokenId);
        arts.setArtEnabled(1, false, 2);
        arts.setArtEnabled(2, false, 2);
        arts.setArtEnabled(3, false, 2);
        _resolveQuest(id, bytes32(0));
        assertEq(skills.getActiveSkillCount(tokenId) + skills.getPassiveSkillCount(tokenId), 0);
        assertEq(skills.getMoveSets(tokenId)[0], 0);
        assertEq(equipment.ownerOf(1), ALICE);
        assertEq(data.ownerOf(g.quest.nftReward(id)), ALICE);
        vm.prank(ALICE);
        g.quest.claimQuestBinder(id);
    }

    function testNoFourthPatternAndNoDuplicateArt() public {
        uint256 tokenId = _mint(1);
        for (uint32 artId = 4; artId <= 6; ++artId) {
            binderStructs.ArtDefinition memory definition = arts.getArtDefinition(3);
            definition.artId = artId;
            arts.addArt(definition, new uint256[](0));
            skills.grantMoveSet(tokenId, artId);
        }
        skills.grantActiveSkill(tokenId, 1);
        skills.grantPassiveSkill(tokenId, 2);
        control.updateErrantryRule(1, _rewardErrantry());
        _finishTraining(_startTraining(tokenId, 3, 1), bytes32(0));
        assertEq(abi.encode(skills.getMoveSets(tokenId)), abi.encode([uint32(4), 5, 6]));
        assertEq(skills.getActiveSkillCount(tokenId), 1);
        assertEq(skills.getPassiveSkillCount(tokenId), 1);
    }

    function testBookHistoryAuthorityValidationAndDiagnostics() public {
        binderStructs.TrainingRule memory initial = g.book.getTrainingRule(1, 1, 0);
        vm.prank(ALICE);
        vm.expectRevert();
        g.book.addDrillRule(initial);
        initial.successBps = 10_001;
        vm.expectRevert();
        control.updateDrillRule(1, initial);
        initial.successBps = 9_000;
        ScaleOfBalance(control.scaleOfBalance()).updateDrillRule(1, initial);
        assertEq(g.book.getTrainingRule(1, 1, 0).successBps, 9_000);
        assertEq(g.book.getTrainingRule(1, 1, 1).successBps, 8_000);
        control.deactivateDrillRule(1);
        assertFalse(g.book.getTrainingRule(1, 1, 0).terms.enabled);
        assertEq(control.addDrillRule(initial), 2);
        vm.prank(ALICE);
        vm.expectRevert();
        g.ledger.settleQuest(bytes32(uint256(1)));
        vm.expectRevert();
        control.setActivityModule(3, address(g.training));
        vm.expectRevert();
        control.setActivityModule(4, address(g.quest));
        vm.prank(address(control));
        data.setActivityController(3, address(g.quest));
        assertFalse(control.isGrowthWired());
        assertEq(control.growthWiringError(), 8);
    }

    function testFuzzQuestDeathFirstAndSurvivorHpFloor(bytes32 seed) public {
        uint256 tokenId = _mint(1);
        binderStructs.QuestRule memory rule = g.book.getQuestRule(1, 0);
        rule.injuryBps = 10_000;
        rule.injuryAmount = 10_000;
        control.updateQuestRule(1, rule);
        bytes32 id = _startQuest(tokenId);
        bool dead = GrowthRollLib.expand(seed, id, "QUEST_DEATH", 0) % 10_000 < rule.deathBps;
        _resolveQuest(id, seed);
        assertEq(g.quest.getActivity(id).dead, dead);
        assertEq(data.ownerOf(tokenId), dead ? GRAVEYARD : address(g.quest));
        assertEq(data.getNFTDetails(tokenId).dynamicStats.currentHP, dead ? 0 : 1);
        if (dead) {
            assertEq(g.quest.nftReward(id), 0);
            assertEq(g.quest.credits(address(0), ALICE), 0);
        } else {
            vm.prank(ALICE);
            g.quest.claimQuestBinder(id);
        }
    }

    function testQuestSnapshotsOnlyFullyRegisteredNftClasses() public {
        uint256 tokenId = _mint(1);
        life.addNewClass(100, "Unwired class", 1, life.getClassConfig(1), 1);
        life.enableClassAcquisition(100, 4);
        binderStructs.QuestClassReward[] memory classes = new binderStructs.QuestClassReward[](1);
        classes[0] = binderStructs.QuestClassReward(100, 1);
        control.setNftRewardTable(1, classes);
        binderStructs.QuestRule memory rule = _itemOnlyQuest();
        rule.itemBps = 0;
        rule.nftBps = 10_000;
        control.updateQuestRule(1, rule);
        bytes32 id = _startQuest(tokenId);
        data.setClassVersion(100, 1); // A later registration cannot enter the earlier snapshot.
        _resolveQuest(id, bytes32(0));
        assertEq(g.quest.nftReward(id), 0);
        vm.prank(ALICE);
        g.quest.claimQuestBinder(id);
        id = _startQuest(tokenId);
        _resolveQuest(id, bytes32(0));
        assertEq(data.getNFTClass(g.quest.nftReward(id)), 100);
    }

    function testQuestReserveRescueAndExactNativePayment() public {
        uint256 tokenId = _mint(1);
        binderStructs.QuestRule memory rule = g.book.getQuestRule(1, 0);
        uint256 pool = g.quest.rewardPool(address(0));
        vm.prank(ALICE);
        vm.expectRevert(ActivityEscrow.InvalidPayment.selector);
        g.quest.startQuest{value: rule.terms.price + 1}(tokenId, 1, 0);
        assertEq(data.ownerOf(tokenId), ALICE);
        assertEq(data.activeGrowthCount(), 0);
        assertEq(g.quest.binderNonce(tokenId), 0);
        assertEq(g.quest.rewardPool(address(0)), pool);
        bytes32 id = _startQuest(tokenId);
        assertEq(g.quest.rewardPool(address(0)), pool - rule.maxCurrency);
        _requestQuest(id);
        ActivityEscrow.Activity memory record = g.quest.getActivity(id);
        vm.warp(uint256(record.requestedAt) + record.rescueDelay);
        vm.prank(BOB);
        vm.expectRevert();
        g.quest.rescueQuest(id);
        vm.prank(ALICE);
        g.quest.rescueQuest(id);
        assertEq(g.quest.rewardPool(address(0)), pool);
        assertEq(g.quest.credits(address(0), ALICE), rule.terms.price);
        assertEq(data.ownerOf(tokenId), ALICE);
        vm.expectRevert();
        entropy.fulfill(record.sequence, PROVIDER, bytes32(0));
        vm.prank(ALICE);
        g.quest.withdrawCredit(address(0));
        assertEq(address(g.quest).balance, pool);

        rule.terms.refundOnRescue = false;
        control.updateQuestRule(1, rule);
        id = _startQuest(tokenId);
        _requestQuest(id);
        record = g.quest.getActivity(id);
        rule.terms.refundOnRescue = true;
        control.updateQuestRule(1, rule); // The pending cancellation policy stays unchanged.
        vm.warp(uint256(record.requestedAt) + record.rescueDelay);
        vm.prank(ALICE);
        g.quest.rescueQuest(id);
        assertEq(g.quest.credits(address(0), ALICE), 0);
        assertEq(g.quest.credits(address(0), BOB), rule.terms.price);
        assertEq(g.quest.rewardPool(address(0)), pool);
    }

    function testQuestErc20PrefundingAndAssetSnapshot() public {
        uint256 tokenId = _mint(1);
        GrowthGold gold = new GrowthGold(ALICE);
        control.setGoldAsset(address(gold));
        binderStructs.QuestRule memory rule = _itemOnlyQuest();
        rule.itemBps = 0;
        rule.currencyBps = 10_000;
        control.updateQuestRule(1, rule);
        vm.startPrank(ALICE);
        gold.approve(address(g.quest), type(uint256).max);
        vm.expectRevert(ActivityEscrow.InvalidPayment.selector);
        g.quest.startQuest(tokenId, 1, 0); // No reward may be promised without a reserve.
        g.quest.fundRewards(address(gold), 1 ether);
        bytes32 id = g.quest.startQuest(tokenId, 1, 0);
        vm.stopPrank();
        control.setGoldAsset(address(0));
        _resolveQuest(id, bytes32(0));
        uint256 reward = g.quest.credits(address(gold), ALICE);
        assertGe(reward, rule.minCurrency);
        assertLe(reward, rule.maxCurrency);
        assertEq(g.quest.credits(address(0), ALICE), 0);
        assertEq(g.quest.rewardPool(address(gold)), 1 ether - reward);
        vm.prank(ALICE);
        g.quest.withdrawCredit(address(gold));
        vm.prank(BOB);
        g.quest.withdrawCredit(address(gold));
        assertEq(gold.balanceOf(address(g.quest)), g.quest.rewardPool(address(gold)));
        vm.prank(ALICE);
        g.quest.claimQuestBinder(id);
    }

    function testForeignActivityProofAndDependencyReplacementAreRejected() public {
        uint256 trainingToken = _mint(1);
        uint256 questToken = _mint(1);
        bytes32 trainingId = _startTraining(trainingToken, 3, 1);
        bytes32 questId = _startQuest(questToken);
        vm.prank(address(g.quest));
        vm.expectRevert();
        data.releaseGrowthActivity(trainingToken, trainingId);
        vm.prank(address(g.training));
        vm.expectRevert();
        data.settleQuestVitals(questToken, questId, true, 0);
        vm.prank(address(g.quest));
        vm.expectRevert();
        g.ledger.settleTraining(trainingId);
        vm.prank(address(g.training));
        vm.expectRevert();
        g.ledger.settleQuest(questId);
        vm.prank(address(g.training));
        vm.expectRevert();
        data.transferFrom(address(g.training), ALICE, trainingToken);
        vm.expectRevert();
        control.setBook0fArts(address(life));
        vm.expectRevert();
        control.setBook0fLife(address(arts));
        vm.expectRevert();
        control.setBinderSkills(address(g.ledger));
        assertTrue(control.isGrowthWired());
    }

    function testGasTrainingLifecycleAndRuntimeSizes() public {
        _measureTraining(1, "Drill");
        _measureTraining(2, "xDrill");
        control.updateErrantryRule(1, _rewardErrantry());
        _measureTraining(3, "Errantry");
        _reportSize("BinderData", address(data));
        _reportSize("CentralConsole", address(control));
        _reportSize("ScaleOfBalance", control.scaleOfBalance());
        bytes32 implementationSlot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        _reportSize(
            "BinderSkills implementation", address(uint160(uint256(vm.load(address(skills), implementationSlot))))
        );
        _reportSize("Book0fArts", address(arts));
        _reportSize("BinderInventory", address(inventory));
        _reportSize("Equipment", address(equipment));
        _reportSize("TomeAndGrimoires", address(tomes));
        _reportSize("SItems", address(sItems));
        _reportSize("Book0fGrowth", address(g.book));
        _reportSize("BinderGrowth", address(g.ledger));
        _reportSize("Training", address(g.training));
        _reportSize("Quest", address(g.quest));
    }

    function _measureTraining(uint8 kind, string memory label) private {
        uint256 tokenId = _mint(1);
        uint64 beforeSequence = entropy.sequence();
        bytes32 id = _startTraining(tokenId, kind, kind == 1 ? 0 : 1);
        _reportGas(string.concat(label, " start"));
        _requestTraining(id);
        _reportGas(string.concat(label, " request (mock provider)"));
        entropy.fulfill(g.training.getActivity(id).sequence, PROVIDER, bytes32(uint256(1)));
        _reportGas(string.concat(label, " callback (mock delivery)"));
        g.training.finalizeTraining(id);
        _reportGas(string.concat(label, " finalize"));
        vm.prank(ALICE);
        g.training.claimTrainedBinder(id);
        _reportGas(string.concat(label, " claim"));
        assertEq(entropy.sequence(), beforeSequence + 1);
    }

    function testGasMaximumQuestRewardTablesAndFullInventory() public {
        uint256 tokenId = _mint(1);
        _maximumQuestTables();
        uint8 base = data.getNFTDetails(tokenId).staticStats.stats[0];
        for (uint16 eqId = 1; eqId <= 5; ++eqId) {
            EqConfig memory cfg = items.getEq(eqId);
            cfg.statsReq[0] = base;
            control.updateEq(eqId, cfg);
            equipment.mintToBinder(tokenId, eqId, bytes32(0));
            vm.prank(ALICE);
            inventory.equip(tokenId, uint8(eqId - 1));
        }
        sItems.mintToBinder(tokenId, 1, 15 * 99, bytes32(0));
        binderStructs.QuestRule memory rule = _allRewards();
        rule.profile = _fixedProfile(1, 2, 0);
        rule.profile.minDeltas = [int32(10), -5, -5];
        rule.profile.maxDeltas = rule.profile.minDeltas;
        control.updateQuestRule(1, rule);
        uint64 beforeSequence = entropy.sequence();
        bytes32 id = _startQuest(tokenId);
        _reportGas("Max-table Quest start");
        _requestQuest(id);
        _reportGas("Max-table Quest request (mock provider)");
        entropy.fulfill(g.quest.getActivity(id).sequence, PROVIDER, bytes32(uint256(1)));
        _reportGas("Max-table Quest callback (mock delivery)");
        g.quest.finalizeQuest(id);
        _reportGas("Max-table Quest finalize");
        vm.prank(ALICE);
        g.quest.claimQuestBinder(id);
        _reportGas("Max-table Quest claim");
        assertEq(entropy.sequence(), beforeSequence + 1);
        assertEq(_occupied(tokenId), 20);
        for (uint8 i; i < 5; ++i) {
            assertFalse(inventory.getSlot(tokenId, i).equipped);
        }
        assertEq(data.ownerOf(g.quest.nftReward(id)), ALICE);
        assertEq(skills.getActiveSkillCount(tokenId), 1);
        assertGt(skills.getMoveSets(tokenId)[0], 0);
    }

    function _maximumQuestTables() private {
        uint32[] memory pool = new uint32[](16);
        for (uint32 i; i < 32; ++i) {
            binderStructs.ArtDefinition memory definition = arts.getArtDefinition(i < 16 ? 1 : 3);
            definition.artId = 100 + i;
            arts.addArt(definition, new uint256[](0));
            pool[i % 16] = definition.artId;
            if (i == 15 || i == 31) control.setArtRewardPool(i == 15 ? 1 : 2, pool);
        }
        QuestItemReward[] memory rewards = new QuestItemReward[](8);
        binderStructs.QuestClassReward[] memory classes = new binderStructs.QuestClassReward[](8);
        binderStructs.ClassConfig memory cfg = life.getClassConfig(1);
        for (uint16 i; i < 8; ++i) {
            rewards[i] = QuestItemReward(
                i < 5 ? ItemFamily.EQUIPMENT : ItemFamily.TOME_OR_GRIMOIRE, i < 5 ? i + 1 : i - 4, 1, 1, 1
            );
            life.addNewClass(100 + i, "Quest reward", 1, cfg, 1);
            data.setClassVersion(100 + i, 1);
            life.enableClassAcquisition(100 + i, 4);
            classes[i] = binderStructs.QuestClassReward(100 + i, 1);
        }
        control.setItemRewardTable(1, rewards);
        control.setNftRewardTable(1, classes);
    }

    function _reportGas(string memory label) private {
        // Execution gas of the last external call in this local warm-state simulation.
        // Not a Monad RPC gas-limit recommendation; Pyth itself is mocked.
        uint256 used = vm.lastCallGas().gasTotalUsed;
        emit log_named_uint(label, used);
        assertLt(used, 16_000_000);
    }

    function _reportSize(string memory label, address target) private {
        uint256 size = target.code.length;
        emit log_named_uint(label, size);
        assertGt(size, 0);
        assertLt(size, 128 * 1024);
    }

    function _allRewards() private view returns (binderStructs.QuestRule memory rule) {
        rule = g.book.getQuestRule(1, 0);
        rule.deathBps = 0;
        rule.successBps = 10_000;
        rule.currencyBps = 10_000;
        rule.itemBps = 10_000;
        rule.statBps = 10_000;
        rule.nftBps = 10_000;
        rule.injuryBps = 10_000;
        rule.artBps = 10_000;
        rule.patternBps = 10_000;
    }

    function _itemOnlyQuest() private view returns (binderStructs.QuestRule memory rule) {
        rule = g.book.getQuestRule(1, 0);
        rule.deathBps = 0;
        rule.successBps = 10_000;
        rule.currencyBps = 0;
        rule.itemBps = 10_000;
        rule.statBps = 0;
        rule.nftBps = 0;
        rule.injuryBps = 0;
        rule.artBps = 0;
        rule.patternBps = 0;
    }

    function _startQuest(uint256 tokenId) private returns (bytes32) {
        uint128 price = g.book.getQuestRule(1, 0).terms.price;
        vm.prank(ALICE);
        return IQuest(address(g.quest)).startQuest{value: price}(tokenId, 1, 0);
    }

    function _requestQuest(bytes32 id) private {
        vm.warp(g.quest.getActivity(id).maturesAt);
        g.quest.requestQuestResolution{value: ENTROPY_FEE}(id);
    }

    function _resolveQuest(bytes32 id, bytes32 seed) private {
        _requestQuest(id);
        entropy.fulfill(g.quest.getActivity(id).sequence, PROVIDER, seed);
        g.quest.finalizeQuest(id);
    }

    function _deps() private view returns (ActivityEscrow.Dependencies memory) {
        return ActivityEscrow.Dependencies(
            address(control),
            address(data),
            address(g.book),
            address(g.ledger),
            address(skills),
            address(arts),
            address(entropy),
            PROVIDER,
            BOB
        );
    }

    function _startTraining(uint256 tokenId, uint8 kind, uint32 profile) private returns (bytes32) {
        binderStructs.TrainingRule memory rule = g.book.getTrainingRule(kind, kind == 1 ? 1 : profile, 0);
        vm.prank(ALICE);
        return ITraining(address(g.training)).startTraining{value: rule.terms.price}(tokenId, kind, profile);
    }

    function _requestTraining(bytes32 id) private {
        uint48 maturity = g.training.getActivity(id).maturesAt;
        if (block.timestamp < maturity) vm.warp(maturity);
        g.training.requestTrainingResolution{value: ENTROPY_FEE}(id);
    }

    function _finishTraining(bytes32 id, bytes32 seed) private {
        _requestTraining(id);
        entropy.fulfill(g.training.getActivity(id).sequence, PROVIDER, seed);
        g.training.finalizeTraining(id);
        vm.prank(ALICE);
        g.training.claimTrainedBinder(id);
    }

    function _rewardErrantry() private view returns (binderStructs.TrainingRule memory rule) {
        rule = g.book.getTrainingRule(3, 1, 0);
        rule.successBps = 10_000;
        rule.artBps = 10_000;
        rule.patternBps = 10_000;
        rule.artPoolId = 1;
        rule.patternPoolId = 2;
    }

    function _itemTable(ItemFamily family, uint16 itemId) private {
        QuestItemReward[] memory entries = new QuestItemReward[](1);
        entries[0] = QuestItemReward(family, itemId, 1, 1, 1);
        control.setItemRewardTable(1, entries);
    }

    function _fixedProfile(uint8 first, uint8 second, uint8 third)
        private
        pure
        returns (binderStructs.GrowthStatProfile memory profile)
    {
        profile.primaryWeights[first] = 1;
        profile.secondaryWeights[second] = 1;
        profile.tertiaryWeights[third] = 1;
    }
}
