// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../modular/BinderData.sol";
import "../modular/Book0fLife.sol";
import "../modular/FusionMinter.sol";
import "../modular/supportContract/CentralConsole.sol";
import "../modular/supportContract/binderIds.sol";
import "../modular/supportContract/binderStructs.sol";
import "../modular/interfaces/ICentralConsole.sol";

/// @dev Implements only the Entropy calls exercised by FusionMinter.
contract EntropyV2Mock {
    uint64 internal _nextSequence = 1;

    function getFeeV2(address, uint32) external pure returns (uint128) {
        return 0;
    }

    function requestV2(address, bytes32, uint32) external payable returns (uint64 sequence) {
        sequence = _nextSequence++;
    }

    function resolve(FusionMinter minter, address provider, uint64 sequence, bytes32 randomNumber) external {
        minter._entropyCallback(sequence, provider, randomNumber);
    }
}

contract FusionLifecycleTest is Test {
    address internal constant ALICE = address(0xA11CE);
    address internal constant PROVIDER = address(0xBEEF);
    address internal constant GRAVEYARD = address(0xDEAD);

    BinderData internal binderData;
    Book0fLife internal life;
    CentralConsole internal centralConsole;
    EntropyV2Mock internal entropy;
    FusionMinter internal fusion;

    function setUp() public {
        binderData = new BinderData(address(this), "");
        binderData.setAuthorizedBinderLogic(address(this), true);
        centralConsole = new CentralConsole(address(this), address(binderData));
        binderData.grantRole(binderData.CONFIG_ROLE(), address(centralConsole));
        life = new Book0fLife();
        entropy = new EntropyV2Mock();
        _configureLife();
        life.grantRole(life.CONFIG_ROLE(), address(centralConsole));
        centralConsole.setBook0fLife(address(life));

        fusion = new FusionMinter(address(binderData), address(life), address(entropy), PROVIDER, address(this));
        centralConsole.setFusionMinter(address(fusion));
        binderData.setGraveyard(GRAVEYARD);
        _mintPair();
        vm.deal(ALICE, 1 ether);
    }

    function testPendingFusionRetainsOldMinterExitAfterControllerCutover() public {
        uint256 fusionId = _requestFusion();
        assertEq(fusion.pendingFusionCount(), 1);
        assertEq(binderData.activeFusionMinter(1), address(fusion));
        assertEq(binderData.ownerOf(1), address(fusion));

        vm.expectRevert(abi.encodeWithSelector(BinderData.ActiveFusionBinding.selector, uint256(1), address(fusion)));
        binderData.forceClearActivity(1);

        BinderData anotherCollection = new BinderData(address(this), "");
        vm.expectRevert(abi.encodeWithSelector(FusionMinter.PendingFusionsPreventBinderDataChange.selector, uint256(1)));
        fusion.setBaseBinder(address(anotherCollection));

        FusionMinter replacement =
            new FusionMinter(address(binderData), address(life), address(entropy), PROVIDER, address(this));
        centralConsole.setFusionMinter(address(replacement));
        assertEq(binderData.getActivityController(BinderIds.ACTIVITY_FUSION), address(replacement));

        vm.warp(block.timestamp + fusion.FUSION_RESCUE_DELAY());
        vm.prank(ALICE);
        fusion.rescueFusion(fusionId);

        assertEq(fusion.pendingFusionCount(), 0);
        assertEq(binderData.ownerOf(1), ALICE);
        assertEq(binderData.ownerOf(2), ALICE);
        assertTrue(binderData.getUnitState(1).idle);
        assertEq(binderData.activeFusionMinter(1), address(0));
    }

    function testOutgoingFusionMinterCompletesCallbackAfterCutover() public {
        uint256 fusionId = _requestFusion();
        (,,,, uint64 sequence,) = fusion.getFusionRequest(fusionId);

        FusionMinter replacement =
            new FusionMinter(address(binderData), address(life), address(entropy), PROVIDER, address(this));
        centralConsole.setFusionMinter(address(replacement));
        entropy.resolve(fusion, PROVIDER, sequence, bytes32(uint256(999)));

        assertEq(uint8(fusion.fusionStatus(fusionId)), uint8(FusionMinter.FusionStatus.RESOLVED));
        assertEq(fusion.pendingFusionCount(), 0);
        assertEq(binderData.ownerOf(1), GRAVEYARD);
        assertEq(binderData.ownerOf(2), GRAVEYARD);
        assertEq(binderData.ownerOf(3), ALICE);
        assertEq(binderData.activeFusionCountByMinter(address(fusion)), 0);
    }

    function testFusionRetirementWaitsForBoundWorkThenRemovesAuthorizationAndBookRole() public {
        uint256 fusionId = _requestFusion();
        FusionMinter replacement =
            new FusionMinter(address(binderData), address(life), address(entropy), PROVIDER, address(this));
        centralConsole.setFusionMinter(address(replacement));

        vm.expectRevert(
            abi.encodeWithSelector(CentralConsole.PendingFusionsPreventRetirement.selector, address(fusion), uint256(2))
        );
        centralConsole.finalizeFusionMinterRetirement(address(fusion));

        entropy.resolve(fusion, PROVIDER, 1, bytes32(uint256(99)));
        assertEq(binderData.activeFusionCountByMinter(address(fusion)), 0);
        assertEq(fusion.pendingFusionCount(), 0);

        centralConsole.finalizeFusionMinterRetirement(address(fusion));
        assertFalse(binderData.authorizedFusionMinter(address(fusion)));
        assertFalse(life.hasRole(life.FUSION_MINTER(), address(fusion)));
        assertEq(uint8(fusion.fusionStatus(fusionId)), uint8(FusionMinter.FusionStatus.RESOLVED));
    }

    function testConsoleReportsFusionWiringPostconditions() public view {
        ICentralConsole.WiringStatus memory status = centralConsole.getWiringStatus();
        assertTrue(status.bookLifeDependenciesMatch);
        assertTrue(status.fusionActivityControllerMatch);
    }

    function testRescuedFusionRejectsLateEntropyCallback() public {
        uint256 fusionId = _requestFusion();
        (,,,, uint64 sequence,) = fusion.getFusionRequest(fusionId);
        vm.warp(block.timestamp + fusion.FUSION_RESCUE_DELAY());
        vm.prank(ALICE);
        fusion.rescueFusion(fusionId);

        vm.expectRevert(abi.encodeWithSelector(FusionMinter.UnknownEntropySequence.selector, sequence));
        entropy.resolve(fusion, PROVIDER, sequence, bytes32(uint256(123)));
    }

    function testFusionAllocatesAtMaxAdd254() public {
        life.addNewClass(3, "Boundary", 1, _maxFusionGapConfig(), 1);
        life.enableClassAcquisition(3, life.ACQ_FUSION());
        binderData.setClassVersion(3, 1);

        uint256[] memory outcomes = new uint256[](1);
        outcomes[0] = 3;
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        life.setFusionRecipe(1, 2, outcomes, weights, 10_000);

        uint256 fusionId = _requestFusion();
        (,,,, uint64 sequence,) = fusion.getFusionRequest(fusionId);
        entropy.resolve(fusion, PROVIDER, sequence, bytes32(0));

        assertEq(binderData.ownerOf(3), ALICE);
    }

    function _requestFusion() internal returns (uint256 fusionId) {
        vm.startPrank(ALICE);
        binderData.approve(address(fusion), 1);
        binderData.approve(address(fusion), 2);
        fusion.riteFusion{value: fusion.fusionCost()}(1, 2);
        vm.stopPrank();
        fusionId = fusion.nextFusionId();
    }

    function _configureLife() internal {
        life.registerRarity(1, "Common");
        binderStructs.ClassConfig memory config = _classConfig();
        life.addNewClass(1, "Knight", 1, config, 1);
        life.addNewClass(2, "Mage", 1, config, 1);
        life.enableClassAcquisition(1, life.ACQ_FUSION());
        binderData.setClassVersion(1, 1);
        binderData.setClassVersion(2, 1);
        uint256[] memory outcomes = new uint256[](1);
        outcomes[0] = 1;
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        life.setFusionRecipe(1, 2, outcomes, weights, 10_000);
    }

    function _mintPair() internal {
        uint8[8] memory values = [uint8(10), 10, 10, 10, 10, 10, 10, 10];
        binderStructs.StaticStats memory stats = binderStructs.StaticStats({stats: values});
        binderStructs.DynamicStats memory vitals =
            binderStructs.DynamicStats({maxHP: 100, maxMP: 100, currentHP: 100, currentMP: 100});
        binderData._mintRandomNFT(ALICE, 1, "Knight", 1, "Common", stats, vitals);
        binderData._mintRandomNFT(ALICE, 2, "Mage", 1, "Common", stats, vitals);
    }

    function _classConfig() internal pure returns (binderStructs.ClassConfig memory config) {
        uint8[8] memory minimums = [uint8(1), 1, 1, 1, 1, 1, 1, 1];
        uint8[8] memory maximums = [uint8(20), 20, 20, 20, 20, 20, 20, 20];
        config = binderStructs.ClassConfig({
            minStats: minimums,
            maxStats: maximums,
            totalPoints: 8,
            hpPerVit: 10,
            mpPerWis: 10
        });
    }

    function _maxFusionGapConfig() internal pure returns (binderStructs.ClassConfig memory config) {
        config = binderStructs.ClassConfig({
            minStats: [uint8(1), 1, 1, 1, 1, 1, 1, 1],
            maxStats: [uint8(255), 255, 255, 255, 255, 255, 255, 255],
            totalPoints: 1,
            hpPerVit: 1,
            mpPerWis: 1
        });
    }
}
