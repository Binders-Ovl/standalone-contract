// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Book0fArts} from "../modular/shelf/Book0fArts.sol";
import {Book0fItems} from "../modular/shelf/Book0fItems.sol";
import {Equipment} from "../modular/Items/Equipment.sol";
import {ItemCollectionBase} from "../modular/Items/ItemCollectionBase.sol";
import {TomeAndGrimoires} from "../modular/Items/TomeAndGrimoires.sol";
import {SItems} from "../modular/Items/SItems.sol";
import {ItemMetadataBuilder} from "../modular/Items/ItemMetadataBuilder.sol";
import {EqConfig, TomeConfig, SItemConfig, EquipmentSlot, SItemCategory} from "../modular/Items/ItemStruct.sol";
import {binderStructs} from "../modular/supportContract/binderStructs.sol";
import {BinderIds} from "../modular/supportContract/binderIds.sol";

contract ItemCollectionInventoryMock {
    address internal immutable _account;
    uint256 public preparedEquipment;
    uint256 public preparedTome;
    uint128 public preparedSItemAmount;

    constructor(address account) {
        _account = account;
    }

    function isBinderAccount(address account) external view returns (bool) {
        return account == _account;
    }

    function prepareEquipmentMint(uint256, uint16, uint256 tokenId) external returns (address) {
        preparedEquipment = tokenId;
        return _account;
    }

    function prepareTomeMint(uint256, uint16, uint256 tokenId) external returns (address) {
        preparedTome = tokenId;
        return _account;
    }

    function prepareSItemMint(uint256, uint16, uint128 amount) external returns (address) {
        preparedSItemAmount = amount;
        return _account;
    }
}

/// @notice Verifies the controlled collection routes without a private validator clone.
contract ItemCollectionsTest is Test {
    address private constant ALICE = address(0xA11CE);
    address private constant BINDER_ACCOUNT = address(0xB1DDE);

    Book0fItems private book;
    Equipment private equipment;
    TomeAndGrimoires private tomes;
    SItems private sItems;
    ItemCollectionInventoryMock private inventory;

    function setUp() public {
        Book0fArts arts = new Book0fArts(address(this));
        arts.addArt(_art(), new uint256[](0));
        book = new Book0fItems(address(this), address(this), address(arts));
        book.addEq(_eq());
        book.addTome(_tome());
        book.addSItem(_sItem());
        ItemMetadataBuilder metadata = new ItemMetadataBuilder();
        inventory = new ItemCollectionInventoryMock(BINDER_ACCOUNT);
        equipment = new Equipment(address(this), address(0), address(book), address(metadata));
        tomes = new TomeAndGrimoires(address(this), address(0), address(book), address(metadata));
        sItems = new SItems(address(this), address(0), address(book), address(metadata));
        equipment.setIssuer(address(this), true);
        tomes.setIssuer(address(this), true);
        sItems.setIssuer(address(this), true);
        equipment.setInventory(address(inventory));
        tomes.setInventory(address(inventory));
        sItems.setInventory(address(inventory));
    }

    function testMintRoutesPreserveLibraryIdsAndMetadata() public {
        uint256 eqToken = equipment.mintToWallet(ALICE, 1, bytes32("wallet"));
        assertEq(equipment.eqIdOf(eqToken), 1);
        assertEq(equipment.ownerOf(eqToken), ALICE);
        assertTrue(bytes(equipment.tokenURI(eqToken)).length > 0);

        uint256 tomeToken = tomes.mintToBinder(7, 1, bytes32("binder"));
        assertEq(tomes.ownerOf(tomeToken), BINDER_ACCOUNT);
        assertEq(inventory.preparedTome(), tomeToken);
        sItems.mintToBinder(7, 1, 100, bytes32("binder"));
        assertEq(sItems.balanceOf(BINDER_ACCOUNT, 1), 100);
        assertEq(inventory.preparedSItemAmount(), 100);
    }

    function testDirectBinderReceiptIsBlockedOutsideInventoryRoute() public {
        uint256 tokenId = equipment.mintToWallet(ALICE, 1, bytes32(0));
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(ItemCollectionBase.DirectBinderDepositBlocked.selector, BINDER_ACCOUNT));
        equipment.transferFrom(ALICE, BINDER_ACCOUNT, tokenId);
    }

    function testWalletMintCannotBypassBinderInventoryForAnyCollection() public {
        bytes memory reason =
            abi.encodeWithSelector(ItemCollectionBase.DirectBinderDepositBlocked.selector, BINDER_ACCOUNT);
        vm.expectRevert(reason);
        equipment.mintToWallet(BINDER_ACCOUNT, 1, bytes32(0));
        vm.expectRevert(reason);
        tomes.mintToWallet(BINDER_ACCOUNT, 1, bytes32(0));
        vm.expectRevert(reason);
        sItems.mintToWallet(BINDER_ACCOUNT, 1, 1, bytes32(0));
        assertEq(inventory.preparedEquipment(), 0);
        assertEq(inventory.preparedTome(), 0);
        assertEq(inventory.preparedSItemAmount(), 0);
    }

    function testSharedCollectionAuthorityRemainsOwnerOnly() public {
        address[3] memory collections = [address(equipment), address(tomes), address(sItems)];
        for (uint256 i; i < collections.length; ++i) {
            ItemCollectionBase collection = ItemCollectionBase(collections[i]);
            vm.startPrank(ALICE);
            vm.expectRevert();
            collection.setIssuer(ALICE, true);
            vm.expectRevert();
            collection.setInventory(ALICE);
            vm.expectRevert();
            collection.setBaseImageURI("ipfs://unauthorized");
            vm.expectRevert();
            collection.configureTransferRuleset(255, address(0), 0, 9);
            vm.stopPrank();
            assertFalse(collection.issuers(ALICE));
            assertEq(collection.inventory(), address(inventory));
        }
    }

    function _eq() private pure returns (EqConfig memory config) {
        config.enabled = true;
        config.itemName = "Helm";
        config.slot = EquipmentSlot.HEADGEAR;
    }

    function _art() private pure returns (binderStructs.ArtDefinition memory definition) {
        definition.artId = 1;
        definition.name = "Scroll Art";
        definition.artTypeId = BinderIds.ART_TYPE_ACTIVE;
        definition.effectTypeId = BinderIds.EFFECT_TYPE_HEAL;
        definition.patternTypeId = BinderIds.PATTERN_TYPE_SELF;
        definition.version = 1;
        definition.enabled = true;
    }

    function _tome() private pure returns (TomeConfig memory config) {
        config.enabled = true;
        config.itemName = "Tome";
        config.artId = 1;
        config.learnSuccessBps = 10_000;
    }

    function _sItem() private pure returns (SItemConfig memory config) {
        config.enabled = true;
        config.itemName = "Material";
        config.category = SItemCategory.MATERIAL;
        config.maximumStack = 99;
    }
}
