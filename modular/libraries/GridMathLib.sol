// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../supportContract/Errors.sol";

/// @notice Pure tile-ID geometry helpers for canonical Book0fRealms maps.
/// @dev Tile IDs are one-based externally; returned internal coordinates are
/// zero-based. Terrain, occupancy, elevation, and full path validation remain
/// explicit BattleProxy concerns rather than hidden coordinate conventions.
library GridMathLib {
    function internalCoordinates(uint16 tileId, uint16 width, uint16 tileCount)
        internal
        pure
        returns (uint16 x, uint16 y)
    {
        _requireTile(tileId, width, tileCount);
        uint256 zeroBasedTile = uint256(tileId) - 1;
        x = uint16(zeroBasedTile % width);
        y = uint16(zeroBasedTile / width);
    }

    function displayCoordinates(uint16 tileId, uint16 width, uint16 tileCount)
        internal
        pure
        returns (uint16 x, uint16 y)
    {
        (uint16 internalX, uint16 internalY) = internalCoordinates(tileId, width, tileCount);
        return (internalX + 1, internalY + 1);
    }

    function tileIdAt(uint16 x, uint16 y, uint16 width, uint16 height) internal pure returns (uint16) {
        if (width == 0 || height == 0) revert InvalidGridDimensions(width, height);
        if (x >= width || y >= height) revert InvalidGridDimensions(width, height);
        uint256 tileId = uint256(y) * width + x + 1;
        if (tileId > type(uint16).max) revert TileOutOfBounds(type(uint16).max, type(uint16).max);
        return uint16(tileId);
    }

    function manhattanDistance(uint16 fromTileId, uint16 toTileId, uint16 width, uint16 tileCount)
        internal
        pure
        returns (uint16)
    {
        (uint16 fromX, uint16 fromY) = internalCoordinates(fromTileId, width, tileCount);
        (uint16 toX, uint16 toY) = internalCoordinates(toTileId, width, tileCount);
        return _absoluteDifference(fromX, toX) + _absoluteDifference(fromY, toY);
    }

    function chebyshevDistance(uint16 fromTileId, uint16 toTileId, uint16 width, uint16 tileCount)
        internal
        pure
        returns (uint16)
    {
        (uint16 fromX, uint16 fromY) = internalCoordinates(fromTileId, width, tileCount);
        (uint16 toX, uint16 toY) = internalCoordinates(toTileId, width, tileCount);
        uint16 horizontal = _absoluteDifference(fromX, toX);
        uint16 vertical = _absoluteDifference(fromY, toY);
        return horizontal > vertical ? horizontal : vertical;
    }

    function areOrthogonallyAdjacent(uint16 fromTileId, uint16 toTileId, uint16 width, uint16 tileCount)
        internal
        pure
        returns (bool)
    {
        return manhattanDistance(fromTileId, toTileId, width, tileCount) == 1;
    }

    function sumMovementCosts(uint16[] memory movementCosts) internal pure returns (uint256 totalCost) {
        for (uint256 index; index < movementCosts.length; ++index) {
            totalCost += movementCosts[index];
        }
    }

    function _requireTile(uint16 tileId, uint16 width, uint16 tileCount) private pure {
        if (width == 0 || tileCount == 0) revert InvalidGridDimensions(width, 0);
        if (tileId == 0 || tileId > tileCount) revert TileOutOfBounds(tileId, tileCount);
    }

    function _absoluteDifference(uint16 left, uint16 right) private pure returns (uint16) {
        return left >= right ? left - right : right - left;
    }
}
