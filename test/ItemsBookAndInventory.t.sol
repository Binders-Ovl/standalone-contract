// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../modular/shelf/Book0fArts.sol";
import "../modular/shelf/Book0fItems.sol";
import "../modular/Items/BinderInventory.sol";
import "../modular/Items/ItemStruct.sol";
import "../modular/supportContract/binderStructs.sol";

contract ItemBookMockBinderData {
    address public battleProxy;

    function setBattleProxy(address proxy) external {
        battleProxy = proxy;
    }

    function activeBattleProxy(uint256) external view returns (address) {
        return battleProxy;
    }

    function ownerOf(uint256) external view returns (address) {
        return address(this);
    }

    function getUnitState(uint256) external pure returns (binderStructs.UnitStateView memory state) {
        state.idle = true;
        state.readyToArm = true;
    }

    function getNFTClass(uint256) external pure returns (uint256) {
        return 1;
    }

    function getNFTDetails(uint256) external pure returns (binderStructs.NFTMetadata memory details) {
        details.classId = 1;
        details.staticStats.stats = [uint8(10), 10, 10, 10, 10, 10, 10, 10];
    }
}

contract ItemBookMockBattleFactory {
    function isBattleProxy(address proxy) external view returns (bool) {
        return proxy == address(this);
    }
}

contract ItemBookMockRegistry {
    function account(address, bytes32, uint256, address, uint256 tokenId) external pure returns (address) {
        return address(uint160(tokenId + 0xB100));
    }

    function createAccount(address, bytes32, uint256, address, uint256 tokenId) external pure returns (address) {
        return address(uint160(tokenId + 0xB100));
    }
}

