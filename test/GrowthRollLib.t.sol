// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {GrowthRollLib} from "../modular/growth/GrowthRollLib.sol";
import {binderStructs} from "../modular/supportContract/binderStructs.sol";

contract GrowthRollLibTest is Test {
    function testChanceBoundariesAndFullWidth() public pure {
        assertTrue(GrowthRollLib.chance(7_999, 8_000));
        assertFalse(GrowthRollLib.chance(8_000, 8_000));
        assertTrue(GrowthRollLib.chance(6_699, 6_700));
        assertFalse(GrowthRollLib.chance(6_700, 6_700));
        assertTrue(GrowthRollLib.chance(5_999, 6_000));
        assertFalse(GrowthRollLib.chance(6_000, 6_000));
        assertFalse(GrowthRollLib.chance(0, 0));
        assertTrue(GrowthRollLib.chance(type(uint256).max, 10_000));
        // A uint16 truncation would incorrectly turn this into a successful zero roll.
        assertFalse(GrowthRollLib.chance(65_536, 1));
    }

    function testDirectSliceVectors() public pure {
        bytes32 seed = bytes32((uint256(7_999) << 192) | (uint256(2) << 128));
        (bool success, int32[8] memory delta) = GrowthRollLib.drill(seed, 8_000, 4, 1, 3);
        assertTrue(success);
        for (uint256 i; i < 8; ++i) {
            assertEq(delta[i], i == 4 ? int32(3) : int32(0));
        }
        (success, delta) = GrowthRollLib.drill(bytes32(uint256(8_000) << 192), 8_000, 4, 1, 3);
        assertFalse(success);
        for (uint256 i; i < 8; ++i) {
            assertEq(delta[i], 0);
        }

        seed = bytes32((uint256(6_699) << 192) | (uint256(5) << 128) | (uint256(4) << 64) | 4);
        (success, delta) = GrowthRollLib.xDrill(seed, 6_700, _xProfile());
        assertTrue(success);
        assertEq(delta[0], 8);
        assertEq(delta[1], 5);
        assertEq(delta[2], -6);
        for (uint256 i = 3; i < 8; ++i) {
            assertEq(delta[i], 0);
        }
        (success, delta) = GrowthRollLib.xDrill(bytes32(uint256(6_700) << 192), 6_700, _xProfile());
        assertFalse(success);
        for (uint256 i; i < 8; ++i) {
            assertEq(delta[i], 0);
        }
    }

    function testFuzzDrillSelectedStatOnly(bytes32 seed, uint8 stat) public pure {
        stat %= 8;
        (bool success, int32[8] memory delta) = GrowthRollLib.drill(seed, 8_000, stat, 1, 3);
        assertEq(success, uint64(uint256(seed) >> 192) % 10_000 < 8_000);
        for (uint256 i; i < 8; ++i) {
            if (success && i == stat) {
                assertGe(delta[i], 1);
                assertLe(delta[i], 3);
            } else {
                assertEq(delta[i], 0);
            }
        }
    }

    function testFuzzXDrillDistinctStatsAndRanges(bytes32 seed, uint16[8] memory weights) public pure {
        binderStructs.GrowthStatProfile memory profile = _xProfile();
        for (uint256 i; i < 8; ++i) {
            if (weights[i] == 0) weights[i] = 1;
        }
        profile.primaryWeights = weights;
        profile.secondaryWeights = weights;
        profile.tertiaryWeights = weights;
        GrowthRollLib.validateProfile(profile);
        (bool success, int32[8] memory delta) = GrowthRollLib.xDrill(seed, 6_700, profile);
        assertEq(success, uint64(uint256(seed) >> 192) % 10_000 < 6_700);
        uint8 excluded;
        int32[8] memory expected;
        if (success) {
            for (uint256 i; i < 3; ++i) {
                uint64 slice = uint64(uint256(seed) >> (128 - i * 64));
                uint8 stat = GrowthRollLib.pick(uint32(slice >> 32), weights, excluded);
                assertEq(excluded & (uint8(1) << stat), 0);
                excluded |= uint8(1) << stat;
                expected[stat] = GrowthRollLib.amount(uint32(slice), profile.minDeltas[i], profile.maxDeltas[i]);
                assertGe(expected[stat], profile.minDeltas[i]);
                assertLe(expected[stat], profile.maxDeltas[i]);
            }
        }
        assertEq(abi.encode(delta), abi.encode(expected));
    }

    function testSparseProfileAndRenormalisation() public pure {
        binderStructs.GrowthStatProfile memory profile;
        profile.primaryWeights[1] = 100;
        profile.secondaryWeights[1] = 65_535;
        profile.secondaryWeights[5] = 1;
        profile.tertiaryWeights[1] = 65_535;
        profile.tertiaryWeights[5] = 65_535;
        profile.tertiaryWeights[0] = 1;
        profile.minDeltas = [int32(3), 1, -10];
        profile.maxDeltas = [int32(8), 5, -6];
        GrowthRollLib.validateProfile(profile);
        (, int32[8] memory delta) = GrowthRollLib.xDrill(bytes32(type(uint256).max), 10_000, profile);
        assertGt(delta[1], 0);
        assertGt(delta[5], 0);
        assertLt(delta[0], 0);
    }

    function testRejectsReachableEmptyExclusionPath() public {
        binderStructs.GrowthStatProfile memory profile = _xProfile();
        for (uint256 i; i < 8; ++i) {
            profile.primaryWeights[i] = 0;
            profile.secondaryWeights[i] = 0;
            profile.tertiaryWeights[i] = 0;
        }
        profile.primaryWeights[0] = 1;
        profile.primaryWeights[1] = 1;
        profile.secondaryWeights[0] = 1;
        profile.tertiaryWeights[2] = 1;
        vm.expectRevert(GrowthRollLib.EmptyWeightTable.selector);
        this.validateProfile(profile);
        profile.secondaryWeights[1] = 1;
        profile.tertiaryWeights[2] = 0;
        profile.tertiaryWeights[0] = 1;
        vm.expectRevert(GrowthRollLib.EmptyWeightTable.selector);
        this.validateProfile(profile);
    }

    function testFuzzWeightedPickMatchesCumulativeIntervals(uint256 roll, uint16[8] memory weights, uint8 excluded)
        public
    {
        uint256 total;
        for (uint8 i; i < 8; ++i) {
            if ((excluded & (uint8(1) << i)) == 0) total += weights[i];
        }
        if (total == 0) {
            vm.expectRevert(GrowthRollLib.EmptyWeightTable.selector);
            this.pick(roll, weights, excluded);
            return;
        }
        uint8 selected = GrowthRollLib.pick(roll, weights, excluded);
        uint256 lower;
        for (uint8 i; i < selected; ++i) {
            if ((excluded & (uint8(1) << i)) == 0) lower += weights[i];
        }
        assertEq(excluded & (uint8(1) << selected), 0);
        assertGt(weights[selected], 0);
        assertGe(roll % total, lower);
        assertLt(roll % total, lower + weights[selected]);
    }

    function testFuzzErrantryAndQuestDomainSchedules(bytes32 seed, bytes32 activityId) public pure {
        binderStructs.GrowthStatProfile memory profile = _xProfile();
        profile.minDeltas = [int32(1), -5, -5];
        profile.maxDeltas = [int32(10), -3, -3];
        (bool success, int32[8] memory delta) = GrowthRollLib.errantry(seed, activityId, 6_000, profile);
        uint256 roll = uint256(keccak256(abi.encode(seed, activityId, bytes32("ERRANTRY_SUCCESS"), uint256(0))));
        assertEq(success, roll % 10_000 < 6_000);
        _assertErrantryShape(delta, success);
        int32[8] memory questDelta = GrowthRollLib.questStats(seed, activityId, profile);
        _assertErrantryShape(questDelta, true);
        uint256 expanded = GrowthRollLib.expand(seed, activityId, "QUEST_DEATH", 0);
        assertEq(expanded, uint256(keccak256(abi.encode(seed, activityId, bytes32("QUEST_DEATH"), uint256(0)))));
        assertNotEq(expanded, GrowthRollLib.expand(seed, activityId, "QUEST_SUCCESS", 0));
        assertNotEq(expanded, GrowthRollLib.expand(seed, activityId, "QUEST_DEATH", 1));
    }

    function testFuzzFloorAndOverflow(uint8 base, int32 stored, int32 change) public {
        int256 current = int256(uint256(base)) + stored;
        if (current < 1) current = 1;
        int256 expected = current + change;
        if (expected < 1) expected = 1;
        if (expected - int256(uint256(base)) > type(int32).max) {
            vm.expectRevert(GrowthRollLib.GrowthOverflow.selector);
            this.applyDelta(base, stored, change);
            return;
        }
        (int32 updated, uint32 swg) = GrowthRollLib.applyDelta(base, stored, change);
        assertEq(int256(updated) + int256(uint256(base)), expected);
        assertEq(swg, uint256(expected));
        assertGe(swg, 1);
    }

    function testFloorDiscardsLossAndDoesNotClampToUint16() public pure {
        (int32 stored, uint32 swg) = GrowthRollLib.applyDelta(10, 0, -100);
        assertEq(stored, -9);
        assertEq(swg, 1);
        (stored, swg) = GrowthRollLib.applyDelta(10, stored, 3);
        assertEq(stored, -6);
        assertEq(swg, 4);
        (stored, swg) = GrowthRollLib.applyDelta(255, 0, type(int32).max);
        assertEq(stored, type(int32).max);
        assertEq(swg, uint256(uint32(type(int32).max)) + 255);
    }

    function testFuzzInclusiveSignedRange(uint256 roll, int32 a, int32 b) public pure {
        (int32 minimum, int32 maximum) = a <= b ? (a, b) : (b, a);
        int32 result = GrowthRollLib.amount(roll, minimum, maximum);
        assertGe(result, minimum);
        assertLe(result, maximum);
        assertEq(GrowthRollLib.amount(0, minimum, maximum), minimum);
        assertEq(GrowthRollLib.amount(uint256(int256(maximum) - int256(minimum)), minimum, maximum), maximum);
    }

    function testInputValidation() public {
        vm.expectRevert(GrowthRollLib.InvalidChance.selector);
        this.chance(0, 10_001);
        vm.expectRevert(GrowthRollLib.InvalidRange.selector);
        this.amount(0, 2, 1);
        vm.expectRevert(GrowthRollLib.InvalidStat.selector);
        this.drill(8, 1, 3);
        vm.expectRevert(GrowthRollLib.InvalidRange.selector);
        this.drill(0, 3, 1);
        vm.expectRevert(GrowthRollLib.InvalidRange.selector);
        this.drill(0, 0, type(uint32).max);
        binderStructs.GrowthStatProfile memory profile = _xProfile();
        profile.minDeltas[2] = 1;
        vm.expectRevert(GrowthRollLib.InvalidRange.selector);
        this.validateProfile(profile);
    }

    function _assertErrantryShape(int32[8] memory delta, bool success) private pure {
        uint256 gains;
        uint256 losses;
        for (uint256 i; i < 8; ++i) {
            if (delta[i] > 0) {
                ++gains;
                assertLe(delta[i], 10);
            } else if (delta[i] < 0) {
                ++losses;
                assertGe(delta[i], -5);
                assertLe(delta[i], -3);
            }
        }
        assertEq(gains, success ? 1 : 0);
        assertEq(losses, success ? 2 : 0);
    }

    function _xProfile() private pure returns (binderStructs.GrowthStatProfile memory profile) {
        for (uint256 i; i < 8; ++i) {
            profile.primaryWeights[i] = 1;
            profile.secondaryWeights[i] = 1;
            profile.tertiaryWeights[i] = 1;
        }
        profile.minDeltas = [int32(3), 1, -10];
        profile.maxDeltas = [int32(8), 5, -6];
    }

    // External boundaries let Foundry assert pure-library reverts precisely.
    function validateProfile(binderStructs.GrowthStatProfile memory profile) external pure {
        GrowthRollLib.validateProfile(profile);
    }

    function chance(uint256 roll, uint16 bps) external pure returns (bool) {
        return GrowthRollLib.chance(roll, bps);
    }

    function amount(uint256 roll, int32 minimum, int32 maximum) external pure returns (int32) {
        return GrowthRollLib.amount(roll, minimum, maximum);
    }

    function drill(uint8 stat, uint32 minimum, uint32 maximum) external pure {
        GrowthRollLib.drill(bytes32(0), 8_000, stat, minimum, maximum);
    }

    function pick(uint256 roll, uint16[8] memory weights, uint8 excluded) external pure returns (uint8) {
        return GrowthRollLib.pick(roll, weights, excluded);
    }

    function applyDelta(uint8 base, int32 stored, int32 change) external pure returns (int32, uint32) {
        return GrowthRollLib.applyDelta(base, stored, change);
    }
}
