// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {BattleFactory} from "../modular/Battle/BattleFactory.sol";
import {BattleProxy} from "../modular/Battle/BattleProxy.sol";
import {BinderData} from "../modular/BinderData.sol";
import {ItemStatsView} from "../modular/Items/ItemStatsView.sol";
import {IItemStatsView} from "../modular/interfaces/IItemStatsView.sol";
import {IBinderData} from "../modular/interfaces/IBinderData.sol";
import {Book0fArts} from "../modular/shelf/Book0fArts.sol";
import {Book0fItems} from "../modular/shelf/Book0fItems.sol";
import {Book0fRealms} from "../modular/shelf/Book0fRealms.sol";
import {IBattleFactory} from "../modular/interfaces/IBattleFactory.sol";
import {IBook0fItems} from "../modular/interfaces/IBook0fItems.sol";
import {
    EquipmentSlot,
    InventorySlot,
    ItemFamily,
    ItemEffect,
    ItemEffectKind,
    ItemTarget,
    ItemUseScope,
    SItemCategory,
    SItemConfig
} from "../modular/Items/ItemStruct.sol";
import {BinderIds} from "../modular/supportContract/binderIds.sol";
import {binderStructs} from "../modular/supportContract/binderStructs.sol";

contract BattleItemConsoleMock {
    address public binderData;
    address public binderSkills;
    address public book0fArts;
    address public book0fRealms;
    address public binderInventory;
    address public battleFactory;

    function configure(address data, address skills, address arts, address realms, address inventory, address factory)
        external
    {
        binderData = data;
        binderSkills = skills;
        book0fArts = arts;
        book0fRealms = realms;
        binderInventory = inventory;
        battleFactory = factory;
    }
}

contract BattleItemSkillsMock {
    function hasActiveSkill(uint256, uint32) external pure returns (bool) {
        return true;
    }

    function hasPassiveSkill(uint256, uint32) external pure returns (bool) {
        return false;
    }

    function getMoveSets(uint256) external pure returns (uint32[3] memory moves) {
        return moves;
    }

    function getLearnedArtVersion(uint256, uint32) external pure returns (uint16) {
        return 1;
    }
}

contract BattlePermanentStatsMock is IItemStatsView {
    IBinderData public immutable binderData;

    constructor(address dataAddress) {
        binderData = IBinderData(dataAddress);
    }

    function statsWithGrowth(uint256) external pure returns (uint32[8] memory stats) {
        stats = [uint32(100_000), 10, 10, 10, 10, 10, 10, 10];
    }
}

contract BattleItemInventoryMock {
    IBook0fItems public immutable book;
    IItemStatsView public statsView;
    address public factory;
    mapping(uint256 => InventorySlot[20]) private _slots;

    error UnauthorizedProxy(address caller);
    error InvalidConsumption();

    constructor(address bookAddress, address dataAddress) {
        book = IBook0fItems(bookAddress);
        statsView = new ItemStatsView(dataAddress);
    }

    function setFactory(address factoryAddress) external {
        factory = factoryAddress;
    }

    function setStatsView(IItemStatsView viewAddress) external {
        statsView = viewAddress;
    }

    function setSItem(uint256 binderId, uint8 slot, uint16 sItemId, uint128 amount) external {
        _slots[binderId][slot] = InventorySlot({
            family: ItemFamily.SITEM,
            libraryId: sItemId,
            instanceTokenId: 0,
            amount: amount,
            occupied: true,
            equipped: false,
            equippedAs: EquipmentSlot.HEADGEAR
        });
    }

    function getSlot(uint256 binderId, uint8 slot) external view returns (InventorySlot memory) {
        return _slots[binderId][slot];
    }

    function getSlots(uint256 binderId) external view returns (InventorySlot[20] memory) {
        return _slots[binderId];
    }

    function consumeSItemForBattle(uint256 binderId, uint8 slot, uint128 amount) external returns (uint16 sItemId) {
        if (!IBattleFactory(factory).isBattleProxy(msg.sender)) revert UnauthorizedProxy(msg.sender);
        InventorySlot storage item = _slots[binderId][slot];
        if (!item.occupied || item.family != ItemFamily.SITEM || item.amount < amount || amount == 0) {
            revert InvalidConsumption();
        }
        sItemId = item.libraryId;
        item.amount -= amount;
        if (item.amount == 0) delete _slots[binderId][slot];
    }
}

