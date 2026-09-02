// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-4.8/token/ERC721/IERC721.sol";
import "../supportContract/binderStructs.sol";

/// @notice Cross-module API for canonical BinderData state and authorized mutations.
/// @dev Deliberately excludes administrative role management and renderer configuration.
interface IBinderData is IERC721 {
    function _mintRandomNFT(
        address recipient,
        uint256 classId,
        string calldata className,
        uint8 rarityId,
        string calldata rarityName,
        binderStructs.StaticStats calldata staticStats,
        binderStructs.DynamicStats calldata dynamicStats
    ) external returns (uint256);

    function _mint4Fusion(
        address recipient,
        uint256 classId,
        string calldata className,
        uint8 rarityId,
        string calldata rarityName,
        binderStructs.StaticStats calldata staticStats,
        binderStructs.DynamicStats calldata dynamicStats
    ) external returns (uint256);

    function tfToGraveyard(uint256 tokenId) external;
    function startActivity(uint256 tokenId, uint8 activityId, uint48 lockedUntil) external;
    function endActivity(uint256 tokenId) external;
    function updateNFTStats(
        uint256 tokenId,
        binderStructs.StaticStats calldata stats,
        binderStructs.DynamicStats calldata dynamicStats
    ) external;
    function updateCurrentStats(uint256 tokenId, uint16 currentHP, uint16 currentMP) external;
    function registerBattleProxy(uint256 tokenId, address battleProxy) external;
    function clearBattleProxy(uint256 tokenId, address battleProxy) external;
    function checkpointBattleVitals(
        uint256[] calldata tokenIds,
        uint16[] calldata hpValues,
        uint16[] calldata mpValues,
        uint32 checkpointNonce
    ) external;
    function settleBattleVitals(
        uint256[] calldata tokenIds,
        uint16[] calldata hpValues,
        uint16[] calldata mpValues,
        uint32 checkpointNonce
    ) external;
    function setClassVersion(uint256 classId, uint16 version) external;
    function refreshAllMetadata() external;
    function refreshMetadata(uint256 tokenId) external;

    function getUnitState(uint256 tokenId) external view returns (binderStructs.UnitStateView memory);
    function getNFTClass(uint256 tokenId) external view returns (uint256);
    function getNFTRarityId(uint256 tokenId) external view returns (uint8);
    function getConfigVersion(uint256 tokenId) external view returns (uint16);
    function getNFTDetails(uint256 tokenId) external view returns (binderStructs.NFTMetadata memory);
    function getActivityController(uint8 activityId) external view returns (address);
    function classVersion(uint256 classId) external view returns (uint16);
    function baseImageURI() external view returns (string memory);
    function activeBattleProxy(uint256 tokenId) external view returns (address);
    function battleCheckpointNonce(uint256 tokenId) external view returns (uint32);
}
