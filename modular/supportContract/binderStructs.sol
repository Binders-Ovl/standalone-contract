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
        uint16 maxHP;           // Max Possible HP of an Unit
        uint16 maxMP;           // Max Possible MP of an Unit
        uint16 currentHP;       // Current HP of an Unit
        uint16 currentMP;       // Current MP of an Unit
    }

    struct ClassConfig {
        uint8[8] minStats;      // Minimum baseline stats of an unit [STR|INT|AGI|DEX|VIT|WIS|SPD|STA]
        uint8[8] maxStats;      // Maximum value stats of an unit [STR|INT|AGI|DEX|VIT|WIS|SPD|STA]
        uint16 totalPoints;     // Allocation Point
        uint16 hpPerVit;        // MaxHP modifier
        uint16 mpPerWis;        // MaxMP modifier
    }

    // === Fusion outcome and Recipes ===
    struct FusionRequest {
        address user;
        uint256 nftId1;
        uint256 nftId2;
        bool resolved;
    }

    /** @dev placeHolder for future updateable probablity based on weight
        as of now just to populate for easier lookup at  FusionRecipe
    */
    struct FusionOutcome {
        uint256 outcomeClassId;         // Possible outcome class ID
        uint16 multiProbChance;         // Weighted chance in 100.00%
    }

    struct FusionRecipe {
        FusionOutcome[] outcomes;       // Array of possible outcomes
        uint16 successChance;           // Success chance in 100.00% | Defining wether fusion is success or not
    }

    /** Legacy Code of FUSIONOUTCOME
    struct LegacyFusionOutcome {
        uint256 outcomeClassId; // TargetedClass ID if fusion success
        uint16 successChance;   // Success chance in 100.00%
    }
     */

    /** @notice: Advance fusion used for more thn 1 unit fusion later */
    struct AdvancedFusionRequest {
        address user;
        uint256[] nftIds;
        bytes32 recipeHash;
        bool resolved;
    }

    /** @notice: Advance fusion used for catalyst fusion later */
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
        uint256 class1;         // Class ID of NFT 1  
        uint256 class2;         // Class ID of NFT 2
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
        uint16 configVersion;           // Version of Config that unit is currently on [Check : classVersion for global variable]
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
}
