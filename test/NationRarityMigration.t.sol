// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../modular/AllegianceRegistry.sol";
import "../modular/Book0fLife.sol";
import "../modular/BinderLogic.sol";
import "../modular/supportContract/binderStructs.sol";

interface IEntropyCallbackHarness {
    function _entropyCallback(uint64 sequenceNumber, address providerAddress, bytes32 randomNumber) external;
}

contract MockEntropyForBinder {
    uint64 public nextSequenceNumber = 1;

    function getFeeV2(address, uint32) external pure returns (uint256) {
        return 0;
    }

    function requestV2(address, bytes32, uint32) external returns (uint64 sequenceNumber) {
        sequenceNumber = nextSequenceNumber++;
    }

    function fulfill(address consumer, uint64 sequenceNumber, address provider, bytes32 randomNumber) external {
        IEntropyCallbackHarness(consumer)._entropyCallback(sequenceNumber, provider, randomNumber);
    }
}

contract MockBinderDataForMint {
    address public lastRecipient;
    uint256 public lastClassId;
    uint8 public lastRarityId;
    string public lastRarityName;

    function _mintRandomNFT(
        address recipient,
        uint256 classId,
        string calldata,
        uint8 rarityId,
        string calldata rarityName,
        binderStructs.StaticStats calldata,
        binderStructs.DynamicStats calldata
    ) external returns (uint256) {
        lastRecipient = recipient;
        lastClassId = classId;
        lastRarityId = rarityId;
        lastRarityName = rarityName;
        return 1;
    }
}

