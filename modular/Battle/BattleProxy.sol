// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-4.8/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-4.8/token/ERC721/IERC721Receiver.sol";
import "../supportContract/binderIds.sol";
import "../supportContract/Errors.sol";
import "../interfaces/IBattleFactory.sol";
import "../interfaces/IBattleProxyView.sol";
import "../interfaces/IBinderData.sol";
import "../interfaces/IBinderSkills.sol";
import "../interfaces/IBook0fArts.sol";
import "../interfaces/IBook0fRealms.sol";
import "../libraries/ArtFormulaLib.sol";
import "../libraries/GridMathLib.sol";
import "../supportContract/binderStructs.sol";

/// @notice Per-match clone holding authoritative, temporary Battle state.
/// @dev This Phase 6 referee supports single/self Damage and Heal Arts. Its
/// address and selected Art-version records are fixed at initialization, so a
/// Book replacement or later Book edit cannot change an active match's rules.
contract BattleProxy is Initializable, IERC721Receiver, IBattleProxyView {
    struct InitializationParams {
        address factoryAddress;
        address binderDataAddress;
        address binderSkillsAddress;
        address book0fArtsAddress;
        address book0fRealmsAddress;
        uint32 requestedMapId;
        uint16 requestedMapVersion;
        uint256[] tokenIds;
        uint16[] spawnTileIds;
        uint32[][] selectedArtIds;
    }

    struct BattleUnit {
        address controller;
        uint8[8] baseStats;
        uint16 maxHP;
        uint16 maxMP;
        uint16 currentHP;
        uint16 currentMP;
        uint16 tileId;
        uint256 activeAilments;
        bool alive;
        bool guardActive;
    }

    struct BattleUnitView {
        address controller;
        uint8[8] baseStats;
        uint16 maxHP;
        uint16 maxMP;
        uint16 currentHP;
        uint16 currentMP;
        uint16 tileId;
        uint256 activeAilments;
        bool alive;
        bool guardActive;
    }

    address public factory;
    IBinderData public binderData;
    IBinderSkills public binderSkills;
    IBook0fArts public book0fArts;
    IBook0fRealms public book0fRealms;
    uint32 public override mapId;
    uint16 public override mapVersion;
    uint16 public mapWidth;
    uint16 public mapHeight;
    bool public override isActive;
    uint32 public override actionNumber;
    uint32 public checkpointNonce;
    uint16 public dirtyUnitBitmap;

    uint256[] private _participantIds;
    mapping(uint256 => BattleUnit) private _units;
    mapping(uint256 => uint8) private _participantIndexPlusOne;
    mapping(uint256 => mapping(uint32 => bool)) private _selectedArts;
    mapping(uint32 => uint16) private _artVersions;

    event BattleInitialized(
        address indexed factory,
        address indexed book0fArts,
        address indexed book0fRealms,
        uint32 mapId,
        uint16 mapVersion,
        uint256 participantCount
    );
    event ActionDeclared(uint32 indexed actionNumber, uint256 indexed actorTokenId, uint8 actionTypeId, uint32 referenceId);
    event ArtUsed(
        uint32 indexed actionNumber,
        uint256 indexed actorTokenId,
        uint256 indexed targetTokenId,
        uint32 artId,
        int256 hpDelta,
        uint16 actorHPAfter,
        uint16 actorMPAfter,
        uint16 targetHPAfter
    );
    event BattleCancelled(address indexed caller, uint256 participantCount);
    event BattleVitalsPulsed(uint32 indexed checkpointNonce, uint16 dirtyUnitBitmap, uint256 participantCount);
    event BattleSettled(uint32 indexed checkpointNonce, uint256 survivorCount);

    error OnlyFactory(address caller);
    error BattleInactive();
    error BattleAlreadyHasActions(uint32 actionCount);
    error InvalidBattleInput();
    error DuplicateBattleToken(uint256 tokenId);
    error DuplicateSpawnTile(uint16 tileId);
    error UnauthorizedBattleActor(uint256 tokenId, address caller);
    error BattleUnitNotAlive(uint256 tokenId);
    error ArtNotSelected(uint256 tokenId, uint32 artId);
    error ArtNotLearned(uint256 tokenId, uint32 artId);
    error UnsupportedBattleArtType(uint8 artTypeId);
    error UnsupportedBattlePattern(uint8 patternTypeId);
    error UnsupportedBattleEffect(uint8 effectTypeId);
    error InvalidBattleTarget(uint256 tokenId);
    error TargetOutOfRange(uint256 actorTokenId, uint256 targetTokenId, uint16 distance, uint16 range);
    error InsufficientBattleResource(uint256 tokenId, uint16 currentHP, uint16 currentMP, uint16 hpCost, uint16 mpCost);
    error UnexpectedERC721(address token, address operator);
    error BattleNotReadyForSettlement(uint256 livingUnits);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(InitializationParams calldata params) external initializer {
        if (msg.sender != params.factoryAddress) revert OnlyFactory(msg.sender);
        if (
            params.factoryAddress.code.length == 0 || params.binderDataAddress.code.length == 0
                || params.binderSkillsAddress.code.length == 0 || params.book0fArtsAddress.code.length == 0
                || params.book0fRealmsAddress.code.length == 0 || params.tokenIds.length < 2
                || params.tokenIds.length > BinderIds.MAX_BATTLE_PARTICIPANTS
                || params.tokenIds.length != params.spawnTileIds.length || params.tokenIds.length != params.selectedArtIds.length
        ) revert InvalidBattleInput();

        factory = params.factoryAddress;
        binderData = IBinderData(params.binderDataAddress);
        binderSkills = IBinderSkills(params.binderSkillsAddress);
        book0fArts = IBook0fArts(params.book0fArtsAddress);
        book0fRealms = IBook0fRealms(params.book0fRealmsAddress);
        mapId = params.requestedMapId;
        mapVersion = params.requestedMapVersion;

        binderStructs.MapDefinition memory map = book0fRealms.getMapAtVersion(params.requestedMapId, params.requestedMapVersion);
        if (!map.enabled) revert InvalidBattleInput();
        mapWidth = map.width;
        mapHeight = map.height;

        for (uint256 index; index < params.tokenIds.length; ++index) {
            _initializeUnit(
                params.tokenIds[index], params.spawnTileIds[index], params.selectedArtIds[index], uint16(map.width * map.height)
            );
        }
        isActive = true;
        _emitBattleInitialized();
    }

    function participantCount() external view override returns (uint256) {
        return _participantIds.length;
    }

    function getParticipantIds(uint256 offset, uint256 limit) external view returns (uint256[] memory) {
        uint256 count = _participantIds.length;
        if (offset >= count || limit == 0) return new uint256[](0);
        uint256 pageLength = limit < count - offset ? limit : count - offset;
        uint256[] memory page = new uint256[](pageLength);
        for (uint256 index; index < pageLength; ++index) page[index] = _participantIds[offset + index];
        return page;
    }

    function getBattleUnit(uint256 tokenId) external view returns (BattleUnitView memory) {
        BattleUnit storage unit = _requireParticipant(tokenId);
        return BattleUnitView({
            controller: unit.controller,
            baseStats: unit.baseStats,
            maxHP: unit.maxHP,
            maxMP: unit.maxMP,
            currentHP: unit.currentHP,
            currentMP: unit.currentMP,
            tileId: unit.tileId,
            activeAilments: unit.activeAilments,
            alive: unit.alive,
            guardActive: unit.guardActive
        });
    }

    function getCurrentVitals(uint256 tokenId) external view override returns (uint16 currentHP, uint16 currentMP, bool alive) {
        BattleUnit storage unit = _requireParticipant(tokenId);
        return (unit.currentHP, unit.currentMP, unit.alive);
    }

    function getPosition(uint256 tokenId) external view override returns (uint16) {
        return _requireParticipant(tokenId).tileId;
    }

    function getArtVersion(uint32 artId) external view override returns (uint16) {
        return _artVersions[artId];
    }

    function isArtSelected(uint256 tokenId, uint32 artId) external view returns (bool) {
        return _selectedArts[tokenId][artId];
    }

    /// @notice Referee action: numerical effects are calculated locally, never supplied by the caller.
    function useArt(uint256 actorTokenId, uint32 artId, uint256 targetTokenId) external {
        if (!isActive) revert BattleInactive();
        BattleUnit storage actor = _requireParticipant(actorTokenId);
        if (actor.controller != msg.sender) revert UnauthorizedBattleActor(actorTokenId, msg.sender);
        if (!actor.alive) revert BattleUnitNotAlive(actorTokenId);
        if (!_selectedArts[actorTokenId][artId]) revert ArtNotSelected(actorTokenId, artId);

        uint16 artVersion = _artVersions[artId];
        if (artVersion == 0) revert ArtNotSelected(actorTokenId, artId);
        binderStructs.ArtDefinition memory art = book0fArts.getArtDefinitionAtVersion(artId, artVersion);
        if (art.artTypeId != BinderIds.ART_TYPE_MOVE_SET && art.artTypeId != BinderIds.ART_TYPE_ACTIVE) {
            revert UnsupportedBattleArtType(art.artTypeId);
        }
        if (!ArtFormulaLib.canPayCosts(actor.currentHP, actor.currentMP, art.hpCost, art.mpCost)) {
            revert InsufficientBattleResource(actorTokenId, actor.currentHP, actor.currentMP, art.hpCost, art.mpCost);
        }

        BattleUnit storage target = _requireParticipant(targetTokenId);
        if (!target.alive) revert BattleUnitNotAlive(targetTokenId);
        _validateTargetPattern(actorTokenId, targetTokenId, art);

        actor.currentHP -= art.hpCost;
        actor.currentMP -= art.mpCost;
        int256 formulaResult = ArtFormulaLib.evaluate(art.primaryFormula, _asEffectiveStats(actor), _asEffectiveStats(target));
        uint16 actorHPAfterCost = actor.currentHP;
        uint16 actorMPAfterCost = actor.currentMP;
        uint16 targetHPBefore = target.currentHP;
        int256 hpDelta = _applyEffect(art.effectTypeId, target, formulaResult);
        if (actorHPAfterCost != _units[actorTokenId].currentHP || actorMPAfterCost != _units[actorTokenId].currentMP) {
            // Kept for clarity if a future effect mutates the actor after costs.
            _markDirty(actorTokenId);
        } else if (art.hpCost != 0 || art.mpCost != 0) {
            _markDirty(actorTokenId);
        }
        if (target.currentHP != targetHPBefore) _markDirty(targetTokenId);

        ++actionNumber;
        emit ActionDeclared(actionNumber, actorTokenId, art.artTypeId, artId);
        emit ArtUsed(
            actionNumber,
            actorTokenId,
            targetTokenId,
            artId,
            hpDelta,
            actor.currentHP,
            actor.currentMP,
            target.currentHP
        );
    }

    /// @notice Commits only changed local vitals at an explicit safe action boundary.
    /// @dev Anyone may trigger a pulse, but the payload is assembled solely from
    /// this proxy's local state and is validated by BinderData provenance/nonce checks.
    function checkpointDirtyVitals() external {
        if (!isActive) revert BattleInactive();
        uint16 bitmap = dirtyUnitBitmap;
        if (bitmap == 0) return;

        uint256 dirtyCount;
        for (uint256 index; index < _participantIds.length; ++index) {
            if ((bitmap & (uint16(1) << uint16(index))) != 0) ++dirtyCount;
        }
        uint256[] memory tokenIds = new uint256[](dirtyCount);
        uint16[] memory hpValues = new uint16[](dirtyCount);
        uint16[] memory mpValues = new uint16[](dirtyCount);
        uint256 outputIndex;
        for (uint256 index; index < _participantIds.length; ++index) {
            if ((bitmap & (uint16(1) << uint16(index))) == 0) continue;
            uint256 tokenId = _participantIds[index];
            BattleUnit storage unit = _units[tokenId];
            tokenIds[outputIndex] = tokenId;
            hpValues[outputIndex] = unit.currentHP;
            mpValues[outputIndex] = unit.currentMP;
            ++outputIndex;
        }

        uint32 nextNonce = checkpointNonce + 1;
        binderData.checkpointBattleVitals(tokenIds, hpValues, mpValues, nextNonce);
        checkpointNonce = nextNonce;
        dirtyUnitBitmap = 0;
        emit BattleVitalsPulsed(nextNonce, bitmap, dirtyCount);
    }

    /// @notice Permissionlessly settles a match after combat has reduced it to at most one living unit.
    /// @dev Survivors are returned via the stable factory gateway; zero-HP units
    /// are moved to BinderData's configured graveyard by final settlement.
    function settleDefeatedBattle() external {
        if (!isActive) revert BattleInactive();
        uint256 survivors;
        for (uint256 index; index < _participantIds.length; ++index) {
            if (_units[_participantIds[index]].alive) ++survivors;
        }
        if (survivors > 1) revert BattleNotReadyForSettlement(survivors);

        uint256 count = _participantIds.length;
        uint256[] memory tokenIds = new uint256[](count);
        uint16[] memory hpValues = new uint16[](count);
        uint16[] memory mpValues = new uint16[](count);
        uint256[] memory survivorIds = new uint256[](survivors);
        uint256 survivorIndex;
        for (uint256 index; index < count; ++index) {
            uint256 tokenId = _participantIds[index];
            BattleUnit storage unit = _units[tokenId];
            tokenIds[index] = tokenId;
            hpValues[index] = unit.currentHP;
            mpValues[index] = unit.currentMP;
            if (unit.alive) survivorIds[survivorIndex++] = tokenId;
        }

        uint32 nextNonce = checkpointNonce + 1;
        // Set inactive before external calls; a revert restores it atomically.
        isActive = false;
        binderData.settleBattleVitals(tokenIds, hpValues, mpValues, nextNonce);
        IBattleFactory(factory).endBattle(survivorIds);
        for (uint256 index; index < survivorIds.length; ++index) {
            uint256 tokenId = survivorIds[index];
            binderData.safeTransferFrom(address(this), _units[tokenId].controller, tokenId);
        }
        checkpointNonce = nextNonce;
        dirtyUnitBitmap = 0;
        emit BattleSettled(nextNonce, survivors);
    }

    /// @notice Returns all escrowed NFTs before any referee action has occurred.
    /// @dev This is a draft-stage escape hatch only; post-action settlement,
    /// pulses, and timeout resolution are introduced in Phase 7.
    function cancelUnstarted() external {
        if (!isActive) revert BattleInactive();
        if (actionNumber != 0) revert BattleAlreadyHasActions(actionNumber);
        _requireParticipantController(msg.sender);
        _endAndReturnAll();
        emit BattleCancelled(msg.sender, _participantIds.length);
    }

    function onERC721Received(address operator, address, uint256, bytes calldata) external view override returns (bytes4) {
        if (msg.sender != address(binderData) || operator != factory) revert UnexpectedERC721(msg.sender, operator);
        return IERC721Receiver.onERC721Received.selector;
    }

    function _initializeUnit(uint256 tokenId, uint16 spawnTileId, uint32[] calldata loadout, uint16 tileCount) internal {
        if (_units[tokenId].controller != address(0)) revert DuplicateBattleToken(tokenId);
        if (loadout.length > BinderIds.MAX_BATTLE_LOADOUT_ARTS) revert InvalidBattleInput();
        for (uint256 index; index < _participantIds.length; ++index) {
            if (_units[_participantIds[index]].tileId == spawnTileId) revert DuplicateSpawnTile(spawnTileId);
        }
        // Confirms map bounds before state is persisted; terrain and occupancy are separate checks.
        GridMathLib.internalCoordinates(spawnTileId, mapWidth, tileCount);

        binderStructs.NFTMetadata memory metadata = binderData.getNFTDetails(tokenId);
        _units[tokenId] = BattleUnit({
            controller: binderData.ownerOf(tokenId),
            baseStats: metadata.staticStats.stats,
            maxHP: metadata.dynamicStats.maxHP,
            maxMP: metadata.dynamicStats.maxMP,
            currentHP: metadata.dynamicStats.currentHP,
            currentMP: metadata.dynamicStats.currentMP,
            tileId: spawnTileId,
            activeAilments: 0,
            alive: metadata.dynamicStats.currentHP != 0,
            guardActive: false
        });
        _participantIds.push(tokenId);
        _participantIndexPlusOne[tokenId] = uint8(_participantIds.length);

        for (uint256 index; index < loadout.length; ++index) {
            uint32 artId = loadout[index];
            if (artId == 0 || _selectedArts[tokenId][artId]) revert InvalidBattleInput();
            if (!_isLearned(tokenId, artId)) revert ArtNotLearned(tokenId, artId);
            binderStructs.ArtDefinition memory art = book0fArts.getArtDefinition(artId);
            if (!art.enabled) revert InvalidBattleInput();
            _selectedArts[tokenId][artId] = true;
            if (_artVersions[artId] == 0) _artVersions[artId] = art.version;
        }
    }

    function _isLearned(uint256 tokenId, uint32 artId) internal view returns (bool) {
        if (binderSkills.hasActiveSkill(tokenId, artId) || binderSkills.hasPassiveSkill(tokenId, artId)) return true;
        uint32[3] memory moveSets = binderSkills.getMoveSets(tokenId);
        for (uint256 index; index < moveSets.length; ++index) {
            if (moveSets[index] == artId) return true;
        }
        return false;
    }

    function _validateTargetPattern(uint256 actorTokenId, uint256 targetTokenId, binderStructs.ArtDefinition memory art)
        internal
        view
    {
        if (art.patternTypeId == BinderIds.PATTERN_TYPE_SELF) {
            if (actorTokenId != targetTokenId) revert InvalidBattleTarget(targetTokenId);
            return;
        }
        if (art.patternTypeId != BinderIds.PATTERN_TYPE_SINGLE) revert UnsupportedBattlePattern(art.patternTypeId);
        uint16 distance = GridMathLib.manhattanDistance(
            _units[actorTokenId].tileId, _units[targetTokenId].tileId, mapWidth, uint16(mapWidth * mapHeight)
        );
        if (distance > art.range) revert TargetOutOfRange(actorTokenId, targetTokenId, distance, art.range);
    }

    function _applyEffect(uint8 effectTypeId, BattleUnit storage target, int256 formulaResult)
        internal
        returns (int256 hpDelta)
    {
        uint16 beforeHP = target.currentHP;
        if (effectTypeId == BinderIds.EFFECT_TYPE_DAMAGE) {
            uint16 damage = ArtFormulaLib.clampDamage(formulaResult, beforeHP);
            target.currentHP = beforeHP - damage;
            if (target.currentHP == 0) target.alive = false;
        } else if (effectTypeId == BinderIds.EFFECT_TYPE_HEAL) {
            target.currentHP = ArtFormulaLib.clampResourceDelta(formulaResult, beforeHP, target.maxHP);
        } else {
            revert UnsupportedBattleEffect(effectTypeId);
        }
        hpDelta = int256(uint256(target.currentHP)) - int256(uint256(beforeHP));
    }

    function _asEffectiveStats(BattleUnit storage unit) internal view returns (uint256[8] memory stats) {
        for (uint256 index; index < stats.length; ++index) stats[index] = unit.baseStats[index];
    }

    function _markDirty(uint256 tokenId) internal {
        uint8 indexPlusOne = _participantIndexPlusOne[tokenId];
        if (indexPlusOne == 0) revert InvalidBattleTarget(tokenId);
        dirtyUnitBitmap |= uint16(1) << uint16(indexPlusOne - 1);
    }

    function _requireParticipant(uint256 tokenId) internal view returns (BattleUnit storage unit) {
        unit = _units[tokenId];
        if (unit.controller == address(0)) revert InvalidBattleTarget(tokenId);
    }

    function _requireParticipantController(address controller) internal view {
        for (uint256 index; index < _participantIds.length; ++index) {
            if (_units[_participantIds[index]].controller == controller) return;
        }
        revert UnauthorizedBattleActor(0, controller);
    }

    function _endAndReturnAll() internal {
        isActive = false;
        IBattleFactory(factory).endBattle(_participantIds);
        for (uint256 index; index < _participantIds.length; ++index) {
            uint256 tokenId = _participantIds[index];
            binderData.safeTransferFrom(address(this), _units[tokenId].controller, tokenId);
        }
    }

    function _emitBattleInitialized() internal {
        emit BattleInitialized(factory, address(book0fArts), address(book0fRealms), mapId, mapVersion, _participantIds.length);
    }
}
