// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployAndWire} from "../script/DeployAndWire.s.sol";
import {InitializeArts} from "../initiate/InitializeArts.sol";
import {InitializeItems} from "../initiate/InitializeItems.sol";
import {BinderData} from "../modular/BinderData.sol";
import {BinderLogic} from "../modular/BinderLogic.sol";
import {BinderSkills} from "../modular/BinderSkills.sol";
import {FusionMinter} from "../modular/FusionMinter.sol";
import {CentralConsole} from "../modular/supportContract/CentralConsole.sol";
import {Book0fLife} from "../modular/shelf/Book0fLife.sol";
import {Book0fArts} from "../modular/shelf/Book0fArts.sol";
import {Book0fItems} from "../modular/shelf/Book0fItems.sol";
import {BinderInventory} from "../modular/Items/BinderInventory.sol";
import {BindersTBA} from "../modular/Items/BindersTBA.sol";
import {ItemStatsView} from "../modular/Items/ItemStatsView.sol";
import {ItemMetadataBuilder} from "../modular/Items/ItemMetadataBuilder.sol";
import {ItemUseRouter} from "../modular/Items/ItemUseRouter.sol";
import {Equipment} from "../modular/Items/Equipment.sol";
import {TomeAndGrimoires} from "../modular/Items/TomeAndGrimoires.sol";
import {SItems} from "../modular/Items/SItems.sol";
import {ItemCollectionBase} from "../modular/Items/ItemCollectionBase.sol";
import {InventorySlot, TomeConfig, TomeBurnPolicy} from "../modular/Items/ItemStruct.sol";
import {ERC6551Registry} from "@erc6551/ERC6551Registry.sol";
import {binderStructs} from "../modular/supportContract/binderStructs.sol";

interface DryRunEntropyConsumer {
    function _entropyCallback(uint64 sequence, address provider, bytes32 seed) external;
}

/// @dev Only randomness delivery is simulated. Every game/custody contract is real.
contract DryRunEntropy {
    uint256 public constant FEE = 0.0001 ether;
    uint64 public sequence;
    mapping(uint64 => address) public consumer;

    function getFeeV2(address, uint32) external pure returns (uint256) {
        return FEE;
    }

    function requestV2(address, bytes32, uint32) external payable returns (uint64) {
        require(msg.value == FEE, "Incorrect entropy fee");
        consumer[++sequence] = msg.sender;
        return sequence;
    }

    function fulfill(uint64 request, address provider, bytes32 seed) external {
        DryRunEntropyConsumer(consumer[request])._entropyCallback(request, provider, seed);
    }
}

