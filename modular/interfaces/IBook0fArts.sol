// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../supportContract/binderStructs.sol";

/// @notice Read API for versioned Art definitions used by metadata and battle modules.
interface IBook0fArts {
    function getRewardPool(uint32 poolId) external view returns (uint32[] memory);
    function setRewardPool(uint32 poolId, uint32[] calldata artIds) external;
    function BALANCE_ROLE() external view returns (bytes32);
    function setScaleOfBalanceAuthority(address previousScale, address newScale) external;
    function updateArtBalance(binderStructs.ArtDefinition calldata definition, uint256[] calldata eligibleClassIds)
        external;
    function getArtCount() external view returns (uint256);
    function getArtIdAt(uint256 index) external view returns (uint32);
    function getArtIds(uint256 offset, uint256 limit) external view returns (uint32[] memory);
    function artExists(uint32 artId) external view returns (bool);
    function getArtDefinition(uint32 artId) external view returns (binderStructs.ArtDefinition memory);
    function getArtDefinitionAtVersion(uint32 artId, uint16 version)
        external
        view
        returns (binderStructs.ArtDefinition memory);
    function getArtVersionCount(uint32 artId) external view returns (uint256);
    function getArtVersionAt(uint32 artId, uint256 index) external view returns (uint16);
    function getArtVersions(uint32 artId, uint256 offset, uint256 limit) external view returns (uint16[] memory);
    function isArtEnabled(uint32 artId) external view returns (bool);
    function isArtItemCastable(uint32 artId) external view returns (bool);
    function isClassEligible(uint32 artId, uint16 version, uint256 classId) external view returns (bool);
    function getEligibleClassIds(uint32 artId, uint16 version, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory);
}
