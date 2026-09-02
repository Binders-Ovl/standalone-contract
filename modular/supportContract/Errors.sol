// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Shared custom errors for repeated protocol semantics.
/// @dev This is a source module, not a deployed contract. Module-specific errors
/// may remain local where they express a uniquely local invariant.
/// @dev Some entries are reserved for upcoming Godot battle-flow error decoding.
error UnauthorizedController(address caller);
error InvalidArtId(uint32 artId);
error InvalidMapId(uint32 mapId);
error InvalidTileId(uint16 tileId);
error MoveSetSlotsFull(uint256 tokenId);
error SkillAlreadyLearned(uint256 tokenId, uint32 artId);
error InvalidBattleProxy(address proxy);
error InvalidCheckpointNonce(uint256 tokenId, uint64 expectedNonce, uint64 providedNonce);
error IllegalMove(uint256 tokenId, uint16 fromTileId, uint16 toTileId);
error IllegalTarget(uint256 actorTokenId, uint256 targetTokenId);
error InsufficientResource(uint256 tokenId, uint256 requiredAmount, uint256 availableAmount);
error InvalidAilmentId(uint8 ailmentId);
error BookMigrationMismatch(bytes32 expectedHash, bytes32 actualHash);
error CanonicalPairMismatch(address expectedBinderData, address actualBinderData);
error CanonicalSkillsMismatch(address expectedSkills, address actualSkills);
error UnitNotIdle(uint256 tokenId, uint8 activityId);
error InvalidModuleAddress(bytes32 moduleId, address moduleAddress);
error InvalidInitialOwner(address initialOwner);
error UnknownCanonicalModule(bytes32 moduleId);
error InvalidModuleVersion(bytes32 moduleId, uint32 currentVersion, uint32 proposedVersion);
error InvalidActivityModuleId(uint8 activityId);
error InvalidFormulaTermCount(uint8 termCount);
error InvalidFormulaSource(uint8 sourceId);
error InvalidFormulaStatId(uint8 statId);
error FormulaArithmeticOverflow();
error InvalidGridDimensions(uint16 width, uint16 height);
error TileOutOfBounds(uint16 tileId, uint16 tileCount);
