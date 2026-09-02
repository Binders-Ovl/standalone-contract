// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library binderStructs {
    // @notice: Array of stats that determine unit stats in following order
    // STR  determine pATK (Weapon Based  Value)        ==>     uint8[0]
    // INT  determine mATK (Skill Based Value)          ==>     uint8[1]
    // AGI  Chance to hit                               ==>     uint8[2]
    // DEX  Chance to Dodge pATK                       ==>     uint8[3]
    // VIT  Detemine value of HP and pDef               ==>     uint8[4]
    // WIS  Determine value of MP and mDef              ==>     uint8[5]
    // SPD  Determine priority of actions               ==>     uint8[6]
    // STA  Determine value of movement range           ==>     uint8[7]

    // === UNIT Stats and Configuration ===
    struct StaticStats {
        uint8[8] stats; // STR, INT, AGI, DEX, VIT, WIS, SPD, STA
    }

    struct DynamicStats {
        uint16 maxHP; // Max Possible HP of an Unit
        uint16 maxMP; // Max Possible MP of an Unit
        uint16 currentHP; // Current HP of an Unit
        uint16 currentMP; // Current MP of an Unit
    }

    struct ClassConfig {
        uint8[8] minStats; // Minimum baseline stats of an unit [STR|INT|AGI|DEX|VIT|WIS|SPD|STA]
        uint8[8] maxStats; // Maximum value stats of an unit [STR|INT|AGI|DEX|VIT|WIS|SPD|STA]
        uint16 totalPoints; // Allocation Point
        uint16 hpPerVit; // MaxHP modifier
        uint16 mpPerWis; // MaxMP modifier
    }

    // === Fusion outcome and Recipes ===
    struct FusionRequest {
        address user;
        uint256 nftId1;
        uint256 nftId2;
        bool resolved;
    }

    /**
     * @dev placeHolder for future updateable probablity based on weight
     *     as of now just to populate for easier lookup at  FusionRecipe
     */
    struct FusionOutcome {
        uint256 outcomeClassId; // Possible outcome class ID
        uint16 multiProbChance; // Weighted chance in 100.00%
    }

    struct FusionRecipe {
        FusionOutcome[] outcomes; // Array of possible outcomes
        uint16 successChance; // Success chance in 100.00% | Defining wether fusion is success or not
    }

    /**
     * Legacy Code of FUSIONOUTCOME
     * struct LegacyFusionOutcome {
     *     uint256 outcomeClassId; // TargetedClass ID if fusion success
     *     uint16 successChance;   // Success chance in 100.00%
     * }
     */

    /**
     * @notice: Advance fusion used for more thn 1 unit fusion later
     */
    struct AdvancedFusionRequest {
        address user;
        uint256[] nftIds;
        bytes32 recipeHash;
        bool resolved;
    }

    /**
     * @notice: Advance fusion used for catalyst fusion later
     */
    struct ERC20Input {
        address token;
        uint256 amount;
    }

    struct ClassMeta {
        uint256 classId;
        string name;
        uint8 rarityId;
    }

    struct ClassPair {
        uint256 class1; // Class ID of NFT 1
        uint256 class2; // Class ID of NFT 2
    }

    struct AllSimpleFusionRecipe {
        uint256 class1;
        uint256 class2;
        FusionRecipe recipe;
    }

    // === NFT Metadata ===

    struct NFTMetadata {
        string name;
        uint256 classId;
        uint8 rarityId;
        StaticStats staticStats;
        DynamicStats dynamicStats;
        uint16 configVersion; // Version of Config that unit is currently on [Check : classVersion for global variable]
    }

    /// @notice Compact, authoritative per-token activity occupancy state.
    /// @dev activityId 0 is permanently Idle. `lockedUntil` is informational / an
    /// earliest completion marker only; controllers must explicitly clear activity.
    struct ActivityState {
        uint8 activityId;
        uint48 lockedUntil;
    }

    /// @notice Derived BinderData state used by integrations and renderers.
    /// @dev Only `activity` is persisted. The booleans are calculated on every read.
    struct UnitStateView {
        bool readyToArm;
        bool idle;
        bool transferable;
        ActivityState activity;
    }

    /// @notice Class-level event-mint availability. Nation rotation, when present,
    /// advances in fixed timestamp slots from startTime; calendar recurrence is
    /// deliberately outside this model.
    struct EventMintSchedule {
        bool enabled;
        uint48 startTime;
        uint48 endTime;
        uint32 slotDuration;
    }

    /// @notice One bounded structured component of a future Art formula.
    /// @dev Appended as a new type only; no existing stored struct layout changes.
    struct FormulaTerm {
        uint8 sourceId;
        uint8 statId;
        int16 coefficientBps;
    }

    /// @notice Bounded generic formula data consumed later by ArtFormulaLib.
    /// @dev `termCount` specifies the populated prefix of `terms`.
    struct Formula {
        uint8 formulaTypeId;
        uint8 termCount;
        FormulaTerm[8] terms;
        int32 flatValue;
    }

    /// @notice Versioned reusable Art/Skill definition owned by Book0fArts.
    struct ArtDefinition {
        uint32 artId;
        string name;
        uint8 artTypeId;
        uint16 hpCost;
        uint16 mpCost;
        uint8 effectTypeId;
        uint8 patternTypeId;
        uint16 range;
        Formula primaryFormula;
        Formula secondaryFormula;
        uint32 requirementFlags;
        uint8 ailmentId;
        uint16 version;
        bool enabled;
    }

    /// @notice Versioned rectangular-map header owned by Book0fRealms.
    struct MapDefinition {
        uint32 mapId;
        string name;
        uint16 width;
        uint16 height;
        uint16 version;
        bool enabled;
    }

    /// @notice Canonical tile definition. Tile IDs are local to one map version.
    struct TileDefinition {
        uint16 tileId;
        int16 elevation;
        uint32 terrainTypeId;
        uint32 terrainFlags;
        bool walkable;
        uint16 movementCost;
    }
}
