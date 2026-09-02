// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../supportContract/binderStructs.sol";

/// @notice Read API for versioned map and tile definitions used by battle modules.
interface IBook0fRealms {
    function getMapCount() external view returns (uint256);
    function getMapIdAt(uint256 index) external view returns (uint32);
    function getMapIds(uint256 offset, uint256 limit) external view returns (uint32[] memory);
    function getMap(uint32 mapId) external view returns (binderStructs.MapDefinition memory);
    function getMapAtVersion(uint32 mapId, uint16 version) external view returns (binderStructs.MapDefinition memory);
    function getMapVersionCount(uint32 mapId) external view returns (uint256);
    function getMapVersionAt(uint32 mapId, uint256 index) external view returns (uint16);
    function getMapVersions(uint32 mapId, uint256 offset, uint256 limit) external view returns (uint16[] memory);
    function getTile(uint32 mapId, uint16 version, uint16 tileId)
        external
        view
        returns (binderStructs.TileDefinition memory);
    function getTiles(uint32 mapId, uint16 version, uint256 offset, uint256 limit)
        external
        view
        returns (binderStructs.TileDefinition[] memory);
    function getInternalCoordinates(uint32 mapId, uint16 version, uint16 tileId)
        external
        view
        returns (uint16 x, uint16 y, int16 z);
    function getDisplayCoordinates(uint32 mapId, uint16 version, uint16 tileId)
        external
        view
        returns (uint16 x, uint16 y, int16 z);
    function isWalkable(uint32 mapId, uint16 version, uint16 tileId) external view returns (bool);
}