/// @notice Fresh isolated EVM per scenario. No RPC, live funds, or private validator deployment.
contract GameDryRunTest is Test, DeployAndWire {
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant PROVIDER = address(0xBEEF);
    address private constant GRAVEYARD = address(0xDEAD);
    BinderData private data;
    BinderLogic private logic;
    BinderSkills private skills;
    FusionMinter private fusion;
    CentralConsole private control;
    Book0fLife private life;
    Book0fItems private items;
    BinderInventory private inventory;
    Equipment private equipment;
    TomeAndGrimoires private tomes;
    SItems private sItems;
    ItemUseRouter private router;
    DryRunEntropy private entropy;
    uint256 private minted;

    function setUp() public {
        entropy = new DryRunEntropy();
        Deployment memory deployed = _deployAndWire(address(this), GRAVEYARD, address(entropy), PROVIDER, "");
        data = BinderData(deployed.binderData);
        logic = BinderLogic(deployed.binderLogic);
        skills = BinderSkills(deployed.binderSkillsProxy);
        fusion = FusionMinter(deployed.fusionMinter);
        control = CentralConsole(deployed.centralConsole);
        life = Book0fLife(deployed.book0fLife);
        InitializeArts.seed(Book0fArts(deployed.book0fArts));
        _deployItems(deployed);
        InitializeItems.seed(control);
        vm.deal(ALICE, 10 ether);
    }

    function _deployItems(Deployment memory deployed) private {
        items = new Book0fItems(address(control), deployed.scaleOfBalance, deployed.book0fArts);
        ItemStatsView stats = new ItemStatsView(address(data));
        ItemMetadataBuilder metadata = new ItemMetadataBuilder();
        inventory = new BinderInventory(
            address(control),
            address(data),
            address(items),
            address(new ERC6551Registry()),
            address(new BindersTBA()),
            address(stats)
        );
        // No validator is substituted: these tests assert game mechanics, NOT live V5 policy.
        equipment = new Equipment(address(control), address(0), address(items), address(metadata));
        tomes = new TomeAndGrimoires(address(control), address(0), address(items), address(metadata));
        sItems = new SItems(address(control), address(0), address(items), address(metadata));
        router = new ItemUseRouter(address(data), address(items), address(inventory));
        control.configureItemSystem(
            address(items),
            address(inventory),
            address(equipment),
            address(tomes),
            address(sItems),
            address(router),
            address(metadata),
            address(stats),
            address(entropy),
            PROVIDER
        );
        control.setItemIssuer(address(equipment), address(this), true);
        control.setItemIssuer(address(tomes), address(this), true);
        control.setItemIssuer(address(sItems), address(this), true);
        fusion.setBinderInventory(address(inventory));
        assertTrue(control.isFullyWired());
        CentralConsole.ItemWiringStatus memory status = control.getItemWiringStatus();
        assertTrue(status.bookAuthorityMatch && status.inventoryDependenciesMatch && status.collectionsMatch);
        assertTrue(status.collectionOwnershipMatch && status.routerDependenciesMatch && status.skillsDependenciesMatch);
    }

    function testDryRunMint() public {
        // Use actual default 75/15/10 distribution, selecting reproducible entropy for each bucket.
        for (uint8 rarity = 1; rarity <= 3; ++rarity) {
            uint256 tokenId = _mint(rarity);
            assertEq(data.getNFTRarityId(tokenId), rarity);
            assertEq(inventory.accountOf(tokenId).code.length, 0, "Mint must not deploy TBA");
            assertFalse(inventory.hasInventory(tokenId));
            assertEq(skills.getActiveSkillCount(tokenId), 0, "Mint does not grant automatic skills");
            _reportUnit(tokenId);
        }
        emit log_string("Unregistered wallet gets general-pool Villager / Squire / Knight. No levels or starter items.");
    }

    function testDryRunFusionSuccess() public {
        bytes32 seed = bytes32(uint256(1));
        uint256 expectedClass = uint256(keccak256(abi.encodePacked(seed, "OUTCUM"))) % 10_000 < 8_000 ? 2 : 3;
        _fuse(seed, expectedClass);
        emit log_string("Success: both parents go to Graveyard; one freshly rolled Squire or Scout replaces them.");
    }

    function testDryRunFusionFailure() public {
        _fuse(bytes32(uint256(7_000)), 1);
        emit log_string("Failure: both parents still go to Graveyard; a freshly rolled Villager replaces them.");
    }

    function testDryRunInventory() public {
        uint256 binderId = _mint(1);
        address account = inventory.accountOf(binderId);
        for (uint16 eqId = 1; eqId <= 5; ++eqId) {
            uint256 tokenId = equipment.mintToWallet(ALICE, eqId, bytes32("simulation"));
            vm.prank(ALICE);
            inventory.depositEquipment(binderId, tokenId);
            assertFalse(inventory.getSlot(binderId, uint8(eqId - 1)).equipped);
            vm.prank(ALICE);
            inventory.equip(binderId, uint8(eqId - 1));
            assertEq(equipment.ownerOf(tokenId), account);
        }
        assertGt(account.code.length, 0);
        assertEq(inventory.equipmentModifiers(binderId)[0], 5);
        sItems.mintToBinder(binderId, 1, 100, bytes32("simulation"));
        assertEq(inventory.getSlot(binderId, 5).amount, 99);
        assertEq(inventory.getSlot(binderId, 6).amount, 1);
        sItems.mintToBinder(binderId, 1, 1_385, bytes32("simulation"));
        assertEq(_occupied(binderId), 20);
        assertEq(sItems.balanceOf(account, 1), 1_485);
        vm.expectRevert(abi.encodeWithSelector(BinderInventory.InventoryFull.selector, binderId));
        sItems.mintToBinder(binderId, 2, 1, bytes32("overflow"));
        assertEq(sItems.balanceOf(account, 2), 0);
        vm.prank(ALICE);
        data.transferFrom(ALICE, BOB, binderId);
        assertEq(inventory.accountOf(binderId), account);
        vm.prank(ALICE);
        vm.expectRevert();
        inventory.withdrawSItem(binderId, 1, 1);
        vm.prank(BOB);
        inventory.withdrawSItem(binderId, 1, 1_485);
        assertEq(sItems.balanceOf(BOB, 1), 1_485);
        assertEq(_occupied(binderId), 5);
        emit log_string(
            "Five equipped + fifteen loose stacks = 20. Overflow is atomic; Binder transfer carries its TBA."
        );
    }

    function testDryRunLearning() public {
        uint256 binderId = _mint(1);
        for (uint16 tomeId = 1; tomeId <= 3; ++tomeId) {
            uint256 tokenId = tomes.mintToWallet(ALICE, tomeId, bytes32("simulation"));
            vm.startPrank(ALICE);
            inventory.depositTome(binderId, tokenId);
            skills.learnFromTome(binderId, tokenId);
            vm.stopPrank();
            assertFalse(inventory.isTomeInInventory(binderId, tokenId));
            vm.expectRevert();
            tomes.ownerOf(tokenId);
            assertEq(skills.getLearnedArtVersion(binderId, tomeId), 1);
        }
        assertTrue(skills.hasActiveSkill(binderId, 1));
        assertTrue(skills.hasPassiveSkill(binderId, 2));
        assertEq(skills.getMoveSets(binderId)[0], 3);
        assertEq(_occupied(binderId), 0);
        uint256 duplicate = tomes.mintToBinder(binderId, 1, bytes32("duplicate"));
        vm.prank(ALICE);
        vm.expectRevert();
        skills.learnFromTome(binderId, duplicate);
        assertEq(tomes.ownerOf(duplicate), inventory.accountOf(binderId));
        emit log_string("Learned Strike v1, Guard v1, and Swing v1. Three Tomes burned; invalid duplicate retained.");
    }

    function testDryRunUnstableLearning() public {
        uint256 binderId = _mint(1);
        uint256 failed = tomes.mintToBinder(binderId, 4, bytes32("failure"));
        vm.prank(ALICE);
        skills.learnFromTome{value: 0.0001 ether}(binderId, failed);
        uint64 request = entropy.sequence();
        vm.prank(ALICE);
        vm.expectRevert();
        skills.learnFromTome{value: 0.0001 ether}(binderId, failed);
        entropy.fulfill(request, PROVIDER, bytes32(uint256(5_000)));
        assertFalse(skills.hasActiveSkill(binderId, 1));
        assertFalse(inventory.isTomeInInventory(binderId, failed));

        uint256 success = tomes.mintToBinder(binderId, 4, bytes32("success"));
        vm.prank(ALICE);
        skills.learnFromTome{value: 0.0001 ether}(binderId, success);
        entropy.fulfill(entropy.sequence(), PROVIDER, bytes32(uint256(4_999)));
        assertTrue(skills.hasActiveSkill(binderId, 1));
        assertEq(_occupied(binderId), 0);
        uint64 completed = entropy.sequence();
        vm.expectRevert();
        entropy.fulfill(completed, PROVIDER, bytes32(0));
        emit log_string(
            "50% Tome boundary: roll 5000 fails and burns; 4999 succeeds and burns; duplicate callbacks rejected."
        );
    }

    function testDryRunTomeTimeoutAndWorldPotion() public {
        uint256 binderId = _mint(1);
        uint256 tome = tomes.mintToBinder(binderId, 4, bytes32("timeout"));
        vm.prank(ALICE);
        skills.learnFromTome{value: 0.0001 ether}(binderId, tome);
        uint64 request = entropy.sequence();
        vm.prank(ALICE);
        vm.expectRevert();
        skills.rescueTomeLearning(request);
        vm.warp(block.timestamp + skills.TOME_RESCUE_DELAY());
        vm.prank(ALICE);
        skills.rescueTomeLearning(request);
        vm.prank(ALICE);
        inventory.withdrawTome(binderId, 0);
        assertEq(tomes.ownerOf(tome), ALICE);
        vm.expectRevert();
        entropy.fulfill(request, PROVIDER, bytes32(0));

        binderStructs.NFTMetadata memory before = data.getNFTDetails(binderId);
        data.adminUpdatePersistentVitals(binderId, 1, before.dynamicStats.currentMP);
        sItems.mintToBinder(binderId, 2, 2, bytes32("potion"));
        vm.prank(ALICE);
        router.useWorldSItem(binderId, 2, 2);
        assertEq(data.getNFTDetails(binderId).dynamicStats.currentHP, 21);
        assertEq(sItems.balanceOf(inventory.accountOf(binderId), 2), 0);
        emit log_string(
            "Unfulfilled Tome rescued after one day; late callback rejected. Two potions burn and restore 20 HP."
        );
    }

    function testDryRunFusionRejectsInventory() public {
        uint256 first = _mint(1);
        uint256 second = _mint(1);
        equipment.mintToBinder(first, 1, bytes32("blocked"));
        uint256 price = fusion.fusionCost() + 0.0001 ether;
        vm.startPrank(ALICE);
        data.setApprovalForAll(address(fusion), true);
        vm.expectRevert(abi.encodeWithSelector(FusionMinter.FusionInventoryNotEmpty.selector, first));
        fusion.riteFusion{value: price}(first, second);
        vm.stopPrank();
        assertEq(data.ownerOf(first), ALICE);
        assertEq(data.ownerOf(second), ALICE);
        emit log_string("Fusion with recognised inventory reverts before any sacrifice.");
    }

    function testDryRunUnstableFailureRetainsOnSuccessTome() public {
        uint256 binderId = _mint(1);
        TomeConfig memory cfg = items.getTome(4);
        cfg.burnPolicy = TomeBurnPolicy.ON_SUCCESS;
        control.updateTome(4, cfg);
        uint256 tome = tomes.mintToBinder(binderId, 4, bytes32("retain"));
        vm.prank(ALICE);
        skills.learnFromTome{value: 0.0001 ether}(binderId, tome);
        entropy.fulfill(entropy.sequence(), PROVIDER, bytes32(uint256(5_000)));
        assertFalse(skills.hasActiveSkill(binderId, 1));
        vm.prank(ALICE);
        inventory.withdrawTome(binderId, 0);
        assertEq(tomes.ownerOf(tome), ALICE);
        emit log_string("ON_SUCCESS policy: a valid random failure retains and unlocks the Tome.");
    }

    function testFuzzRealInventoryConservesBalances(uint16 amountSeed, uint16 withdrawnSeed) public {
        uint128 amount = uint128(bound(amountSeed, 1, 1_980));
        uint128 withdrawn = uint128(bound(withdrawnSeed, 1, amount));
        uint256 binderId = _mint(1);
        sItems.mintToWallet(ALICE, 1, amount, bytes32("fuzz"));
        vm.startPrank(ALICE);
        inventory.depositSItem(binderId, 1, amount);
        inventory.withdrawSItem(binderId, 1, withdrawn);
        vm.stopPrank();
        InventorySlot[20] memory slots = inventory.getSlots(binderId);
        uint256 total;
        for (uint256 i; i < 20; ++i) {
            if (!slots[i].occupied) continue;
            assertLe(slots[i].amount, 99);
            total += slots[i].amount;
        }
        assertEq(total, amount - withdrawn);
        assertEq(total, sItems.balanceOf(inventory.accountOf(binderId), 1));
        assertEq(sItems.balanceOf(ALICE, 1), withdrawn);
    }

    function _mint(uint8 rarity) private returns (uint256 tokenId) {
        uint256 lower = rarity == 1 ? 0 : rarity == 2 ? 7_500 : 9_000;
        uint256 upper = rarity == 1 ? 7_500 : rarity == 2 ? 9_000 : 10_000;
        bytes32 seed;
        for (uint256 i; i < 10_000; ++i) {
            seed = bytes32(i);
            uint256 roll = uint256(keccak256(abi.encodePacked("BINDERS_RARITY", seed))) % 10_000;
            if (roll >= lower && roll < upper) break;
            require(i < 9_999, "No matching simulation seed");
        }
        uint256 price = logic.mintPrice() + 0.0001 ether;
        vm.prank(ALICE);
        logic.requestMint{value: price}(bytes32(uint256(123)));
        entropy.fulfill(entropy.sequence(), PROVIDER, seed);
        tokenId = ++minted;
        assertEq(data.ownerOf(tokenId), ALICE);
        _assertUnit(tokenId);
    }

    function _fuse(bytes32 seed, uint256 expectedClass) private {
        uint256 first = _mint(1);
        uint256 second = _mint(1);
        vm.startPrank(ALICE);
        data.setApprovalForAll(address(fusion), true);
        fusion.riteFusion{value: fusion.fusionCost() + 0.0001 ether}(first, second);
        vm.stopPrank();
        assertEq(data.ownerOf(first), address(fusion));
        assertFalse(data.getUnitState(first).idle);
        entropy.fulfill(entropy.sequence(), PROVIDER, seed);
        assertEq(data.ownerOf(first), GRAVEYARD);
        assertEq(data.ownerOf(second), GRAVEYARD);
        uint256 child = ++minted;
        assertEq(data.ownerOf(child), ALICE);
        assertEq(data.getNFTClass(child), expectedClass);
        assertEq(inventory.accountOf(child).code.length, 0);
        assertEq(fusion.pendingFusionCount(), 0);
        _assertUnit(child);
        _reportUnit(child);
    }

    function _assertUnit(uint256 tokenId) private view {
        binderStructs.NFTMetadata memory unit = data.getNFTDetails(tokenId);
        binderStructs.ClassConfig memory cfg = life.getClassConfig(unit.classId);
        uint256 base;
        uint256 allocated;
        for (uint256 i; i < 8; ++i) {
            assertGe(unit.staticStats.stats[i], cfg.minStats[i]);
            assertLe(unit.staticStats.stats[i], cfg.maxStats[i]);
            base += cfg.minStats[i];
            allocated += unit.staticStats.stats[i];
        }
        assertEq(allocated, base + cfg.totalPoints);
        assertEq(unit.dynamicStats.maxHP, uint16(unit.staticStats.stats[4]) * cfg.hpPerVit);
        assertEq(unit.dynamicStats.currentHP, unit.dynamicStats.maxHP);
        assertEq(unit.dynamicStats.maxMP, uint16(unit.staticStats.stats[5]) * cfg.mpPerWis);
        assertEq(unit.dynamicStats.currentMP, unit.dynamicStats.maxMP);
        assertTrue(data.getUnitState(tokenId).readyToArm);
    }

    function _reportUnit(uint256 tokenId) private {
        binderStructs.NFTMetadata memory unit = data.getNFTDetails(tokenId);
        emit log_named_string("Unit", unit.name);
        emit log_named_uint("Class ID", unit.classId);
        string[8] memory labels = ["STR", "INT", "AGI", "DEX", "VIT", "WIS", "SPD", "STA"];
        for (uint256 i; i < 8; ++i) {
            emit log_named_uint(labels[i], unit.staticStats.stats[i]);
        }
        emit log_named_uint("HP", unit.dynamicStats.currentHP);
        emit log_named_uint("MP", unit.dynamicStats.currentMP);
        emit log_named_address("Counterfactual TBA", inventory.accountOf(tokenId));
    }

    function _occupied(uint256 binderId) private view returns (uint256 count) {
        InventorySlot[20] memory slots = inventory.getSlots(binderId);
        for (uint256 i; i < 20; ++i) {
            if (slots[i].occupied) ++count;
        }
    }
}
