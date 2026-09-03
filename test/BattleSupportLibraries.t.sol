// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../modular/supportContract/binderIds.sol";
import "../modular/supportContract/Errors.sol";
import "../modular/libraries/ArtFormulaLib.sol";
import "../modular/libraries/AilmentBitmapLib.sol";
import "../modular/libraries/GridMathLib.sol";
import "../modular/supportContract/binderStructs.sol";

contract BattleSupportHarness {
    function evaluate(binderStructs.Formula memory formula, uint256[8] memory actor, uint256[8] memory target)
        external
        pure
        returns (int256)
    {
        return ArtFormulaLib.evaluate(formula, actor, target);
    }

    function clampDamage(int256 amount, uint16 currentHP) external pure returns (uint16) {
        return ArtFormulaLib.clampDamage(amount, currentHP);
    }

    function clampResource(int256 delta, uint16 currentValue, uint16 maxValue) external pure returns (uint16) {
        return ArtFormulaLib.clampResourceDelta(delta, currentValue, maxValue);
    }

    function canPayCosts(uint16 hp, uint16 mp, uint16 hpCost, uint16 mpCost) external pure returns (bool) {
        return ArtFormulaLib.canPayCosts(hp, mp, hpCost, mpCost);
    }

    function ailmentHas(uint256 bitmap, uint8 ailmentId) external pure returns (bool) {
        return AilmentBitmapLib.has(bitmap, ailmentId);
    }

    function addAilment(uint256 bitmap, uint8 ailmentId) external pure returns (uint256) {
        return AilmentBitmapLib.add(bitmap, ailmentId);
    }

    function removeAilment(uint256 bitmap, uint8 ailmentId) external pure returns (uint256) {
        return AilmentBitmapLib.remove(bitmap, ailmentId);
    }

    function internalCoordinates(uint16 tileId, uint16 width, uint16 tileCount)
        external
        pure
        returns (uint16, uint16)
    {
        return GridMathLib.internalCoordinates(tileId, width, tileCount);
    }

    function displayCoordinates(uint16 tileId, uint16 width, uint16 tileCount) external pure returns (uint16, uint16) {
        return GridMathLib.displayCoordinates(tileId, width, tileCount);
    }

    function tileIdAt(uint16 x, uint16 y, uint16 width, uint16 height) external pure returns (uint16) {
        return GridMathLib.tileIdAt(x, y, width, height);
    }

    function distances(uint16 fromTileId, uint16 toTileId, uint16 width, uint16 tileCount)
        external
        pure
        returns (uint16 manhattan, uint16 chebyshev, bool adjacent)
    {
        manhattan = GridMathLib.manhattanDistance(fromTileId, toTileId, width, tileCount);
        chebyshev = GridMathLib.chebyshevDistance(fromTileId, toTileId, width, tileCount);
        adjacent = GridMathLib.areOrthogonallyAdjacent(fromTileId, toTileId, width, tileCount);
    }

    function sumMovementCosts(uint16[] memory costs) external pure returns (uint256) {
        return GridMathLib.sumMovementCosts(costs);
    }
}