contract BattleItemRouteTest is Test {
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);

    BinderData private data;
    Book0fItems private itemBook;
    BattleItemInventoryMock private inventory;
    BattleFactory private factory;

    function setUp() public {
        BattleItemConsoleMock registry = new BattleItemConsoleMock();
        data = new BinderData(address(this), "");
        data.setAuthorizedBinderLogic(address(this), true);
        data.setClassVersion(1, 1);

        Book0fArts arts = new Book0fArts(address(this));
        arts.addArt(_art(), new uint256[](0));
        Book0fRealms realms = new Book0fRealms(address(this));
        realms.addMap(_map(), _tiles());
        BattleItemSkillsMock skills = new BattleItemSkillsMock();
        itemBook = new Book0fItems(address(registry), address(this), address(arts));
        itemBook.addSItem(_battleConsumable());
        itemBook.addSItem(_unsupportedObject());
        inventory = new BattleItemInventoryMock(address(itemBook), address(data));

        BattleProxy implementation = new BattleProxy();
        factory = new BattleFactory(address(this), address(registry), address(implementation));
        registry.configure(
            address(data), address(skills), address(arts), address(realms), address(inventory), address(factory)
        );
        inventory.setFactory(address(factory));
        data.setActivityController(BinderIds.ACTIVITY_BATTLE, address(factory));
        data.setAuthorizedBattleFactory(address(factory), true);

        _mint(1, ALICE);
        _mint(2, BOB);
        inventory.setSItem(1, 0, 1, 1);
        inventory.setSItem(1, 1, 2, 1);
    }

    function testBattleSnapshotsWideGrowthWithoutChangingBaseStats() public {
        inventory.setStatsView(new BattlePermanentStatsMock(address(data)));
        BattleProxy battle = _createBattle();
        inventory.setStatsView(new ItemStatsView(address(data)));
        vm.prank(ALICE);
        battle.useArt(1, 1, 2);
        assertEq(battle.getBattleUnit(2).currentHP, 0);
        assertEq(battle.getBattleUnit(1).baseStats[0], 10);
        assertEq(data.getNFTDetails(1).staticStats.stats[0], 10);
    }

    function testOfficialProxyConsumesAtomicallyAndAppliesTypedBattleEffects() public {
        BattleProxy battle = _createBattle();
        vm.prank(ALICE);
        battle.useItem(1, 0, 1, 1);

        assertEq(battle.getBattleUnit(1).currentHP, 100);
        int32[8] memory modifiers = battle.getTemporaryModifiers(1);
        assertEq(modifiers[BinderIds.STAT_STR], 2);
        assertTrue(battle.isAilmentActive(1, 1));
        assertEq(inventory.getSlot(1, 0).amount, 0);
        assertEq(battle.actionNumber(), 1);

        vm.warp(block.timestamp + 31);
        assertFalse(battle.isAilmentActive(1, 1));
        modifiers = battle.getTemporaryModifiers(1);
        assertEq(modifiers[BinderIds.STAT_STR], 0);
    }

    function testUnsupportedBattleObjectDoesNotConsumeItem() public {
        BattleProxy battle = _createBattle();
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(BattleProxy.BattleObjectsUnsupported.selector, uint32(77)));
        battle.useItem(1, 1, 1, 1);
        assertEq(inventory.getSlot(1, 1).amount, 1);
    }

    function testTemporaryModifierAppliesToTheConfiguredTarget() public {
        SItemConfig memory cfg = _battleConsumable();
        for (uint256 i; i < cfg.effectCount; ++i) {
            cfg.effects[i].target = ItemTarget.ENEMY;
        }
        itemBook.updateSItem(1, cfg);
        BattleProxy battle = _createBattle();
        vm.prank(ALICE);
        battle.useItem(1, 0, 1, 2);
        assertEq(battle.getTemporaryModifiers(1)[BinderIds.STAT_STR], 0);
        assertEq(battle.getTemporaryModifiers(2)[BinderIds.STAT_STR], 2);
        assertEq(battle.getBattleUnit(2).currentHP, 100);
        assertTrue(battle.isAilmentActive(2, 1));
    }

    function _createBattle() private returns (BattleProxy battle) {
        vm.startPrank(ALICE);
        data.approve(address(factory), 1);
        uint256 invitationId = factory.createBattleInvitation(BOB, 1, uint48(block.timestamp + 1 hours), _party(1, 1));
        vm.stopPrank();
        vm.startPrank(BOB);
        data.approve(address(factory), 2);
        battle = BattleProxy(factory.acceptBattleInvitation(invitationId, _party(2, 2)));
        vm.stopPrank();
    }

    function _party(uint256 binderId, uint16 tileId)
        private
        pure
        returns (BattleFactory.PartySubmission memory party)
    {
        party.tokenIds = new uint256[](1);
        party.tokenIds[0] = binderId;
        party.spawnTileIds = new uint16[](1);
        party.spawnTileIds[0] = tileId;
        party.selectedArtIds = new uint32[][](1);
        party.selectedArtIds[0] = new uint32[](1);
        party.selectedArtIds[0][0] = 1;
    }

    function _mint(uint256 ignoredTokenId, address owner) private {
        uint8[8] memory values = [uint8(10), 10, 10, 10, 10, 10, 10, 10];
        binderStructs.StaticStats memory staticStats = binderStructs.StaticStats({stats: values});
        binderStructs.DynamicStats memory dynamicStats =
            binderStructs.DynamicStats({maxHP: 100, maxMP: 50, currentHP: 90, currentMP: 50});
        data._mintRandomNFT(owner, 1, "Fighter", 1, "Common", staticStats, dynamicStats);
        ignoredTokenId;
    }

    function _battleConsumable() private pure returns (SItemConfig memory cfg) {
        cfg.enabled = true;
        cfg.itemName = "Battle Tonic";
        cfg.category = SItemCategory.CONSUMABLE;
        cfg.maximumStack = 10;
        cfg.effectCount = 3;
        cfg.effects[0] = ItemEffect({
            kind: ItemEffectKind.MODIFY_CUR_HP,
            scope: ItemUseScope.BATTLE_ONLY,
            target: ItemTarget.SELF,
            refId: 0,
            amount: 20,
            statDelta: [int16(0), 0, 0, 0, 0, 0, 0, 0],
            durationSeconds: 0
        });
        cfg.effects[1] = ItemEffect({
            kind: ItemEffectKind.TEMP_STAT_DELTA,
            scope: ItemUseScope.BATTLE_ONLY,
            target: ItemTarget.SELF,
            refId: 0,
            amount: 0,
            statDelta: [int16(2), 0, 0, 0, 0, 0, 0, 0],
            durationSeconds: 30
        });
        cfg.effects[2] = ItemEffect({
            kind: ItemEffectKind.APPLY_AILMENT,
            scope: ItemUseScope.BATTLE_ONLY,
            target: ItemTarget.SELF,
            refId: 1,
            amount: 0,
            statDelta: [int16(0), 0, 0, 0, 0, 0, 0, 0],
            durationSeconds: 30
        });
    }

    function _unsupportedObject() private pure returns (SItemConfig memory cfg) {
        cfg.enabled = true;
        cfg.itemName = "Future Trap";
        cfg.category = SItemCategory.BATTLE_OBJECT;
        cfg.maximumStack = 1;
        cfg.effectCount = 1;
        cfg.effects[0] = ItemEffect({
            kind: ItemEffectKind.PLACE_BATTLE_OBJECT,
            scope: ItemUseScope.BATTLE_ONLY,
            target: ItemTarget.TILE,
            refId: 77,
            amount: 0,
            statDelta: [int16(0), 0, 0, 0, 0, 0, 0, 0],
            durationSeconds: 0
        });
    }

    function _art() private pure returns (binderStructs.ArtDefinition memory definition) {
        definition.artId = 1;
        definition.name = "Strike";
        definition.artTypeId = BinderIds.ART_TYPE_ACTIVE;
        definition.effectTypeId = BinderIds.EFFECT_TYPE_DAMAGE;
        definition.patternTypeId = BinderIds.PATTERN_TYPE_SINGLE;
        definition.range = 1;
        definition.primaryFormula.termCount = 1;
        definition.primaryFormula.terms[0] = binderStructs.FormulaTerm({
            sourceId: BinderIds.FORMULA_SOURCE_ACTOR,
            statId: BinderIds.STAT_STR,
            coefficientBps: 10_000
        });
        definition.version = 1;
        definition.enabled = true;
    }

    function _map() private pure returns (binderStructs.MapDefinition memory) {
        return binderStructs.MapDefinition({mapId: 1, name: "Arena", width: 2, height: 1, version: 1, enabled: true});
    }

    function _tiles() private pure returns (binderStructs.TileDefinition[] memory tiles) {
        tiles = new binderStructs.TileDefinition[](2);
        for (uint16 tileId = 1; tileId <= 2; ++tileId) {
            tiles[tileId - 1] = binderStructs.TileDefinition({
                tileId: tileId,
                elevation: 0,
                terrainTypeId: 1,
                terrainFlags: 0,
                walkable: true,
                movementCost: 1
            });
        }
    }
}
