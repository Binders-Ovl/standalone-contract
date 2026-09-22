// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Shared JSON string escaping for Binder and item metadata.
library JsonStringLib {
    function escape(string memory raw) internal pure returns (string memory) {
        bytes memory source = bytes(raw);
        bytes memory escaped = new bytes(source.length * 6);
        uint256 outputLength;
        bytes16 hexSymbols = "0123456789abcdef";

        for (uint256 i; i < source.length; ++i) {
            bytes1 char = source[i];
            if (char == '"' || char == "\\") {
                escaped[outputLength++] = "\\";
                escaped[outputLength++] = char;
            } else if (char == bytes1(0x08)) {
                escaped[outputLength++] = "\\";
                escaped[outputLength++] = "b";
            } else if (char == bytes1(0x0c)) {
                escaped[outputLength++] = "\\";
                escaped[outputLength++] = "f";
            } else if (char == bytes1(0x0a)) {
                escaped[outputLength++] = "\\";
                escaped[outputLength++] = "n";
            } else if (char == bytes1(0x0d)) {
                escaped[outputLength++] = "\\";
                escaped[outputLength++] = "r";
            } else if (char == bytes1(0x09)) {
                escaped[outputLength++] = "\\";
                escaped[outputLength++] = "t";
            } else if (uint8(char) < 0x20) {
                escaped[outputLength++] = "\\";
                escaped[outputLength++] = "u";
                escaped[outputLength++] = "0";
                escaped[outputLength++] = "0";
                escaped[outputLength++] = hexSymbols[uint8(char) >> 4];
                escaped[outputLength++] = hexSymbols[uint8(char) & 0x0f];
            } else {
                escaped[outputLength++] = char;
            }
        }
        assembly ("memory-safe") {
            mstore(escaped, outputLength)
        }
        return string(escaped);
    }
}
