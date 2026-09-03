// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-4.8/access/AccessControl.sol";
import "./supportContract/binderIds.sol";
import "./supportContract/Errors.sol";
import "./supportContract/binderStructs.sol";
import "./interfaces/IBook0fRealms.sol";

/// @notice Canonical versioned map, tile, and castle-to-map configuration.
/// @dev Tile IDs are local to each map version and are intentionally bounded to uint16.
contract Book0fRealms is AccessControl, IBook0fRealms {
    bytes32 public constant CONFIG_ROLE = keccak256("CONFIG_ROLE");

    mapping(uint32 => bool) private _mapExists;
    mapping(uint32 => uint16) private _currentVersion;
    mapping(uint32 => bool) private _currentEnabled;
    mapping(uint32 => mapping(uint16 => bool)) private _versionExists;
    mapping(uint32 => mapping(uint16 => binderStructs.MapDefinition)) private _mapDefinitions;
    mapping(uint32 => uint16[]) private _versions;
    mapping(uint32 => mapping(uint16 => mapping(uint16 => binderStructs.TileDefinition))) private _tiles;
    uint32[] private _mapIds;
    mapping(uint256 => uint32) private _castleMap;

    event MapVersionConfigured(uint32 indexed mapId, uint16 indexed version, bool enabled, uint16 width, uint16 height);
    event MapEnabledChanged(uint32 indexed mapId, bool enabled);
    event CastleMapBound(uint256 indexed castleId, uint32 indexed mapId);

    error MapAlreadyExists(uint32 mapId);
    error MapDoesNotExist(uint32 mapId);
    error MapVersionDoesNotExist(uint32 mapId, uint16 version);
    error InvalidMapVersion(uint16 version);
    error InvalidMapDefinition();
    error InvalidTileDefinition(uint16 tileId);

    constructor(address initialAdmin) {
        if (initialAdmin == address(0)) revert InvalidModuleAddress(BinderIds.MODULE_BOOK_OF_REALMS, initialAdmin);
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(CONFIG_ROLE, initialAdmin);
    }

    function addMap(binderStructs.MapDefinition calldata definition, binderStructs.TileDefinition[] calldata tiles)
        external
        onlyRole(CONFIG_ROLE)
    {
        if (definition.mapId == 0) revert InvalidMapId(definition.mapId);
        if (_mapExists[definition.mapId]) revert MapAlreadyExists(definition.mapId);
        _mapExists[definition.mapId] = true;
        _mapIds.push(definition.mapId);
        _storeMapVersion(definition, tiles);
    }

    function updateMapVersion(
        binderStructs.MapDefinition calldata definition,
        binderStructs.TileDefinition[] calldata tiles
    ) external onlyRole(CONFIG_ROLE) {
        _requireMap(definition.mapId);
        if (definition.version <= _currentVersion[definition.mapId]) revert InvalidMapVersion(definition.version);
        _storeMapVersion(definition, tiles);
    }

    /// @notice Disables a map for new activity creation without mutating historical versions.
    function setMapEnabled(uint32 mapId, bool enabled) external onlyRole(CONFIG_ROLE) {
        _requireMap(mapId);
        _currentEnabled[mapId] = enabled;
        emit MapEnabledChanged(mapId, enabled);
    }

    function setCastleMap(uint256 castleId, uint32 mapId) external onlyRole(CONFIG_ROLE) {
        if (castleId == 0) revert InvalidMapDefinition();
        _requireMap(mapId);
        _castleMap[castleId] = mapId;
        emit CastleMapBound(castleId, mapId);
    }

    function getCastleMap(uint256 castleId) external view returns (uint32) {
        return _castleMap[castleId];
    }

    /// @notice Chunk-safe migration import. Existing map IDs only accept strictly newer versions.
    function importMapVersions(
        binderStructs.MapDefinition[] calldata definitions,
        binderStructs.TileDefinition[][] calldata tilesByDefinition
    ) external onlyRole(CONFIG_ROLE) {
        require(definitions.length == tilesByDefinition.length, "Mismatched map import");
        for (uint256 i; i < definitions.length; ++i) {
            uint32 mapId = definitions[i].mapId;
            if (mapId == 0) revert InvalidMapId(mapId);
            if (!_mapExists[mapId]) {
                _mapExists[mapId] = true;
                _mapIds.push(mapId);
            } else if (definitions[i].version <= _currentVersion[mapId]) {
                revert InvalidMapVersion(definitions[i].version);
            }
            _storeMapVersion(definitions[i], tilesByDefinition[i]);
        }
    }

    /// @notice Chunk-safe migration import for castle/world bindings.
    function importCastleBindings(uint256[] calldata castleIds, uint32[] calldata mapIds)
        external
        onlyRole(CONFIG_ROLE)
    {
        require(castleIds.length == mapIds.length, "Mismatched castle import");
        for (uint256 i; i < castleIds.length; ++i) {
            if (castleIds[i] == 0) revert InvalidMapDefinition();
            _requireMap(mapIds[i]);
            _castleMap[castleIds[i]] = mapIds[i];
            emit CastleMapBound(castleIds[i], mapIds[i]);
        }
    }

    function getMapCount() external view override returns (uint256) {
        return _mapIds.length;
    }

    function getMapIdAt(uint256 index) external view override returns (uint32) {
        return _mapIds[index];
    }

    function getMapIds(uint256 offset, uint256 limit) external view override returns (uint32[] memory) {
        uint256 sourceLength = _mapIds.length;
        if (offset >= sourceLength || limit == 0) return new uint32[](0);
        uint256 available = sourceLength - offset;
        uint256 pageLength = limit < available ? limit : available;
        uint32[] memory page = new uint32[](pageLength);
        for (uint256 i; i < pageLength; ++i) {
            page[i] = _mapIds[offset + i];
        }
        return page;
    }

    function getMap(uint32 mapId) external view override returns (binderStructs.MapDefinition memory definition) {
        _requireMap(mapId);
        definition = _mapDefinitions[mapId][_currentVersion[mapId]];
        definition.enabled = _currentEnabled[mapId];
    }

    function getMapAtVersion(uint32 mapId, uint16 version)
        external
        view
        override
        returns (binderStructs.MapDefinition memory)
    {
        _requireMapVersion(mapId, version);
        return _mapDefinitions[mapId][version];
    }

    function getMapVersionCount(uint32 mapId) external view override returns (uint256) {
        _requireMap(mapId);
        return _versions[mapId].length;
    }

    function getMapVersionAt(uint32 mapId, uint256 index) external view override returns (uint16) {
        _requireMap(mapId);
        return _versions[mapId][index];
    }

    function getMapVersions(uint32 mapId, uint256 offset, uint256 limit)
        external
        view
        override
        returns (uint16[] memory)
    {
        _requireMap(mapId);
        uint16[] storage source = _versions[mapId];
        uint256 sourceLength = source.length;
        if (offset >= sourceLength || limit == 0) return new uint16[](0);
        uint256 available = sourceLength - offset;
        uint256 pageLength = limit < available ? limit : available;
        uint16[] memory page = new uint16[](pageLength);
        for (uint256 i; i < pageLength; ++i) {
            page[i] = source[offset + i];
        }
        return page;
    }

    function getTile(uint32 mapId, uint16 version, uint16 tileId)
        external
        view
        override
        returns (binderStructs.TileDefinition memory)
    {
        _requireTile(mapId, version, tileId);
        return _tiles[mapId][version][tileId];
    }

    function getTiles(uint32 mapId, uint16 version, uint256 offset, uint256 limit)
        external
        view
        override
        returns (binderStructs.TileDefinition[] memory)
    {
        _requireMapVersion(mapId, version);
        uint256 tileCount = _tileCount(_mapDefinitions[mapId][version]);
        if (offset >= tileCount || limit == 0) return new binderStructs.TileDefinition[](0);
        uint256 available = tileCount - offset;
        uint256 pageLength = limit < available ? limit : available;
        binderStructs.TileDefinition[] memory page = new binderStructs.TileDefinition[](pageLength);
        for (uint256 i; i < pageLength; ++i) {
            page[i] = _tiles[mapId][version][uint16(offset + i + 1)];
        }
        return page;
    }

    function getInternalCoordinates(uint32 mapId, uint16 version, uint16 tileId)
        external
        view
        override
        returns (uint16 x, uint16 y, int16 z)
    {
        binderStructs.MapDefinition memory definition = _requireTile(mapId, version, tileId);
        uint256 index = uint256(tileId) - 1;
        x = uint16(index % definition.width);
        y = uint16(index / definition.width);
        z = _tiles[mapId][version][tileId].elevation;
    }

    function getDisplayCoordinates(uint32 mapId, uint16 version, uint16 tileId)
        external
        view
        override
        returns (uint16 x, uint16 y, int16 z)
    {
        binderStructs.MapDefinition memory definition = _requireTile(mapId, version, tileId);
        uint256 index = uint256(tileId) - 1;
        x = uint16(index % definition.width) + 1;
        y = uint16(index / definition.width) + 1;
        z = _tiles[mapId][version][tileId].elevation;
    }

    function isWalkable(uint32 mapId, uint16 version, uint16 tileId) external view override returns (bool) {
        _requireTile(mapId, version, tileId);
        return _tiles[mapId][version][tileId].walkable;
    }

    function _storeMapVersion(
        binderStructs.MapDefinition calldata definition,
        binderStructs.TileDefinition[] calldata tiles
    ) internal {
        _validateMapDefinition(definition, tiles.length);
        uint32 mapId = definition.mapId;
        uint16 version = definition.version;
        if (_versionExists[mapId][version]) revert InvalidMapVersion(version);

        _mapDefinitions[mapId][version] = definition;
        _versionExists[mapId][version] = true;
        _versions[mapId].push(version);
        _currentVersion[mapId] = version;
        _currentEnabled[mapId] = definition.enabled;

        for (uint256 i; i < tiles.length; ++i) {
            uint16 expectedTileId = uint16(i + 1);
            binderStructs.TileDefinition calldata tile = tiles[i];
            if (tile.tileId != expectedTileId || (tile.walkable && tile.movementCost == 0)) {
                revert InvalidTileDefinition(tile.tileId);
            }
            _tiles[mapId][version][expectedTileId] = tile;
        }

        emit MapVersionConfigured(mapId, version, definition.enabled, definition.width, definition.height);
    }

    function _validateMapDefinition(binderStructs.MapDefinition calldata definition, uint256 suppliedTileCount)
        internal
        pure
    {
        if (
            definition.mapId == 0 || definition.version == 0 || definition.width == 0 || definition.height == 0
                || bytes(definition.name).length == 0
        ) revert InvalidMapDefinition();
        uint256 expectedTileCount = uint256(definition.width) * definition.height;
        if (expectedTileCount > type(uint16).max || suppliedTileCount != expectedTileCount) {
            revert InvalidMapDefinition();
        }
    }

    function _requireMap(uint32 mapId) internal view {
        if (!_mapExists[mapId]) revert MapDoesNotExist(mapId);
    }

    function _requireMapVersion(uint32 mapId, uint16 version) internal view {
        _requireMap(mapId);
        if (!_versionExists[mapId][version]) revert MapVersionDoesNotExist(mapId, version);
    }

    function _requireTile(uint32 mapId, uint16 version, uint16 tileId)
        internal
        view
        returns (binderStructs.MapDefinition memory definition)
    {
        _requireMapVersion(mapId, version);
        definition = _mapDefinitions[mapId][version];
        if (tileId == BinderIds.INVALID_TILE_ID || tileId > _tileCount(definition)) revert InvalidTileId(tileId);
    }

    function _tileCount(binderStructs.MapDefinition memory definition) internal pure returns (uint256) {
        return uint256(definition.width) * definition.height;
    }
}
