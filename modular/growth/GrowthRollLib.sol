// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {binderStructs} from "../supportContract/binderStructs.sol";

/// @notice Pure CP5.1b roll schedule. No custody, eligibility, reward issuance or extra entropy requests.
library GrowthRollLib {
    error InvalidChance();
    error InvalidRange();
    error InvalidStat();
    error EmptyWeightTable();
    error GrowthOverflow();

    /// @dev The complete roll participates in the comparison, not a truncated uint16.
    function chance(uint256 roll, uint16 bps) internal pure returns (bool) {
        if (bps > 10_000) revert InvalidChance();
        return roll % 10_000 < bps;
    }

    function expand(bytes32 seed, bytes32 activityId, bytes32 domain, uint256 index) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, activityId, domain, index)));
    }

    /// @notice Validate every reachable exclusion path, including valid sparse profiles.
    /// @dev Configuration-time only; settlement picks exactly three stats, without retries.
    function validateProfile(binderStructs.GrowthStatProfile memory profile) internal pure {
        uint8 first = _support(profile.primaryWeights);
        uint8 second = _support(profile.secondaryWeights);
        uint8 third = _support(profile.tertiaryWeights);
        if (first == 0) revert EmptyWeightTable();
        for (uint8 i; i < 8; ++i) {
            if ((first & (uint8(1) << i)) == 0) continue;
            uint8 remaining = second & ~(uint8(1) << i);
            if (remaining == 0) revert EmptyWeightTable();
            for (uint8 j; j < 8; ++j) {
                if ((remaining & (uint8(1) << j)) == 0) continue;
                if ((third & ~((uint8(1) << i) | (uint8(1) << j))) == 0) revert EmptyWeightTable();
            }
        }
        for (uint256 i; i < 3; ++i) {
            if (profile.minDeltas[i] > profile.maxDeltas[i]) revert InvalidRange();
        }
    }

    function drill(bytes32 seed, uint16 successBps, uint8 stat, uint32 minGain, uint32 maxGain)
        internal
        pure
        returns (bool success, int32[8] memory deltas)
    {
        if (stat >= 8) revert InvalidStat();
        if (minGain > maxGain || maxGain > uint32(type(int32).max)) revert InvalidRange();
        success = chance(uint64(uint256(seed) >> 192), successBps);
        if (success) {
            // Amount half of the first stat/amount slice; Drill's stat is chosen by the player.
            deltas[stat] = amount(uint32(uint256(seed) >> 128), int32(minGain), int32(maxGain));
        }
    }

    function xDrill(bytes32 seed, uint16 successBps, binderStructs.GrowthStatProfile memory profile)
        internal
        pure
        returns (bool success, int32[8] memory deltas)
    {
        success = chance(uint64(uint256(seed) >> 192), successBps);
        if (!success) return (success, deltas);
        uint8 excluded;
        for (uint256 i; i < 3; ++i) {
            uint64 slice = uint64(uint256(seed) >> (128 - i * 64));
            uint8 stat = pick(uint32(slice >> 32), _weights(profile, i), excluded);
            excluded |= uint8(1) << stat;
            deltas[stat] = amount(uint32(slice), profile.minDeltas[i], profile.maxDeltas[i]);
        }
    }

    function errantry(
        bytes32 seed,
        bytes32 activityId,
        uint16 successBps,
        binderStructs.GrowthStatProfile memory profile
    ) internal pure returns (bool success, int32[8] memory deltas) {
        success = chance(expand(seed, activityId, "ERRANTRY_SUCCESS", 0), successBps);
        if (success) deltas = _expandedStats(seed, activityId, "ERRANTRY_STAT", "ERRANTRY_AMOUNT", profile);
    }

    function questStats(bytes32 seed, bytes32 activityId, binderStructs.GrowthStatProfile memory profile)
        internal
        pure
        returns (int32[8] memory)
    {
        return _expandedStats(seed, activityId, "QUEST_STAT", "QUEST_AMOUNT", profile);
    }

    function pick(uint256 roll, uint16[8] memory weights, uint8 excluded) internal pure returns (uint8) {
        uint256 total;
        for (uint8 i; i < 8; ++i) {
            if ((excluded & (uint8(1) << i)) == 0) total += weights[i];
        }
        if (total == 0) revert EmptyWeightTable();
        uint256 target = roll % total;
        for (uint8 i; i < 8; ++i) {
            if ((excluded & (uint8(1) << i)) != 0) continue;
            if (target < weights[i]) return i;
            target -= weights[i];
        }
        revert EmptyWeightTable();
    }

    function amount(uint256 roll, int32 minimum, int32 maximum) internal pure returns (int32) {
        if (minimum > maximum) revert InvalidRange();
        uint256 width = uint256(int256(maximum) - int256(minimum)) + 1;
        return int32(int256(minimum) + int256(roll % width));
    }

    /// @notice Discard floor-clamped damage; never retain it as debt against a later gain.
    function applyDelta(uint8 base, int32 stored, int32 change) internal pure returns (int32 updated, uint32 swg) {
        int256 current = int256(uint256(base)) + stored;
        if (current < 1) current = 1;
        int256 next = current + change;
        if (next < 1) next = 1;
        int256 delta = next - int256(uint256(base));
        if (delta > type(int32).max) revert GrowthOverflow();
        updated = int32(delta);
        swg = uint32(uint256(next));
    }

    function _expandedStats(
        bytes32 seed,
        bytes32 activityId,
        bytes32 statDomain,
        bytes32 amountDomain,
        binderStructs.GrowthStatProfile memory profile
    ) private pure returns (int32[8] memory deltas) {
        uint8 excluded;
        for (uint256 i; i < 3; ++i) {
            uint8 stat = pick(expand(seed, activityId, statDomain, i), _weights(profile, i), excluded);
            excluded |= uint8(1) << stat;
            deltas[stat] = amount(expand(seed, activityId, amountDomain, i), profile.minDeltas[i], profile.maxDeltas[i]);
        }
    }

    function _weights(binderStructs.GrowthStatProfile memory profile, uint256 index)
        private
        pure
        returns (uint16[8] memory)
    {
        if (index == 0) return profile.primaryWeights;
        if (index == 1) return profile.secondaryWeights;
        return profile.tertiaryWeights;
    }

    function _support(uint16[8] memory weights) private pure returns (uint8 mask) {
        for (uint8 i; i < 8; ++i) {
            if (weights[i] != 0) mask |= uint8(1) << i;
        }
    }
}
