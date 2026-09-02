// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Narrow read API for canonical player allegiance and nation validation.
interface IAllegianceRegistry {
    function getPlayerNation(address player) external view returns (uint8);
    function isNationRegistered(uint8 nationId) external view returns (bool);
}
