// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../modular/AllegianceRegistry.sol";
import "../modular/BinderData.sol";
import "../modular/BinderLogic.sol";
import "../modular/Book0fLife.sol";
import "../modular/supportContract/CentralConsole.sol";
import "../modular/supportContract/binderStructs.sol";

interface IEntropyCallbackTarget {
    function _entropyCallback(uint64 sequenceNumber, address providerAddress, bytes32 randomNumber) external;
}

contract LifecycleEntropyMock {
    uint64 internal _nextSequence = 1;

    function getFeeV2(address, uint32) external pure returns (uint256) {
        return 0;
    }

    function requestV2(address, bytes32, uint32) external returns (uint64 sequenceNumber) {
        sequenceNumber = _nextSequence++;
    }

    function fulfill(BinderLogic logic, uint64 sequenceNumber, address providerAddress, bytes32 randomNumber)
        external
    {
        IEntropyCallbackTarget(address(logic))._entropyCallback(sequenceNumber, providerAddress, randomNumber);
    }
}

contract BinderLogicLifecycleTest is Test {
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant PROVIDER = address(0xBEEF);

    BinderData internal binderData;
    Book0fLife internal book;
    AllegianceRegistry internal registry;
    CentralConsole internal centralConsole;
    LifecycleEntropyMock internal entropy;
    BinderLogic internal oldLogic;

    function setUp() public {
        binderData = new BinderData(address(this), "");
        centralConsole = new CentralConsole(address(this), address(binderData));
        binderData.grantRole(binderData.CONFIG_ROLE(), address(centralConsole));

        book = new Book0fLife();
        book.grantRole(book.CONFIG_ROLE(), address(centralConsole));
        book.registerRarity(1, "Common");
        uint8[8] memory minimums = [uint8(1), 1, 1, 1, 1, 1, 1, 1];
        uint8[8] memory maximums = [uint8(3), 3, 3, 3, 3, 3, 3, 3];
        book.addNewClass(
            1,
            "Villager",
            1,
            binderStructs.ClassConfig({
                minStats: minimums,
                maxStats: maximums,
                totalPoints: 4,
                hpPerVit: 10,
                mpPerWis: 10
            }),
            1
        );
        book.setClassAcquisitionFlags(1, book.ACQ_NORMAL_MINT());
        book.assignClassToNation(1, 0);
        binderData.setClassVersion(1, 1);

        registry = new AllegianceRegistry(address(this));
        entropy = new LifecycleEntropyMock();
        centralConsole.setBook0fLife(address(book));
        centralConsole.setAllegianceRegistry(address(registry));

        oldLogic = _newLogic();
        centralConsole.setBinderLogic(address(oldLogic));
    }

    function testOutgoingLogicRejectsNewRequestsButCompletesRecordedCallbackAndRetires() public {
        vm.prank(ALICE);
        oldLogic.requestMint(bytes32(uint256(1)));
        assertEq(oldLogic.pendingMintCount(), 1);

        BinderLogic replacement = _newLogic();
        centralConsole.setBinderLogic(address(replacement));
        assertFalse(oldLogic.acceptingRequests());
        assertTrue(replacement.acceptingRequests());

        vm.prank(BOB);
        vm.expectRevert(BinderLogic.MintRequestsDisabled.selector);
        oldLogic.requestMint(bytes32(uint256(2)));

        vm.expectRevert(
            abi.encodeWithSelector(CentralConsole.PendingMintsPreventRetirement.selector, address(oldLogic), uint256(1))
        );
        centralConsole.finalizeBinderLogicRetirement(address(oldLogic));

        entropy.fulfill(oldLogic, 1, PROVIDER, bytes32(uint256(987)));
        assertEq(oldLogic.pendingMintCount(), 0);
        assertEq(binderData.ownerOf(1), ALICE);

        centralConsole.finalizeBinderLogicRetirement(address(oldLogic));
        assertFalse(binderData.authorizedBinderLogic(address(oldLogic)));

        // A historical MINTER_ROLE grant is no longer an alternate mint path.
        binderData.grantRole(binderData.MINTER_ROLE(), address(oldLogic));
        vm.prank(address(oldLogic));
        vm.expectRevert(abi.encodeWithSelector(BinderData.UnauthorizedBinderLogic.selector, address(oldLogic)));
        binderData._mintRandomNFT(ALICE, 1, "Villager", 1, "Common", _stats(), _vitals());
    }

    function testCallbacksUseOnlyTheirOwnEntropyDomain() public {
        vm.prank(ALICE);
        oldLogic.requestMint(bytes32(uint256(10)));
        entropy.fulfill(oldLogic, 1, PROVIDER, bytes32(uint256(12345)));

        vm.prank(BOB);
        oldLogic.requestMint(bytes32(uint256(11)));
        entropy.fulfill(oldLogic, 2, PROVIDER, bytes32(uint256(12345)));

        binderStructs.NFTMetadata memory first = binderData.getNFTDetails(1);
        binderStructs.NFTMetadata memory second = binderData.getNFTDetails(2);
        for (uint256 index; index < 8; ++index) {
            assertEq(first.staticStats.stats[index], second.staticStats.stats[index]);
        }
    }

    function testUnknownCallbackDoesNotAlterPendingCount() public {
        vm.prank(ALICE);
        oldLogic.requestMint(bytes32(uint256(1)));
        assertEq(oldLogic.pendingMintCount(), 1);

        vm.expectRevert(abi.encodeWithSelector(BinderLogic.InvalidMintRequest.selector, uint64(99)));
        entropy.fulfill(oldLogic, 99, PROVIDER, bytes32(uint256(2)));
        assertEq(oldLogic.pendingMintCount(), 1);
    }

    function _newLogic() internal returns (BinderLogic logic) {
        logic = new BinderLogic(
            address(entropy), PROVIDER, address(binderData), address(book), address(registry), address(this)
        );
        logic.setMintPrice(0);
        logic.grantRole(logic.CONFIG_ROLE(), address(centralConsole));
        uint8[] memory rarityIds = new uint8[](1);
        uint16[] memory chances = new uint16[](1);
        rarityIds[0] = 1;
        chances[0] = 10_000;
        logic.setRarityDistribution(rarityIds, chances);
    }

    function _stats() internal pure returns (binderStructs.StaticStats memory) {
        return binderStructs.StaticStats({stats: [uint8(1), 1, 1, 1, 1, 1, 1, 1]});
    }

    function _vitals() internal pure returns (binderStructs.DynamicStats memory) {
        return binderStructs.DynamicStats({maxHP: 10, maxMP: 10, currentHP: 10, currentMP: 10});
    }
}
