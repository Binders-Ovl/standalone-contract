// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../supportContract/binderStructs.sol";

/// @notice Shared mint/fusion allocator. Book0fLife validates budget <= available capacity.
/// @dev Preserves the established seeded allocation order and per-stat outcome.
library StatAllocationLib {
    function allocate(binderStructs.ClassConfig memory config, bytes32 seed)
        internal
        pure
        returns (binderStructs.StaticStats memory stats)
    {
        stats = binderStructs.StaticStats({stats: config.minStats});
        uint16 remainingPoints = config.totalPoints;
        uint8[8] memory statOrder = _generateAllocationOrder(seed);
        uint8[32] memory byteOrder = _generateBytesOrder(seed);
        uint8 usedBytes;

        while (remainingPoints > 0 && usedBytes < 32) {
            for (uint8 i = 0; i < 8 && remainingPoints > 0; ++i) {
                if (usedBytes >= 32) break;
                uint8 statIndex = statOrder[i];
                uint8 current = stats.stats[statIndex];
                uint8 maxAdd = config.maxStats[statIndex] - current;
                uint8 randByte = uint8(seed[byteOrder[usedBytes++]]);
                if (maxAdd == 0) continue;
                uint16 allocation = randByte % (uint16(maxAdd) + 1);
                if (allocation > remainingPoints) allocation = remainingPoints;
                stats.stats[statIndex] = current + uint8(allocation);
                remainingPoints -= allocation;
            }
        }

        while (remainingPoints > 0) {
            for (uint8 i = 0; i < 8 && remainingPoints > 0; ++i) {
                uint8 statIndex = statOrder[i];
                if (stats.stats[statIndex] >= config.maxStats[statIndex]) continue;
                ++stats.stats[statIndex];
                --remainingPoints;
            }
        }
    }

    function _generateAllocationOrder(bytes32 seed) private pure returns (uint8[8] memory order) {
        order = [0, 1, 2, 3, 4, 5, 6, 7];
        for (uint8 i = 7; i > 0; --i) {
            uint8 j = uint8(seed[i]) % (i + 1);
            (order[i], order[j]) = (order[j], order[i]);
        }
    }

    function _generateBytesOrder(bytes32 seed) private pure returns (uint8[32] memory order) {
        for (uint8 i = 0; i < 32; ++i) {
            order[i] = i;
        }
        for (uint8 i = 31; i > 0; --i) {
            uint8 j = uint8(seed[i]) % (i + 1);
            (order[i], order[j]) = (order[j], order[i]);
        }
    }
}
