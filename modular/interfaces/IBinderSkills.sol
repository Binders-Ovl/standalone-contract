// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./IBook0fItems.sol";
import "./IBinderInventory.sol";

/// @notice Read API for the canonical, separately stored learned-skill repertoire.
interface IBinderSkills {
    function binderData() external view returns (address);
    function centralConsole() external view returns (address);
    function book0fItems() external view returns (IBook0fItems);
    function binderInventory() external view returns (IBinderInventory);
    function setCentralConsole(address newCentralConsole) external;
    function setTomeLearningDependencies(
        address bookAddress,
        address inventoryAddress,
        address entropyAddress,
        address providerAddress
    ) external;
    function getMoveSets(uint256 tokenId) external view returns (uint32[3] memory);
    function hasActiveSkill(uint256 tokenId, uint32 artId) external view returns (bool);
    function hasPassiveSkill(uint256 tokenId, uint32 artId) external view returns (bool);
    function getLearnedArtVersion(uint256 tokenId, uint32 artId) external view returns (uint16);
    function getActiveSkillCount(uint256 tokenId) external view returns (uint256);
    function getPassiveSkillCount(uint256 tokenId) external view returns (uint256);
    function getActiveSkills(uint256 tokenId, uint256 offset, uint256 limit) external view returns (uint32[] memory);
    function getPassiveSkills(uint256 tokenId, uint256 offset, uint256 limit) external view returns (uint32[] memory);
}
