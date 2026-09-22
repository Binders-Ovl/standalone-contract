// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {CentralConsole} from "../modular/supportContract/CentralConsole.sol";
import {Book0fArts} from "../modular/shelf/Book0fArts.sol";
import {Book0fItems} from "../modular/shelf/Book0fItems.sol";
import {ScaleOfBalance} from "../modular/ScaleOfBalance.sol";
import {ItemBookConfigurator} from "../modular/supportContract/ItemBookConfigurator.sol";
import {EqConfig, TomeConfig, SItemConfig, SItemCategory} from "../modular/Items/ItemStruct.sol";
import {binderStructs} from "../modular/supportContract/binderStructs.sol";
import {BinderIds} from "../modular/supportContract/binderIds.sol";

contract ItemWiringBinderDataMock {
    address public previousRouter;
    address public router;

    function setItemUseRouter(address previous, address next) external {
        previousRouter = previous;
        router = next;
    }

    function setMetadataRefreshModule(address, address) external {}
}

contract ItemWiringSkillsMock {
    address public immutable binderData;
    address public centralConsole;
    address public book0fItems;
    address public binderInventory;

    constructor(address data) {
        binderData = data;
    }

    function setCentralConsole(address next) external {
        centralConsole = next;
    }

    function setTomeLearningDependencies(address book, address inventory, address, address) external {
        book0fItems = book;
        binderInventory = inventory;
    }
}

contract ItemWiringInventoryMock {
    address public immutable centralConsole;
    address public immutable binderData;
    address public immutable book;
    address public equipment;
    address public tomes;
    address public sItems;
    address public stats;
    address public skills;
    address public router;

    constructor(address consoleAddress, address data, address itemsBook) {
        centralConsole = consoleAddress;
        binderData = data;
        book = itemsBook;
    }

    function setCollections(address eq, address tome, address sitem) external {
        equipment = eq;
        tomes = tome;
        sItems = sitem;
    }

    function setStatsView(address next) external {
        stats = next;
    }

    function setBinderSkills(address next) external {
        skills = next;
    }

    function setItemUseRouter(address next) external {
        router = next;
    }
}

contract ItemWiringCollectionMock {
    address public immutable owner;
    address public inventory;
    address public issuer;
    bool public issuerAllowed;

    constructor(address consoleAddress) {
        owner = consoleAddress;
    }

    function setInventory(address next) external {
        inventory = next;
    }

    function setIssuer(address next, bool allowed) external {
        issuer = next;
        issuerAllowed = allowed;
    }

    function setTransferValidator(address) external {}
    function configureTransferRuleset(uint8, address, uint8, uint16) external {}
    function applyTransferList(uint48) external {}
    function setBaseImageURI(string calldata) external {}
    function setImageURI(uint16, string calldata) external {}

    function getTransferValidator() external pure returns (address) {
        return address(0);
    }
}

contract ItemWiringRouterMock {
    address public immutable binderData;
    address public immutable book;
    address public immutable inventory;

    constructor(address data, address itemsBook, address inventory_) {
        binderData = data;
        book = itemsBook;
        inventory = inventory_;
    }
}

contract ItemWiringStatsMock {
    address public immutable binderData;

    constructor(address data) {
        binderData = data;
    }
}

contract ItemWiringMetadataMock {}

