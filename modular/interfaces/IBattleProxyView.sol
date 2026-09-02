// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Narrow live-state read surface for clients while a match is active.
/// @dev Game clients use this rather than decoding NFT metadata JSON in battle.
interface IBattleProxyView {
    function isActive() external view returns (bool);
    function actionNumber() external view returns (uint32);
    function mapId() external view returns (uint32);
    function mapVersion() external view returns (uint16);
    function participantCount() external view returns (uint256);
    function getCurrentVitals(uint256 tokenId) external view returns (uint16 currentHP, uint16 currentMP, bool alive);
    function getPosition(uint256 tokenId) external view returns (uint16);
    function getArtVersion(uint32 artId) external view returns (uint16);
}
