// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../supportContract/binderStructs.sol";

/// @notice Read API for versioned Art definitions used by metadata and battle modules.
interface IBook0fArts {
    function getArtCount() external view returns (uint256);
    function getArtIdAt(uint256 index) external view returns (uint32);
    function getArtIds(uint256 offset, uint256 limit) external view returns (uint32[] memory);
    function getArtDefinition(uint32 artId) external view returns (binderStructs.ArtDefinition memory);
    function getArtDefinitionAtVersion(uint32 artId, uint16 version)
        external
        view
        returns (binderStructs.ArtDefinition memory);
    function getArtVersionCount(uint32 artId) external view returns (uint256);
    function getArtVersionAt(uint32 artId, uint256 index) external view returns (uint16);
    function getArtVersions(uint32 artId, uint256 offset, uint256 limit) external view returns (uint16[] memory);
    function isArtEnabled(uint32 artId) external view returns (bool);
    function isClassEligible(uint32 artId, uint16 version, uint256 classId) external view returns (bool);
    function getEligibleClassIds(uint32 artId, uint16 version, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory);
}
