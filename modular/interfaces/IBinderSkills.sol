// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Read API for the canonical, separately stored learned-skill repertoire.
interface IBinderSkills {
    function binderData() external view returns (address);
    function getMoveSets(uint256 tokenId) external view returns (uint32[3] memory);
    function hasActiveSkill(uint256 tokenId, uint32 artId) external view returns (bool);
    function hasPassiveSkill(uint256 tokenId, uint32 artId) external view returns (bool);
    function getActiveSkillCount(uint256 tokenId) external view returns (uint256);
    function getPassiveSkillCount(uint256 tokenId) external view returns (uint256);
    function getActiveSkills(uint256 tokenId, uint256 offset, uint256 limit) external view returns (uint32[] memory);
    function getPassiveSkills(uint256 tokenId, uint256 offset, uint256 limit) external view returns (uint32[] memory);
}