contract NationRarityMigrationTest is Test {
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant PROVIDER = address(0xBEEF);

    AllegianceRegistry internal registry;
    Book0fLife internal book;

    function setUp() public {
        registry = new AllegianceRegistry(address(this));
        book = new Book0fLife();
        book.setAllegianceRegistry(address(registry));
        book.registerRarity(1, "Common");
        book.registerRarity(2, "Uncommon");
        book.registerRarity(3, "Rare");
    }

    function testInitialNationsAndFirstJoinCooldownSnapshot() public {
        assertTrue(registry.isNationActive(1));
        assertEq(registry.getNationName(1), "Weatonia");
        assertEq(registry.getNationName(2), "Mitrevar");
        assertEq(registry.getNationName(3), "Urtaka");
        assertEq(registry.getPlayerNation(ALICE), 0);

        uint48 joinedAt = uint48(block.timestamp + 29 days);
        vm.prank(ALICE);
        registry.joinNation(2);
        assertEq(registry.getPlayerNation(ALICE), 2);
        assertEq(registry.getNextAllegianceChangeAt(ALICE), joinedAt);

        registry.setAllegianceCooldown(14 days);
        assertEq(registry.getNextAllegianceChangeAt(ALICE), joinedAt);
        vm.warp(joinedAt);
        vm.prank(ALICE);
        registry.changeAllegiance(1);
        assertEq(registry.getPlayerNation(ALICE), 1);
        assertEq(registry.getNextAllegianceChangeAt(ALICE), uint48(block.timestamp + 14 days));
    }

    function testNationRegistrationAndSymmetricRelations() public {
        registry.registerNation(4, "Listhar");
        assertTrue(registry.isNationActive(4));
        assertEq(registry.getNationName(4), "Listhar");

        registry.setNationRelation(1, 4, registry.RELATION_HOSTILE());
        assertEq(registry.getNationRelation(1, 4), registry.RELATION_HOSTILE());
        assertEq(registry.getNationRelation(4, 1), registry.RELATION_HOSTILE());
        assertEq(registry.getNationRelation(1, 1), registry.RELATION_FRIENDLY());
    }

    function testGeneralAndSpecificPoolsAreExclusiveAndRarityReindexes() public {
        _addClass(1, 1);
        _addClass(2, 1);
        book.assignClassToNation(1, 0);

        vm.expectRevert(abi.encodeWithSelector(Book0fLife.GeneralMembershipConflict.selector, 1));
        book.assignClassToNation(1, 1);

        book.assignClassToNation(2, 1);
        book.assignClassToNation(2, 2);
        book.setClassRarityId(2, 2);

        assertEq(book.getClassesByNationRarity(1, 1).length, 0);
        assertEq(book.getClassesByNationRarity(2, 1).length, 0);
        assertEq(book.getClassesByNationRarity(1, 2)[0], 2);
        assertEq(book.getClassesByNationRarity(2, 2)[0], 2);
        uint8[] memory nations = book.getClassNations(2);
        assertEq(nations.length, 2);
    }

    function testEventMintWindowAndNationRotation() public {
        _addClass(1, 1);
        book.setClassAcquisitionFlags(1, book.ACQ_EVENT_MINT());
        book.assignClassToNation(1, 0);

        binderStructs.EventMintSchedule memory schedule =
            binderStructs.EventMintSchedule({enabled: true, startTime: 100, endTime: 200, slotDuration: 0});
        book.setEventMintSchedule(1, schedule);
        vm.warp(99);
        assertFalse(book.isClassMintEligible(1, 0));
        vm.warp(100);
        assertTrue(book.isClassMintEligible(1, 0));
        vm.warp(200);
        assertFalse(book.isClassMintEligible(1, 0));

        schedule.endTime = 0;
        schedule.slotDuration = 1 days;
        book.setEventMintSchedule(1, schedule);
        uint8[] memory rotation = new uint8[](2);
        rotation[0] = 1;
        rotation[1] = 2;
        book.setEventNationRotation(1, rotation);
        vm.warp(100);
        assertTrue(book.isClassMintEligible(1, 1));
        assertFalse(book.isClassMintEligible(1, 2));
        vm.warp(100 + 1 days);
        assertTrue(book.isClassMintEligible(1, 2));
        assertFalse(book.isClassMintEligible(1, 0));
    }

    function testUnregisteredMintSnapshotsGeneralOnlyEvenIfPlayerJoinsBeforeCallback() public {
        _addClass(1, 1);
        _addClass(2, 1);
        _addClass(3, 1);
        book.setClassAcquisitionFlags(1, book.ACQ_NORMAL_MINT());
        book.setClassAcquisitionFlags(2, book.ACQ_NORMAL_MINT());
        book.setClassAcquisitionFlags(3, book.ACQ_NORMAL_MINT());
        book.assignClassToNation(1, 0);
        book.assignClassToNation(2, 1);
        book.assignClassToNation(3, 2);

        MockEntropyForBinder entropy = new MockEntropyForBinder();
        MockBinderDataForMint binderData = new MockBinderDataForMint();
        BinderLogic logic = new BinderLogic(
            address(entropy), PROVIDER, address(binderData), address(book), address(registry), address(this)
        );
        logic.setMintPrice(0);
        uint8[] memory rarityIds = new uint8[](1);
        uint16[] memory chances = new uint16[](1);
        rarityIds[0] = 1;
        chances[0] = 10_000;
        logic.setRarityDistribution(rarityIds, chances);

        vm.prank(ALICE);
        logic.requestMint(bytes32(uint256(123)));
        (address recipient, uint8 nationId) = logic.getMintRequest(1);
        assertEq(recipient, ALICE);
        assertEq(nationId, 0);

        vm.prank(ALICE);
        registry.joinNation(1);
        entropy.fulfill(address(logic), 1, PROVIDER, bytes32(uint256(456)));

        assertEq(binderData.lastRecipient(), ALICE);
        assertEq(binderData.lastClassId(), 1);
        assertEq(binderData.lastRarityId(), 1);
        assertEq(binderData.lastRarityName(), "Common");
        (recipient, nationId) = logic.getMintRequest(1);
        assertEq(recipient, address(0));
        assertEq(nationId, 0);
    }

    function _addClass(uint256 classId, uint8 rarityId) internal {
        uint8[8] memory minStats = [uint8(1), 1, 1, 1, 1, 1, 1, 1];
        uint8[8] memory maxStats = [uint8(2), 2, 2, 2, 2, 2, 2, 2];
        binderStructs.ClassConfig memory config = binderStructs.ClassConfig({
            minStats: minStats,
            maxStats: maxStats,
            totalPoints: 4,
            hpPerVit: 10,
            mpPerWis: 10
        });
        book.addNewClass(classId, string.concat("Class", vm.toString(classId)), rarityId, config, 1);
    }
}
