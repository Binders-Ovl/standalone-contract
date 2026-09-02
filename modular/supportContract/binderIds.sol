// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Stable protocol-level identifiers shared by contracts and libraries.
/// @dev Dynamic Art, map, class, and activity definitions remain Book data; this
/// source only names reserved/core values whose meaning must never be reordered.
library BinderIds {
    uint8 internal constant STAT_STR = 0;
    uint8 internal constant STAT_INT = 1;
    uint8 internal constant STAT_AGI = 2;
    uint8 internal constant STAT_DEX = 3;
    uint8 internal constant STAT_VIT = 4;
    uint8 internal constant STAT_WIS = 5;
    uint8 internal constant STAT_SPD = 6;
    uint8 internal constant STAT_STA = 7;
    uint8 internal constant STAT_COUNT = 8;

    uint8 internal constant ART_TYPE_INVALID = 0;
    uint8 internal constant ART_TYPE_MOVE_SET = 1;
    uint8 internal constant ART_TYPE_ACTIVE = 2;
    uint8 internal constant ART_TYPE_PASSIVE = 3;

    uint8 internal constant EFFECT_TYPE_INVALID = 0;
    uint8 internal constant EFFECT_TYPE_DAMAGE = 1;
    uint8 internal constant EFFECT_TYPE_HEAL = 2;
    uint8 internal constant EFFECT_TYPE_BUFF = 3;
    uint8 internal constant EFFECT_TYPE_DEBUFF = 4;
    uint8 internal constant EFFECT_TYPE_RESOURCE = 5;
    uint8 internal constant EFFECT_TYPE_AILMENT = 6;

    uint8 internal constant PATTERN_TYPE_INVALID = 0;
    uint8 internal constant PATTERN_TYPE_SINGLE = 1;
    uint8 internal constant PATTERN_TYPE_AREA = 2;
    uint8 internal constant PATTERN_TYPE_LINE = 3;
    uint8 internal constant PATTERN_TYPE_CONE = 4;
    uint8 internal constant PATTERN_TYPE_SELF = 5;

    uint8 internal constant ACTION_TYPE_INVALID = 0;
    uint8 internal constant ACTION_TYPE_MOVE = 1;
    uint8 internal constant ACTION_TYPE_MOVE_SET = 2;
    uint8 internal constant ACTION_TYPE_ACTIVE_ART = 3;
    uint8 internal constant ACTION_TYPE_ITEM = 4;
    uint8 internal constant ACTION_TYPE_GUARD = 5;
    uint8 internal constant ACTION_TYPE_RETREAT = 6;
    uint8 internal constant ACTION_TYPE_WAIT = 7;

    uint8 internal constant FORMULA_SOURCE_INVALID = 0;
    uint8 internal constant FORMULA_SOURCE_ACTOR = 1;
    uint8 internal constant FORMULA_SOURCE_TARGET = 2;

    uint8 internal constant ACTIVITY_IDLE = 0;
    uint8 internal constant ACTIVITY_BATTLE = 1;
    uint8 internal constant INVALID_AILMENT_ID = 0;
    uint8 internal constant MIN_AILMENT_ID = 1;
    uint8 internal constant MAX_AILMENT_ID = type(uint8).max;
    uint16 internal constant INVALID_TILE_ID = 0;
    uint8 internal constant MOVE_SET_SLOTS = 3;
    uint8 internal constant MAX_FORMULA_TERMS = 8;
    uint8 internal constant MAX_BATTLE_PARTICIPANTS = 12;
    uint8 internal constant MAX_BATTLE_LOADOUT_ARTS = 8;

    bytes32 internal constant MODULE_BINDER_DATA = keccak256("BINDERS_MODULE_BINDER_DATA");
    bytes32 internal constant MODULE_BINDER_SKILLS = keccak256("BINDERS_MODULE_BINDER_SKILLS");
    bytes32 internal constant MODULE_BINDER_METADATA = keccak256("BINDERS_MODULE_BINDER_METADATA");
    bytes32 internal constant MODULE_BOOK_OF_LIFE = keccak256("BINDERS_MODULE_BOOK_OF_LIFE");
    bytes32 internal constant MODULE_BOOK_OF_ARTS = keccak256("BINDERS_MODULE_BOOK_OF_ARTS");
    bytes32 internal constant MODULE_BOOK_OF_REALMS = keccak256("BINDERS_MODULE_BOOK_OF_REALMS");
    bytes32 internal constant MODULE_BINDER_LOGIC = keccak256("BINDERS_MODULE_BINDER_LOGIC");
    bytes32 internal constant MODULE_FUSION_MINTER = keccak256("BINDERS_MODULE_FUSION_MINTER");
    bytes32 internal constant MODULE_SCALE_OF_BALANCE = keccak256("BINDERS_MODULE_SCALE_OF_BALANCE");
    bytes32 internal constant MODULE_BATTLE_FACTORY = keccak256("BINDERS_MODULE_BATTLE_FACTORY");
    bytes32 internal constant MODULE_ALLEGIANCE_REGISTRY = keccak256("BINDERS_MODULE_ALLEGIANCE_REGISTRY");
}