contract BattleSupportLibrariesTest is Test {
    BattleSupportHarness internal harness;

    function setUp() public {
        harness = new BattleSupportHarness();
    }

    function testFormulaEvaluatesSignedTermsAndClampsResources() public view {
        binderStructs.Formula memory formula;
        formula.flatValue = 30;
        formula.termCount = 2;
        formula.terms[0] = binderStructs.FormulaTerm({
            sourceId: BinderIds.FORMULA_SOURCE_ACTOR,
            statId: BinderIds.STAT_INT,
            coefficientBps: 7_000
        });
        formula.terms[1] = binderStructs.FormulaTerm({
            sourceId: BinderIds.FORMULA_SOURCE_TARGET,
            statId: BinderIds.STAT_WIS,
            coefficientBps: -2_000
        });
        uint256[8] memory actor;
        uint256[8] memory target;
        actor[BinderIds.STAT_INT] = 100;
        target[BinderIds.STAT_WIS] = 40;

        assertEq(harness.evaluate(formula, actor, target), 92);
        assertEq(harness.clampDamage(500, 143), 143);
        assertEq(harness.clampDamage(-1, 143), 0);
        assertEq(harness.clampResource(50, 80, 100), 100);
        assertEq(harness.clampResource(-90, 80, 100), 0);
        assertEq(harness.clampResource(-20, 80, 100), 60);
        assertTrue(harness.canPayCosts(30, 20, 30, 20));
        assertFalse(harness.canPayCosts(29, 20, 30, 20));
    }

    function testFormulaRejectsMalformedTermsAndOverflowingInput() public {
        binderStructs.Formula memory formula;
        uint256[8] memory stats;

        formula.termCount = 1;
        formula.terms[0] = binderStructs.FormulaTerm({sourceId: 0, statId: 0, coefficientBps: 1});
        vm.expectRevert(abi.encodeWithSelector(InvalidFormulaSource.selector, uint8(0)));
        harness.evaluate(formula, stats, stats);

        formula.terms[0] = binderStructs.FormulaTerm({sourceId: 1, statId: 8, coefficientBps: 1});
        vm.expectRevert(abi.encodeWithSelector(InvalidFormulaStatId.selector, uint8(8)));
        harness.evaluate(formula, stats, stats);

        formula.terms[0] = binderStructs.FormulaTerm({sourceId: 1, statId: 0, coefficientBps: 1});
        stats[0] = uint256(type(int256).max) + 1;
        vm.expectRevert(FormulaArithmeticOverflow.selector);
        harness.evaluate(formula, stats, stats);
    }

    function testAilmentBitmapHandlesBoundariesAndIdempotency() public {
        uint8[6] memory ids = [uint8(1), 2, 127, 128, 254, 255];
        uint256 bitmap;
        for (uint256 index; index < ids.length; ++index) {
            bitmap = harness.addAilment(bitmap, ids[index]);
            assertTrue(harness.ailmentHas(bitmap, ids[index]));
        }
        uint256 duplicateAdd = harness.addAilment(bitmap, 128);
        assertEq(duplicateAdd, bitmap);
        uint256 removed = harness.removeAilment(bitmap, 127);
        assertFalse(harness.ailmentHas(removed, 127));
        assertEq(harness.removeAilment(removed, 127), removed);
        vm.expectRevert(abi.encodeWithSelector(InvalidAilmentId.selector, uint8(0)));
        harness.addAilment(bitmap, 0);
    }

    function testGridGeometryUsesOneBasedTilesAndBoundedCoordinates() public view {
        (uint16 internalX, uint16 internalY) = harness.internalCoordinates(1, 4, 12);
        assertEq(internalX, 0);
        assertEq(internalY, 0);
        (uint16 displayX, uint16 displayY) = harness.displayCoordinates(1, 4, 12);
        assertEq(displayX, 1);
        assertEq(displayY, 1);
        assertEq(harness.tileIdAt(3, 2, 4, 3), 12);

        (uint16 manhattan, uint16 chebyshev, bool adjacent) = harness.distances(1, 6, 4, 12);
        assertEq(manhattan, 2);
        assertEq(chebyshev, 1);
        assertFalse(adjacent);
        (,, adjacent) = harness.distances(1, 2, 4, 12);
        assertTrue(adjacent);

        uint16[] memory costs = new uint16[](3);
        costs[0] = 2;
        costs[1] = 3;
        costs[2] = 4;
        assertEq(harness.sumMovementCosts(costs), 9);
    }

    function testGridRejectsInvalidTilesAndDimensions() public {
        vm.expectRevert(abi.encodeWithSelector(TileOutOfBounds.selector, uint16(0), uint16(12)));
        harness.internalCoordinates(0, 4, 12);
        vm.expectRevert(abi.encodeWithSelector(TileOutOfBounds.selector, uint16(13), uint16(12)));
        harness.internalCoordinates(13, 4, 12);
        vm.expectRevert(abi.encodeWithSelector(InvalidGridDimensions.selector, uint16(0), uint16(0)));
        harness.internalCoordinates(1, 0, 12);
        vm.expectRevert(abi.encodeWithSelector(InvalidGridDimensions.selector, uint16(4), uint16(3)));
        harness.tileIdAt(4, 2, 4, 3);
    }
}
