// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Base64} from "@openzeppelin/contracts-4.8/utils/Base64.sol";
import {StatAllocationLib} from "../modular/libraries/StatAllocationLib.sol";
import {JsonStringLib} from "../modular/libraries/JsonStringLib.sol";
import {ItemMetadataBuilder} from "../modular/Items/ItemMetadataBuilder.sol";
import {binderStructs} from "../modular/supportContract/binderStructs.sol";

contract SharedHelpersTest is Test {
    function testFuzzAllocatorPreservesLegacyResults(
        bytes32 seed,
        uint8[8] memory minimums,
        uint8[8] memory gaps,
        uint16 points
    ) public pure {
        binderStructs.ClassConfig memory cfg;
        uint256 capacity;
        for (uint256 i; i < 8; ++i) {
            cfg.minStats[i] = uint8(bound(minimums[i], 1, 255));
            uint8 gap = uint8(bound(gaps[i], 0, 255 - cfg.minStats[i]));
            cfg.maxStats[i] = cfg.minStats[i] + gap;
            capacity += gap;
        }
        cfg.totalPoints = uint16(bound(points, 0, capacity));
        // Allocate receives memory arrays; isolate each call from memory aliases.
        binderStructs.StaticStats memory legacy =
            legacyAllocate(abi.decode(abi.encode(cfg), (binderStructs.ClassConfig)), seed);
        binderStructs.StaticStats memory shared =
            StatAllocationLib.allocate(abi.decode(abi.encode(cfg), (binderStructs.ClassConfig)), seed);
        assertEq(abi.encode(shared), abi.encode(legacy));
        uint256 added;
        for (uint256 i; i < 8; ++i) {
            assertGe(shared.stats[i], cfg.minStats[i]);
            assertLe(shared.stats[i], cfg.maxStats[i]);
            added += shared.stats[i] - cfg.minStats[i];
        }
        assertEq(added, cfg.totalPoints);
    }

    function testJsonEscapesControlCharactersAndItemMetadata() public {
        string memory raw = string(abi.encodePacked(bytes1(0x22), bytes1(0x5c), bytes1(0x0a), bytes1(0x01)));
        string memory escaped = JsonStringLib.escape(raw);
        string memory json = string.concat(
            '{"name":"',
            escaped,
            '","image":"',
            escaped,
            '","attributes":[{"trait_type":"Item ID","value":7},{"trait_type":"Config Version","value":2}]}'
        );
        assertEq(vm.parseJsonString(json, ".name"), raw);
        assertEq(vm.parseJsonString(json, ".image"), raw);
        ItemMetadataBuilder renderer = new ItemMetadataBuilder();
        assertEq(
            renderer.tokenURI(raw, raw, 7, 2),
            string.concat("data:application/json;base64,", Base64.encode(bytes(json)))
        );
    }

    // Frozen pre-refactor implementation: independent oracle, never imported by production.
    function legacyAllocate(binderStructs.ClassConfig memory config, bytes32 seed)
        internal
        pure
        returns (binderStructs.StaticStats memory stats)
    {
        stats = binderStructs.StaticStats({stats: config.minStats});
        uint16 remainingPoints = config.totalPoints;
        bytes memory entropyBytes = abi.encodePacked(seed);
        uint8[8] memory statOrder = _generateAllocationOrder(seed);
        uint8[32] memory byteOrder = _generateBytesOrder(seed);
        uint8 usedBytes;

        while (remainingPoints > 0 && usedBytes < 32) {
            for (uint8 i = 0; i < 8 && remainingPoints > 0; ++i) {
                if (usedBytes >= 32) break;
                uint8 statIndex = statOrder[i];
                uint8 current = stats.stats[statIndex];
                uint8 maxAdd = config.maxStats[statIndex] - current;
                uint8 randByte = uint8(entropyBytes[byteOrder[usedBytes++]]);
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