/// @notice Focused conservation check for Book namespaces and the 20-stack ledger.
contract ItemsBookAndInventoryTest is Test {
    Book0fArts private arts;
    Book0fItems private book;
    BinderInventory private inventory;
    ItemBookMockBinderData private data;
    ItemBookMockBattleFactory private factory;
    address public battleFactory;
    uint16 private burnedSItemId;
    uint128 private burnedAmount;

    function setUp() public {
        arts = new Book0fArts(address(this));
        book = new Book0fItems(address(this), address(this), address(arts));
        data = new ItemBookMockBinderData();
        factory = new ItemBookMockBattleFactory();
        battleFactory = address(factory);
        inventory = new BinderInventory(
            address(this),
            address(data),
            address(book),
            address(new ItemBookMockRegistry()),
            address(this),
            address(this)
        );
        // This test contract is the three narrow collection callers; no asset transfer is needed to test ledger capacity.
        inventory.setCollections(address(this), address(this), address(this));
    }

    function statsWithGrowth(uint256) external pure returns (uint16[8] memory stats) {
        stats = [uint16(10), 10, 10, 10, 10, 10, 10, 10];
    }

    function burnForProtocol(address, uint16 sItemId, uint128 amount) external {
        burnedSItemId = sItemId;
        burnedAmount = amount;
    }

    function testBookNamespacesVersioningAndBoundedInventory() public {
        uint256[] memory classes = new uint256[](1);
        classes[0] = 1;
        uint16 eqId = book.addEq(_eq(classes));
        assertEq(eqId, 1);
        EqConfig memory changed = _eq(classes);
        changed.itemName = "Updated Helm";
        book.updateEq(eqId, changed);
        assertEq(book.getEq(eqId).configVersion, 2);
        book.deactivateEq(eqId);
        assertFalse(book.isEqEnabled(eqId));

        for (uint16 id = 1; id <= 21; ++id) {
            assertEq(book.addSItem(_material(id)), id);
        }
        for (uint16 id = 1; id <= 20; ++id) {
            inventory.prepareSItemMint(1, id, 1);
        }
        assertTrue(inventory.hasInventory(1));
        assertEq(inventory.getSlot(1, 0).libraryId, 1);

        vm.expectRevert(abi.encodeWithSelector(BinderInventory.InventoryFull.selector, uint256(1)));
        inventory.prepareSItemMint(1, 21, 1);
        assertEq(inventory.getSlot(1, 19).libraryId, 20);
    }

    function testBookRejectsDuplicateClassEligibilityAndMaterialEffects() public {
        uint256[] memory duplicateClasses = new uint256[](2);
        duplicateClasses[0] = 1;
        duplicateClasses[1] = 1;
        vm.expectRevert(Book0fItems.InvalidItemConfig.selector);
        book.addEq(_eq(duplicateClasses));

        SItemConfig memory material = _material(1);
        material.effectCount = 1;
        material.effects[0].kind = ItemEffectKind.MODIFY_CUR_HP;
        material.effects[0].amount = 1;
        vm.expectRevert(Book0fItems.InvalidItemConfig.selector);
        book.addSItem(material);
    }

    function testStackSplitsAtConfiguredMaximum() public {
        book.addSItem(_material(1));
        inventory.prepareSItemMint(1, 1, 100);
        InventorySlot memory first = inventory.getSlot(1, 0);
        InventorySlot memory second = inventory.getSlot(1, 1);
        assertEq(first.amount, 99);
        assertEq(second.amount, 1);
        assertEq(first.libraryId, second.libraryId);
    }

    function testReducedStackLimitDoesNotUnderflowWhenAddingToExistingInventory() public {
        book.addSItem(_material(1));
        inventory.prepareSItemMint(1, 1, 99);
        SItemConfig memory reduced = _material(1);
        reduced.maximumStack = 10;
        book.updateSItem(1, reduced);
        inventory.prepareSItemMint(1, 1, 11);
        assertEq(inventory.getSlot(1, 0).amount, 99);
        assertEq(inventory.getSlot(1, 1).amount, 10);
        assertEq(inventory.getSlot(1, 2).amount, 1);
    }

    function testFuzzStackConservationAndAtomicOverflow(uint128 amount) public {
        amount = uint128(bound(amount, 1, 20 * 99));
        book.addSItem(_material(1));
        inventory.prepareSItemMint(1, 1, amount);
        InventorySlot[20] memory slots = inventory.getSlots(1);
        uint256 total;
        uint256 occupied;
        for (uint256 i; i < slots.length; ++i) {
            if (!slots[i].occupied) continue;
            assertGt(slots[i].amount, 0);
            assertLe(slots[i].amount, 99);
            total += slots[i].amount;
            ++occupied;
        }
        assertEq(total, amount);
        assertEq(occupied, (uint256(amount) + 98) / 99);
        vm.expectRevert(abi.encodeWithSelector(BinderInventory.InventoryFull.selector, uint256(1)));
        inventory.prepareSItemMint(1, 1, uint128(20 * 99 + 1 - amount));
        InventorySlot[20] memory afterSlots = inventory.getSlots(1);
        assertEq(keccak256(abi.encode(afterSlots)), keccak256(abi.encode(slots)));
    }

    function testOnlyOfficialBattleProxyCanConsumeAndBurnSItems() public {
        book.addSItem(_material(1));
        inventory.prepareSItemMint(1, 1, 2);
        data.setBattleProxy(address(factory));

        vm.prank(address(factory));
        assertEq(inventory.consumeSItemForBattle(1, 0, 1), 1);
        assertEq(inventory.getSlot(1, 0).amount, 1);
        assertEq(burnedSItemId, 1);
        assertEq(burnedAmount, 1);

        vm.prank(address(0xB0B));
        vm.expectRevert(abi.encodeWithSelector(BinderInventory.UnauthorizedBattleProxy.selector, address(0xB0B)));
        inventory.consumeSItemForBattle(1, 0, 1);
    }

    function _eq(uint256[] memory classes) private pure returns (EqConfig memory config) {
        config.itemName = "Helm";
        config.enabled = true;
        config.slot = EquipmentSlot.HEADGEAR;
        config.allowedClassIds = classes;
    }

    function _material(uint16) private pure returns (SItemConfig memory config) {
        config.itemName = "Material";
        config.enabled = true;
        config.category = SItemCategory.MATERIAL;
        config.maximumStack = 99;
    }
}