contract ItemConsoleWiringTest is Test {
    function testConsoleAtomicallyWiresTheFixedItemGraph() public {
        ItemWiringBinderDataMock data = new ItemWiringBinderDataMock();
        CentralConsole registry = new CentralConsole(address(this), address(data));
        ItemWiringSkillsMock skills = new ItemWiringSkillsMock(address(data));
        registry.setBinderSkills(address(skills));

        Book0fArts arts = new Book0fArts(address(this));
        registry.setBook0fArts(address(arts));
        Book0fItems itemsBook = new Book0fItems(address(registry), address(this), address(arts));
        ItemWiringInventoryMock inventory =
            new ItemWiringInventoryMock(address(registry), address(data), address(itemsBook));
        ItemWiringCollectionMock equipment = new ItemWiringCollectionMock(address(registry));
        ItemWiringCollectionMock tomes = new ItemWiringCollectionMock(address(registry));
        ItemWiringCollectionMock sItems = new ItemWiringCollectionMock(address(registry));
        ItemWiringRouterMock router = new ItemWiringRouterMock(address(data), address(itemsBook), address(inventory));
        ItemWiringMetadataMock metadata = new ItemWiringMetadataMock();
        ItemWiringStatsMock stats = new ItemWiringStatsMock(address(data));

        registry.configureItemSystem(
            address(itemsBook),
            address(inventory),
            address(equipment),
            address(tomes),
            address(sItems),
            address(router),
            address(metadata),
            address(stats),
            address(0),
            address(0)
        );

        assertEq(registry.binderInventory(), address(inventory));
        assertEq(equipment.inventory(), address(inventory));
        assertEq(data.router(), address(router));
        assertEq(skills.book0fItems(), address(itemsBook));
        registry.setItemIssuer(address(sItems), address(0xB0B), true);
        assertEq(sItems.issuer(), address(0xB0B));
        assertTrue(sItems.issuerAllowed());
        CentralConsole.ItemWiringStatus memory status = registry.getItemWiringStatus();
        assertTrue(status.bookAuthorityMatch);
        assertTrue(status.inventoryDependenciesMatch);
        assertTrue(status.collectionsMatch);
        assertTrue(status.collectionOwnershipMatch);
        assertTrue(status.routerDependenciesMatch);
        assertTrue(status.skillsDependenciesMatch);
        _exerciseConfigRoutes(registry, itemsBook, arts);
    }

    function testScaleCanConfigureItemsThroughTheSameTypedRoutes() public {
        ScaleOfBalance scale = new ScaleOfBalance(address(this), address(this));
        Book0fArts arts = new Book0fArts(address(this));
        Book0fItems book = new Book0fItems(address(this), address(scale), address(arts));
        scale.setBook0fItems(address(book));
        _exerciseConfigRoutes(scale, book, arts);
    }

    function _exerciseConfigRoutes(ItemBookConfigurator authority, Book0fItems book, Book0fArts arts) private {
        binderStructs.ArtDefinition memory art;
        art.artId = 1;
        art.name = "Item Art";
        art.artTypeId = BinderIds.ART_TYPE_ACTIVE;
        art.effectTypeId = BinderIds.EFFECT_TYPE_HEAL;
        art.patternTypeId = BinderIds.PATTERN_TYPE_SELF;
        art.version = 1;
        art.enabled = true;
        arts.addArt(art, new uint256[](0));
        EqConfig memory eq;
        eq.enabled = true;
        eq.itemName = "Equipment";
        TomeConfig memory tome;
        tome.enabled = true;
        tome.itemName = "Tome";
        tome.artId = 1;
        tome.learnSuccessBps = 10_000;
        SItemConfig memory item;
        item.enabled = true;
        item.itemName = "Material";
        item.category = SItemCategory.MATERIAL;
        item.maximumStack = 99;

        vm.startPrank(address(0xBAD));
        vm.expectRevert();
        authority.addEq(eq);
        vm.expectRevert();
        authority.addTome(tome);
        vm.expectRevert();
        authority.addSItem(item);
        vm.stopPrank();
        assertEq(authority.addEq(eq), 1);
        assertEq(authority.addTome(tome), 1);
        assertEq(authority.addSItem(item), 1);
        authority.updateEq(1, eq);
        authority.updateTome(1, tome);
        authority.updateSItem(1, item);
        authority.deactivateEq(1);
        authority.deactivateTome(1);
        authority.deactivateSItem(1);
        assertFalse(book.isEqEnabled(1));
        assertFalse(book.isTomeEnabled(1));
        assertFalse(book.isSItemEnabled(1));
        assertEq(book.getEq(1).configVersion, 3);
        assertEq(book.getTome(1).configVersion, 3);
        assertEq(book.getSItem(1).configVersion, 3);
    }
}
