// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

enum ItemFamily {
    EQUIPMENT,
    TOME_OR_GRIMOIRE,
    SITEM
}

enum EquipmentSlot {
    HEADGEAR,
    CHEST_PIECE,
    WEAPON,
    OFF_HAND,
    MISC
}

enum TomeBurnPolicy {
    ON_SUCCESS,
    ON_ATTEMPT
}

enum SItemCategory {
    MATERIAL,
    VENDOR_GOOD,
    CONSUMABLE,
    BATTLE_OBJECT
}

enum ItemUseScope {
    WORLD_ONLY,
    BATTLE_ONLY,
    WORLD_OR_BATTLE
}

enum ItemTarget {
    SELF,
    ALLY,
    ENEMY,
    TILE
}

enum ItemEffectKind {
    MODIFY_CUR_HP,
    MODIFY_CUR_MP,
    TEMP_STAT_DELTA,
    CURE_AILMENT,
    APPLY_AILMENT,
    CAST_ART,
    PLACE_BATTLE_OBJECT
}

struct ItemEffect {
    ItemEffectKind kind;
    ItemUseScope scope;
    ItemTarget target;
    uint32 refId;
    int32 amount;
    int16[8] statDelta;
    uint32 durationSeconds;
}

struct EqConfig {
    bool exists;
    bool enabled;
    uint32 configVersion;
    string itemName;
    uint16 rarityId;
    EquipmentSlot slot;
    uint256[] allowedClassIds;
    uint16[8] statsReq;
    uint16[8] statsChgInc;
    uint16[8] statsChgDec;
}

struct TomeConfig {
    bool exists;
    bool enabled;
    uint32 configVersion;
    string itemName;
    uint16 rarityId;
    uint32 artId;
    uint16 learnSuccessBps;
    TomeBurnPolicy burnPolicy;
}

struct SItemConfig {
    bool exists;
    bool enabled;
    uint32 configVersion;
    string itemName;
    uint16 rarityId;
    SItemCategory category;
    uint128 maximumStack;
    uint128 vendorValue;
    uint8 effectCount;
    ItemEffect[8] effects;
}

struct InventorySlot {
    ItemFamily family;
    uint16 libraryId;
    uint256 instanceTokenId;
    uint128 amount;
    bool occupied;
    bool equipped;
    EquipmentSlot equippedAs;
}
