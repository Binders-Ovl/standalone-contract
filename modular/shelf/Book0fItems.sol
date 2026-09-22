// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-4.8/access/AccessControl.sol";
import "../Items/ItemStruct.sol";
import "../interfaces/IBook0fItems.sol";
import "../interfaces/IBook0fArts.sol";

/// @notice Canonical, versioned gameplay configuration for item collections.
contract Book0fItems is AccessControl, IBook0fItems {
    bytes32 public constant ITEMS_CONFIG_ROLE = keccak256("ITEMS_CONFIG_ROLE");
    uint8 public constant PAGE_CAP = 50;

    mapping(uint16 => EqConfig) private _eq;
    mapping(uint16 => TomeConfig) private _tome;
    mapping(uint16 => SItemConfig) private _sItem;
    uint16 private _nextEqId;
    uint16 private _nextTomeId;
    uint16 private _nextSItemId;
    IBook0fArts public immutable book0fArts;

    event EqConfigured(uint16 indexed eqId, uint32 version, bool enabled);
    event TomeConfigured(uint16 indexed tomeId, uint32 version, bool enabled);
    event SItemConfigured(uint16 indexed sItemId, uint32 version, bool enabled);
    event ItemsConfigAuthorityUpdated(address indexed previousAuthority, address indexed newAuthority);

    error InvalidItemConfig();
    error ItemDoesNotExist(uint16 itemId);
    error PageTooLarge(uint256 size);

    constructor(address centralConsole, address scale0fBalance, address book0fArtsAddress) {
        if (centralConsole == address(0) || scale0fBalance == address(0) || book0fArtsAddress.code.length == 0) {
            revert InvalidItemConfig();
        }
        book0fArts = IBook0fArts(book0fArtsAddress);
        _grantRole(DEFAULT_ADMIN_ROLE, centralConsole);
        _grantRole(ITEMS_CONFIG_ROLE, centralConsole);
        _grantRole(ITEMS_CONFIG_ROLE, scale0fBalance);
    }

    function setItemsConfigAuthority(address previousAuthority, address newAuthority)
        external
        onlyRole(ITEMS_CONFIG_ROLE)
    {
        if (newAuthority == address(0)) revert InvalidItemConfig();
        _grantRole(ITEMS_CONFIG_ROLE, newAuthority);
        if (previousAuthority != address(0) && previousAuthority != newAuthority) {
            _revokeRole(ITEMS_CONFIG_ROLE, previousAuthority);
        }
        emit ItemsConfigAuthorityUpdated(previousAuthority, newAuthority);
    }

    function addEq(EqConfig calldata cfg) external onlyRole(ITEMS_CONFIG_ROLE) returns (uint16 eqId) {
        _validateEq(cfg);
        eqId = ++_nextEqId;
        _storeEq(eqId, cfg, 1);
    }

    function updateEq(uint16 eqId, EqConfig calldata cfg) external onlyRole(ITEMS_CONFIG_ROLE) {
        if (!_eq[eqId].exists) revert ItemDoesNotExist(eqId);
        _validateEq(cfg);
        _storeEq(eqId, cfg, _eq[eqId].configVersion + 1);
    }

    function deactivateEq(uint16 eqId) external onlyRole(ITEMS_CONFIG_ROLE) {
        EqConfig storage cfg = _eq[eqId];
        if (!cfg.exists) revert ItemDoesNotExist(eqId);
        cfg.enabled = false;
        ++cfg.configVersion;
        emit EqConfigured(eqId, cfg.configVersion, false);
    }

    function addTome(TomeConfig calldata cfg) external onlyRole(ITEMS_CONFIG_ROLE) returns (uint16 tomeId) {
        _validateTome(cfg);
        tomeId = ++_nextTomeId;
        _storeTome(tomeId, cfg, 1);
    }

    function updateTome(uint16 tomeId, TomeConfig calldata cfg) external onlyRole(ITEMS_CONFIG_ROLE) {
        if (!_tome[tomeId].exists) revert ItemDoesNotExist(tomeId);
        _validateTome(cfg);
        _storeTome(tomeId, cfg, _tome[tomeId].configVersion + 1);
    }

    function deactivateTome(uint16 tomeId) external onlyRole(ITEMS_CONFIG_ROLE) {
        TomeConfig storage cfg = _tome[tomeId];
        if (!cfg.exists) revert ItemDoesNotExist(tomeId);
        cfg.enabled = false;
        ++cfg.configVersion;
        emit TomeConfigured(tomeId, cfg.configVersion, false);
    }

    function addSItem(SItemConfig calldata cfg) external onlyRole(ITEMS_CONFIG_ROLE) returns (uint16 sItemId) {
        _validateSItem(cfg);
        sItemId = ++_nextSItemId;
        _storeSItem(sItemId, cfg, 1);
    }

    function updateSItem(uint16 sItemId, SItemConfig calldata cfg) external onlyRole(ITEMS_CONFIG_ROLE) {
        if (!_sItem[sItemId].exists) revert ItemDoesNotExist(sItemId);
        _validateSItem(cfg);
        _storeSItem(sItemId, cfg, _sItem[sItemId].configVersion + 1);
    }

    function deactivateSItem(uint16 sItemId) external onlyRole(ITEMS_CONFIG_ROLE) {
        SItemConfig storage cfg = _sItem[sItemId];
        if (!cfg.exists) revert ItemDoesNotExist(sItemId);
        cfg.enabled = false;
        ++cfg.configVersion;
        emit SItemConfigured(sItemId, cfg.configVersion, false);
    }

    function getEq(uint16 eqId) external view returns (EqConfig memory) {
        return _eq[eqId];
    }

    function getTome(uint16 tomeId) external view returns (TomeConfig memory) {
        return _tome[tomeId];
    }

    function getSItem(uint16 sItemId) external view returns (SItemConfig memory) {
        return _sItem[sItemId];
    }

    function isEqEnabled(uint16 eqId) external view returns (bool) {
        return _eq[eqId].exists && _eq[eqId].enabled;
    }

    function isTomeEnabled(uint16 tomeId) external view returns (bool) {
        return _tome[tomeId].exists && _tome[tomeId].enabled;
    }

    function isSItemEnabled(uint16 sItemId) external view returns (bool) {
        return _sItem[sItemId].exists && _sItem[sItemId].enabled;
    }

    function getEqPage(uint16 cursor, uint256 size) external view returns (EqConfig[] memory page) {
        if (size > PAGE_CAP) revert PageTooLarge(size);
        return _eqPage(cursor, size);
    }

    function getTomePage(uint16 cursor, uint256 size) external view returns (TomeConfig[] memory page) {
        if (size > PAGE_CAP) revert PageTooLarge(size);
        return _tomePage(cursor, size);
    }

    function getSItemPage(uint16 cursor, uint256 size) external view returns (SItemConfig[] memory page) {
        if (size > PAGE_CAP) revert PageTooLarge(size);
        return _sItemPage(cursor, size);
    }

    function _storeEq(uint16 id, EqConfig calldata source, uint32 version) private {
        EqConfig storage target = _eq[id];
        target.exists = true;
        target.enabled = source.enabled;
        target.configVersion = version;
        target.itemName = source.itemName;
        target.rarityId = source.rarityId;
        target.slot = source.slot;
        target.allowedClassIds = source.allowedClassIds;
        target.statsReq = source.statsReq;
        target.statsChgInc = source.statsChgInc;
        target.statsChgDec = source.statsChgDec;
        emit EqConfigured(id, version, source.enabled);
    }

    function _storeTome(uint16 id, TomeConfig calldata source, uint32 version) private {
        TomeConfig storage target = _tome[id];
        target.exists = true;
        target.enabled = source.enabled;
        target.configVersion = version;
        target.itemName = source.itemName;
        target.rarityId = source.rarityId;
        target.artId = source.artId;
        target.learnSuccessBps = source.learnSuccessBps;
        target.burnPolicy = source.burnPolicy;
        emit TomeConfigured(id, version, source.enabled);
    }

    function _storeSItem(uint16 id, SItemConfig calldata source, uint32 version) private {
        SItemConfig storage target = _sItem[id];
        target.exists = true;
        target.enabled = source.enabled;
        target.configVersion = version;
        target.itemName = source.itemName;
        target.rarityId = source.rarityId;
        target.category = source.category;
        target.maximumStack = source.maximumStack;
        target.vendorValue = source.vendorValue;
        target.effectCount = source.effectCount;
        for (uint256 i; i < 8; ++i) {
            target.effects[i] = source.effects[i];
        }
        emit SItemConfigured(id, version, source.enabled);
    }

    function _validateEq(EqConfig calldata cfg) private pure {
        if (bytes(cfg.itemName).length == 0 || cfg.allowedClassIds.length > 16) revert InvalidItemConfig();
        for (uint256 i; i < cfg.allowedClassIds.length; ++i) {
            if (cfg.allowedClassIds[i] == 0) revert InvalidItemConfig();
            for (uint256 j; j < i; ++j) {
                if (cfg.allowedClassIds[i] == cfg.allowedClassIds[j]) revert InvalidItemConfig();
            }
        }
        for (uint256 i; i < 8; ++i) {
            if (cfg.statsChgInc[i] != 0 && cfg.statsChgDec[i] != 0) revert InvalidItemConfig();
        }
    }

    function _validateTome(TomeConfig calldata cfg) private view {
        if (
            bytes(cfg.itemName).length == 0 || cfg.artId == 0 || cfg.learnSuccessBps == 0
                || cfg.learnSuccessBps > 10_000 || !book0fArts.artExists(cfg.artId)
        ) revert InvalidItemConfig();
    }

    function _validateSItem(SItemConfig calldata cfg) private view {
        if (bytes(cfg.itemName).length == 0 || cfg.maximumStack == 0 || cfg.effectCount > 8) revert InvalidItemConfig();
        if (
            (cfg.category == SItemCategory.MATERIAL || cfg.category == SItemCategory.VENDOR_GOOD)
                && cfg.effectCount != 0
        ) {
            revert InvalidItemConfig();
        }
        for (uint256 i; i < 8; ++i) {
            if (i < cfg.effectCount) _validateEffect(cfg.effects[i]);
            else if (!_isZeroEffect(cfg.effects[i])) revert InvalidItemConfig();
        }
    }

    function _validateEffect(ItemEffect calldata effect) private view {
        bool statsZero = _statsZero(effect.statDelta);
        if (effect.kind == ItemEffectKind.MODIFY_CUR_HP || effect.kind == ItemEffectKind.MODIFY_CUR_MP) {
            if (
                effect.amount == 0 || effect.refId != 0 || effect.durationSeconds != 0 || !statsZero
                    || effect.target == ItemTarget.TILE
            ) {
                revert InvalidItemConfig();
            }
        } else if (effect.kind == ItemEffectKind.TEMP_STAT_DELTA) {
            if (
                effect.scope != ItemUseScope.BATTLE_ONLY || effect.refId != 0 || effect.amount != 0
                    || effect.durationSeconds == 0 || statsZero
            ) {
                revert InvalidItemConfig();
            }
        } else if (effect.kind == ItemEffectKind.CURE_AILMENT) {
            if (
                effect.scope != ItemUseScope.BATTLE_ONLY || effect.refId == 0 || effect.amount != 0
                    || effect.durationSeconds != 0 || !statsZero
            ) {
                revert InvalidItemConfig();
            }
        } else if (effect.kind == ItemEffectKind.APPLY_AILMENT) {
            if (
                effect.scope != ItemUseScope.BATTLE_ONLY || effect.refId == 0 || effect.amount != 0
                    || effect.durationSeconds == 0 || !statsZero
            ) {
                revert InvalidItemConfig();
            }
        } else if (effect.kind == ItemEffectKind.CAST_ART) {
            if (
                effect.scope != ItemUseScope.BATTLE_ONLY || effect.refId == 0 || effect.amount != 0
                    || effect.durationSeconds != 0 || !statsZero || !book0fArts.artExists(effect.refId)
                    || !book0fArts.isArtItemCastable(effect.refId)
            ) {
                revert InvalidItemConfig();
            }
        } else if (effect.kind == ItemEffectKind.PLACE_BATTLE_OBJECT) {
            if (
                effect.scope != ItemUseScope.BATTLE_ONLY || effect.refId == 0 || effect.amount != 0
                    || effect.durationSeconds != 0 || !statsZero || effect.target != ItemTarget.TILE
            ) {
                revert InvalidItemConfig();
            }
        }
    }

    function _isZeroEffect(ItemEffect calldata effect) private pure returns (bool) {
        return effect.refId == 0 && effect.amount == 0 && effect.durationSeconds == 0 && _statsZero(effect.statDelta)
            && effect.scope == ItemUseScope.WORLD_ONLY && effect.target == ItemTarget.SELF
            && effect.kind == ItemEffectKind.MODIFY_CUR_HP;
    }

    function _statsZero(int16[8] calldata stats) private pure returns (bool) {
        for (uint256 i; i < 8; ++i) {
            if (stats[i] != 0) return false;
        }
        return true;
    }

    function _eqPage(uint16 cursor, uint256 size) private view returns (EqConfig[] memory page) {
        uint256 start = uint256(cursor) + 1;
        if (start > _nextEqId || size == 0) return new EqConfig[](0);
        uint256 count = _nextEqId - start + 1;
        if (count > size) count = size;
        page = new EqConfig[](count);
        for (uint256 i; i < count; ++i) {
            page[i] = _eq[uint16(start + i)];
        }
    }

    function _tomePage(uint16 cursor, uint256 size) private view returns (TomeConfig[] memory page) {
        uint256 start = uint256(cursor) + 1;
        if (start > _nextTomeId || size == 0) return new TomeConfig[](0);
        uint256 count = _nextTomeId - start + 1;
        if (count > size) count = size;
        page = new TomeConfig[](count);
        for (uint256 i; i < count; ++i) {
            page[i] = _tome[uint16(start + i)];
        }
    }

    function _sItemPage(uint16 cursor, uint256 size) private view returns (SItemConfig[] memory page) {
        uint256 start = uint256(cursor) + 1;
        if (start > _nextSItemId || size == 0) return new SItemConfig[](0);
        uint256 count = _nextSItemId - start + 1;
        if (count > size) count = size;
        page = new SItemConfig[](count);
        for (uint256 i; i < count; ++i) {
            page[i] = _sItem[uint16(start + i)];
        }
    }
}
