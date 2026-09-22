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
import "../interfaces/IBinderInventory.sol";
import "../libraries/ArtFormulaLib.sol";
import "../libraries/GridMathLib.sol";
import "../supportContract/binderStructs.sol";
import "../Items/ItemStruct.sol";

/// @notice Per-match clone holding authoritative, temporary Battle state.
/// @dev Its address and selected Art-version records are fixed at initialization,
/// so a Book replacement or later Book edit cannot change an active match's rules.
contract BattleProxy is Initializable, IERC721Receiver, IBattleProxyView {
    struct InitializationParams {
        address factoryAddress;
        address binderDataAddress;
        address binderSkillsAddress;
        address book0fArtsAddress;
        address book0fRealmsAddress;
        address inventoryAddress;
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
        int32[8] equipmentModifiers;
        uint256[5] equipmentTokenIds;
        uint32[5] equipmentConfigVersions;
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
        int32[8] equipmentModifiers;
        bool alive;
        bool guardActive;
    }

    struct TimedStatModifier {
        bytes32 key;
        int32[8] delta;
        uint64 expiresAt;
    }

    address public factory;
    IBinderData public binderData;
    IBinderSkills public binderSkills;
    IBook0fArts public book0fArts;
    IBook0fRealms public book0fRealms;
    IBinderInventory public binderInventory;
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
    mapping(uint256 => TimedStatModifier[]) private _temporaryModifiers;
    mapping(uint256 => mapping(bytes32 => uint16)) private _temporaryModifierIndex;
    mapping(uint256 => mapping(uint8 => uint64)) private _ailmentExpiry;

    event BattleInitialized(
        address indexed factory,
        address indexed book0fArts,
        address indexed book0fRealms,
        uint32 mapId,
        uint16 mapVersion,
        uint256 participantCount
    );
    event ActionDeclared(
        uint32 indexed actionNumber, uint256 indexed actorTokenId, uint8 actionTypeId, uint32 referenceId
    );
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
    event ItemUsed(uint32 indexed actionNumber, uint256 indexed actorTokenId, uint16 indexed sItemId, uint128 amount);
    event BattleCancelled(address indexed caller, uint256 participantCount);
    event BattleVitalsPulsed(uint32 indexed checkpointNonce, uint16 dirtyUnitBitmap, uint256 participantCount);
    event BattleSettled(uint32 indexed checkpointNonce, uint256 survivorCount);

    error OnlyFactory(address caller);
    error BattleInactive();
    error BattleAlreadyHasActions(uint32 actionCount);
    error InvalidBattleInput();
    error DuplicateBattleToken(uint256 tokenId);
    error DuplicateSpawnTile(uint16 tileId);
    error UnwalkableSpawnTile(uint16 tileId);
    error UnauthorizedBattleActor(uint256 tokenId, address caller);
    error BattleUnitNotAlive(uint256 tokenId);
    error ArtNotSelected(uint256 tokenId, uint32 artId);
    error ArtNotLearned(uint256 tokenId, uint32 artId);
    error BattleArtVersionStale(uint256 tokenId, uint32 artId, uint16 learnedVersion, uint16 currentVersion);
    error BattleArtUnavailable(uint32 artId);
    error BattleArtClassIneligible(uint256 tokenId, uint32 artId, uint256 classId, uint16 version);
    error UnsupportedBattleArtType(uint8 artTypeId);
    error UnsupportedBattlePattern(uint8 patternTypeId);
    error UnsupportedBattleEffect(uint8 effectTypeId);
    error InvalidBattleTarget(uint256 tokenId);
    error TargetOutOfRange(uint256 actorTokenId, uint256 targetTokenId, uint16 distance, uint16 range);
    error InsufficientBattleResource(uint256 tokenId, uint16 currentHP, uint16 currentMP, uint16 hpCost, uint16 mpCost);
    error UnexpectedERC721(address token, address operator);
    error BattleNotReadyForSettlement(uint256 livingUnits);
    error BattleItemsUnavailable();
    error BattleItemUnavailable(uint16 sItemId);
    error InvalidBattleItemTarget(uint256 target);
    error InvalidBattleItemAmount(uint128 amount);
    error BattleObjectsUnsupported(uint32 battleObjectId);
    error InvalidBattleAilmentId(uint32 ailmentId);

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
                || params.tokenIds.length != params.spawnTileIds.length
                || params.tokenIds.length != params.selectedArtIds.length
        ) revert InvalidBattleInput();

        factory = params.factoryAddress;
        binderData = IBinderData(params.binderDataAddress);
        binderSkills = IBinderSkills(params.binderSkillsAddress);
        book0fArts = IBook0fArts(params.book0fArtsAddress);
        book0fRealms = IBook0fRealms(params.book0fRealmsAddress);
        if (params.inventoryAddress != address(0)) {
            if (params.inventoryAddress.code.length == 0) revert InvalidBattleInput();
            binderInventory = IBinderInventory(params.inventoryAddress);
        }
        mapId = params.requestedMapId;
        mapVersion = params.requestedMapVersion;

        binderStructs.MapDefinition memory map =
            book0fRealms.getMapAtVersion(params.requestedMapId, params.requestedMapVersion);
        if (!map.enabled) revert InvalidBattleInput();
        mapWidth = map.width;
        mapHeight = map.height;

        for (uint256 index; index < params.tokenIds.length; ++index) {
            _initializeUnit(
                params.tokenIds[index],
                params.spawnTileIds[index],
                params.selectedArtIds[index],
                uint16(map.width * map.height)
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
        for (uint256 index; index < pageLength; ++index) {
            page[index] = _participantIds[offset + index];
        }
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
            equipmentModifiers: unit.equipmentModifiers,
            alive: unit.alive,
            guardActive: unit.guardActive
        });
    }

    function getCurrentVitals(uint256 tokenId)
        external
        view
        override
        returns (uint16 currentHP, uint16 currentMP, bool alive)
    {
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

    function getEquipmentSnapshot(uint256 tokenId)
        external
        view
        returns (uint256[5] memory tokenIds, int32[8] memory modifiers, uint32[5] memory configVersions)
    {
        BattleUnit storage unit = _requireParticipant(tokenId);
        return (unit.equipmentTokenIds, unit.equipmentModifiers, unit.equipmentConfigVersions);
    }

    function getTemporaryModifiers(uint256 tokenId) external view returns (int32[8] memory modifiers) {
        _requireParticipant(tokenId);
        TimedStatModifier[] storage active = _temporaryModifiers[tokenId];
        for (uint256 i; i < active.length; ++i) {
            if (active[i].expiresAt <= block.timestamp) continue;
            for (uint256 stat; stat < 8; ++stat) {
                modifiers[stat] += active[i].delta[stat];
            }
        }
    }

    function isAilmentActive(uint256 tokenId, uint8 ailmentId) external view returns (bool) {
        BattleUnit storage unit = _requireParticipant(tokenId);
        return ailmentId != 0 && (unit.activeAilments & (uint256(1) << ailmentId)) != 0
            && _ailmentExpiry[tokenId][ailmentId] > block.timestamp;
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
        (int256 hpDelta, uint16 actorHPAfter, uint16 actorMPAfter, uint16 targetHPAfter) =
            _resolveArt(actorTokenId, targetTokenId, art);

        ++actionNumber;
        emit ActionDeclared(actionNumber, actorTokenId, art.artTypeId, artId);
        emit ArtUsed(
            actionNumber, actorTokenId, targetTokenId, artId, hpDelta, actorHPAfter, actorMPAfter, targetHPAfter
        );
    }

    /// @notice Consumes a recognised SItem through Inventory and applies only its typed, battle-local effects.
    function useItem(uint256 actorTokenId, uint8 inventorySlot, uint128 amount, uint256 target) external {
        if (!isActive) revert BattleInactive();
        if (address(binderInventory) == address(0)) revert BattleItemsUnavailable();
        BattleUnit storage actor = _requireParticipant(actorTokenId);
        if (actor.controller != msg.sender) revert UnauthorizedBattleActor(actorTokenId, msg.sender);
        if (!actor.alive) revert BattleUnitNotAlive(actorTokenId);
        if (amount == 0) revert InvalidBattleItemAmount(amount);

        InventorySlot memory inventoryItem = binderInventory.getSlot(actorTokenId, inventorySlot);
        if (inventoryItem.family != ItemFamily.SITEM || inventoryItem.equipped || inventoryItem.amount < amount) {
            revert BattleItemUnavailable(inventoryItem.libraryId);
        }
        SItemConfig memory config = binderInventory.book().getSItem(inventoryItem.libraryId);
        if (!config.exists || !config.enabled || config.effectCount == 0) {
            revert BattleItemUnavailable(inventoryItem.libraryId);
        }
        _validateItemUse(actorTokenId, target, amount, config);

        uint16 sItemId = binderInventory.consumeSItemForBattle(actorTokenId, inventorySlot, amount);
        if (sItemId != inventoryItem.libraryId) revert BattleItemUnavailable(sItemId);
        for (uint8 i; i < config.effectCount; ++i) {
            _applyItemEffect(actorTokenId, target, amount, sItemId, i, config.effects[i]);
        }
        ++actionNumber;
        emit ActionDeclared(actionNumber, actorTokenId, BinderIds.ACTION_TYPE_ITEM, sItemId);
        emit ItemUsed(actionNumber, actorTokenId, sItemId, amount);
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

    /// @notice Permissionlessly settles a match after combat has reduced it to at most one living player.
    /// @dev Survivors are returned via the stable factory gateway; zero-HP units
    /// are moved to BinderData's configured graveyard by final settlement.
    function settleDefeatedBattle() external {
        if (!isActive) revert BattleInactive();
        uint256 livingControllers;
        address survivingController;
        for (uint256 index; index < _participantIds.length; ++index) {
            BattleUnit storage unit = _units[_participantIds[index]];
            if (!unit.alive) continue;
            if (survivingController == address(0)) {
                survivingController = unit.controller;
                livingControllers = 1;
            } else if (unit.controller != survivingController) {
                livingControllers = 2;
                break;
            }
        }
        if (livingControllers > 1) revert BattleNotReadyForSettlement(livingControllers);

        uint256 count = _participantIds.length;
        uint256[] memory tokenIds = new uint256[](count);
        uint16[] memory hpValues = new uint16[](count);
        uint16[] memory mpValues = new uint16[](count);
        uint256 survivorCount;
        for (uint256 index; index < count; ++index) {
            if (_units[_participantIds[index]].alive) ++survivorCount;
        }
        uint256[] memory survivorIds = new uint256[](survivorCount);
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
        emit BattleSettled(nextNonce, survivorCount);
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

    function onERC721Received(address operator, address, uint256, bytes calldata)
        external
        view
        override
        returns (bytes4)
    {
        if (msg.sender != address(binderData) || operator != factory) revert UnexpectedERC721(msg.sender, operator);
        return IERC721Receiver.onERC721Received.selector;
    }

    function _initializeUnit(uint256 tokenId, uint16 spawnTileId, uint32[] calldata loadout, uint16 tileCount)
        internal
    {
        if (_units[tokenId].controller != address(0)) revert DuplicateBattleToken(tokenId);
        if (loadout.length > BinderIds.MAX_BATTLE_LOADOUT_ARTS) revert InvalidBattleInput();
        for (uint256 index; index < _participantIds.length; ++index) {
            if (_units[_participantIds[index]].tileId == spawnTileId) revert DuplicateSpawnTile(spawnTileId);
        }
        // Confirms map bounds before state is persisted; terrain and occupancy are separate checks.
        GridMathLib.internalCoordinates(spawnTileId, mapWidth, tileCount);
        if (!book0fRealms.isWalkable(mapId, mapVersion, spawnTileId)) revert UnwalkableSpawnTile(spawnTileId);

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
            equipmentModifiers: [int32(0), 0, 0, 0, 0, 0, 0, 0],
            equipmentTokenIds: [uint256(0), 0, 0, 0, 0],
            equipmentConfigVersions: [uint32(0), 0, 0, 0, 0],
            alive: metadata.dynamicStats.currentHP != 0,
            guardActive: false
        });
        _participantIds.push(tokenId);
        _participantIndexPlusOne[tokenId] = uint8(_participantIds.length);
        _snapshotEquipment(tokenId);

        for (uint256 index; index < loadout.length; ++index) {
            uint32 artId = loadout[index];
            if (artId == 0 || _selectedArts[tokenId][artId]) revert InvalidBattleInput();
            if (!_isLearned(tokenId, artId)) revert ArtNotLearned(tokenId, artId);
            if (!book0fArts.artExists(artId)) revert BattleArtUnavailable(artId);
            binderStructs.ArtDefinition memory art = book0fArts.getArtDefinition(artId);
            if (art.version == 0 || !art.enabled) revert BattleArtUnavailable(artId);
            uint16 learnedVersion = binderSkills.getLearnedArtVersion(tokenId, artId);
            if (learnedVersion != art.version) {
                revert BattleArtVersionStale(tokenId, artId, learnedVersion, art.version);
            }
            if (!book0fArts.isClassEligible(artId, art.version, metadata.classId)) {
                revert BattleArtClassIneligible(tokenId, artId, metadata.classId, art.version);
            }
            if (art.artTypeId != BinderIds.ART_TYPE_MOVE_SET && art.artTypeId != BinderIds.ART_TYPE_ACTIVE) {
                revert UnsupportedBattleArtType(art.artTypeId);
            }
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

    function _resolveArt(uint256 actorTokenId, uint256 targetTokenId, binderStructs.ArtDefinition memory art)
        private
        returns (int256 hpDelta, uint16 actorHPAfter, uint16 actorMPAfter, uint16 targetHPAfter)
    {
        if (art.artTypeId != BinderIds.ART_TYPE_MOVE_SET && art.artTypeId != BinderIds.ART_TYPE_ACTIVE) {
            revert UnsupportedBattleArtType(art.artTypeId);
        }
        BattleUnit storage actor = _requireParticipant(actorTokenId);
        if (!actor.alive) revert BattleUnitNotAlive(actorTokenId);
        if (!ArtFormulaLib.canPayCosts(actor.currentHP, actor.currentMP, art.hpCost, art.mpCost)) {
            revert InsufficientBattleResource(actorTokenId, actor.currentHP, actor.currentMP, art.hpCost, art.mpCost);
        }
        BattleUnit storage target = _requireParticipant(targetTokenId);
        if (!target.alive) revert BattleUnitNotAlive(targetTokenId);
        _validateTargetPattern(actorTokenId, targetTokenId, art);

        actor.currentHP -= art.hpCost;
        actor.currentMP -= art.mpCost;
        if (actor.currentHP == 0) actor.alive = false;
        uint16 targetHPBefore = target.currentHP;
        int256 formulaResult = ArtFormulaLib.evaluate(
            art.primaryFormula, _asEffectiveStats(actorTokenId, actor), _asEffectiveStats(targetTokenId, target)
        );
        _applyEffect(art.effectTypeId, target, formulaResult);
        if (!actor.alive && actor.currentHP != 0) actor.currentHP = 0;
        hpDelta = int256(uint256(target.currentHP)) - int256(uint256(targetHPBefore));
        actorHPAfter = actor.currentHP;
        actorMPAfter = actor.currentMP;
        targetHPAfter = target.currentHP;
        if (art.hpCost != 0 || art.mpCost != 0) _markDirty(actorTokenId);
        if (target.currentHP != targetHPBefore) _markDirty(targetTokenId);
    }

    function _validateItemUse(uint256 actorTokenId, uint256 target, uint128 amount, SItemConfig memory config)
        private
        view
    {
        for (uint8 i; i < config.effectCount; ++i) {
            ItemEffect memory effect = config.effects[i];
            if (effect.scope != ItemUseScope.BATTLE_ONLY && effect.scope != ItemUseScope.WORLD_OR_BATTLE) {
                revert BattleItemUnavailable(0);
            }
            if (effect.kind == ItemEffectKind.PLACE_BATTLE_OBJECT) {
                if (effect.target != ItemTarget.TILE || target == 0 || target > type(uint16).max) {
                    revert InvalidBattleItemTarget(target);
                }
            } else {
                _validateItemTarget(actorTokenId, target, effect.target);
            }
            if (
                amount != 1
                    && (effect.kind == ItemEffectKind.CAST_ART || effect.kind == ItemEffectKind.PLACE_BATTLE_OBJECT)
            ) {
                revert InvalidBattleItemAmount(amount);
            }
        }
    }

    function _applyItemEffect(
        uint256 actorTokenId,
        uint256 targetTokenId,
        uint128 amount,
        uint16 sItemId,
        uint8 effectIndex,
        ItemEffect memory effect
    ) private {
        if (effect.kind == ItemEffectKind.MODIFY_CUR_HP || effect.kind == ItemEffectKind.MODIFY_CUR_MP) {
            BattleUnit storage target = _requireParticipant(targetTokenId);
            int256 delta = int256(effect.amount) * int256(uint256(amount));
            if (effect.kind == ItemEffectKind.MODIFY_CUR_HP) {
                uint16 before = target.currentHP;
                target.currentHP = ArtFormulaLib.clampResourceDelta(delta, before, target.maxHP);
                if (target.currentHP == 0) target.alive = false;
                if (target.currentHP != before) _markDirty(targetTokenId);
            } else {
                uint16 before = target.currentMP;
                target.currentMP = ArtFormulaLib.clampResourceDelta(delta, before, target.maxMP);
                if (target.currentMP != before) _markDirty(targetTokenId);
            }
        } else if (effect.kind == ItemEffectKind.TEMP_STAT_DELTA) {
            int32[8] memory delta;
            for (uint256 stat; stat < 8; ++stat) {
                int256 scaled = int256(effect.statDelta[stat]) * int256(uint256(amount));
                if (scaled > type(int32).max || scaled < type(int32).min) revert InvalidBattleItemAmount(amount);
                delta[stat] = int32(scaled);
            }
            _upsertTemporaryModifier(
                targetTokenId, keccak256(abi.encodePacked(sItemId, effectIndex)), delta, effect.durationSeconds
            );
        } else if (effect.kind == ItemEffectKind.CURE_AILMENT) {
            uint8 ailmentId = _checkedAilmentId(effect.refId);
            _units[targetTokenId].activeAilments &= ~(uint256(1) << ailmentId);
            delete _ailmentExpiry[targetTokenId][ailmentId];
        } else if (effect.kind == ItemEffectKind.APPLY_AILMENT) {
            uint8 ailmentId = _checkedAilmentId(effect.refId);
            _units[targetTokenId].activeAilments |= uint256(1) << ailmentId;
            _ailmentExpiry[targetTokenId][ailmentId] = uint64(block.timestamp) + uint64(effect.durationSeconds);
        } else if (effect.kind == ItemEffectKind.CAST_ART) {
            if (!book0fArts.isArtItemCastable(effect.refId)) revert BattleArtUnavailable(effect.refId);
            binderStructs.ArtDefinition memory art = book0fArts.getArtDefinition(effect.refId);
            if (!art.enabled) revert BattleArtUnavailable(effect.refId);
            _resolveArt(actorTokenId, targetTokenId, art);
        } else if (effect.kind == ItemEffectKind.PLACE_BATTLE_OBJECT) {
            // Book0fRealms has no battle-object catalogue yet, so configured objects remain safely unusable.
            revert BattleObjectsUnsupported(effect.refId);
        } else {
            revert BattleItemUnavailable(sItemId);
        }
    }

    function _validateItemTarget(uint256 actorTokenId, uint256 targetTokenId, ItemTarget targetKind) private view {
        BattleUnit storage actor = _requireParticipant(actorTokenId);
        BattleUnit storage target = _requireParticipant(targetTokenId);
        if (!target.alive) revert BattleUnitNotAlive(targetTokenId);
        if (targetKind == ItemTarget.SELF) {
            if (actorTokenId != targetTokenId) revert InvalidBattleItemTarget(targetTokenId);
        } else if (targetKind == ItemTarget.ALLY) {
            if (actor.controller != target.controller) revert InvalidBattleItemTarget(targetTokenId);
        } else if (targetKind == ItemTarget.ENEMY) {
            if (actor.controller == target.controller) revert InvalidBattleItemTarget(targetTokenId);
        } else {
            revert InvalidBattleItemTarget(targetTokenId);
        }
    }

    function _checkedAilmentId(uint32 ailmentId) private pure returns (uint8) {
        if (ailmentId < BinderIds.MIN_AILMENT_ID || ailmentId > BinderIds.MAX_AILMENT_ID) {
            revert InvalidBattleAilmentId(ailmentId);
        }
        return uint8(ailmentId);
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

    function _applyEffect(uint8 effectTypeId, BattleUnit storage target, int256 formulaResult) internal {
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
    }

    function _asEffectiveStats(uint256 tokenId, BattleUnit storage unit)
        internal
        view
        returns (uint256[8] memory stats)
    {
        for (uint256 index; index < stats.length; ++index) {
            int256 effective = int256(uint256(unit.baseStats[index])) + int256(unit.equipmentModifiers[index]);
            TimedStatModifier[] storage active = _temporaryModifiers[tokenId];
            for (uint256 modifierIndex; modifierIndex < active.length; ++modifierIndex) {
                if (active[modifierIndex].expiresAt > block.timestamp) {
                    effective += int256(active[modifierIndex].delta[index]);
                }
            }
            stats[index] = effective > 0 ? uint256(effective) : 0;
        }
    }

    function _upsertTemporaryModifier(uint256 tokenId, bytes32 key, int32[8] memory delta, uint32 durationSeconds)
        private
    {
        TimedStatModifier[] storage active = _temporaryModifiers[tokenId];
        for (uint256 i; i < active.length;) {
            if (active[i].expiresAt <= block.timestamp) {
                bytes32 expiredKey = active[i].key;
                uint256 last = active.length - 1;
                if (i != last) {
                    active[i] = active[last];
                    _temporaryModifierIndex[tokenId][active[i].key] = uint16(i + 1);
                }
                delete _temporaryModifierIndex[tokenId][expiredKey];
                active.pop();
            } else {
                ++i;
            }
        }
        uint16 indexPlusOne = _temporaryModifierIndex[tokenId][key];
        uint64 expiresAt = uint64(block.timestamp) + uint64(durationSeconds);
        if (indexPlusOne == 0) {
            active.push(TimedStatModifier({key: key, delta: delta, expiresAt: expiresAt}));
            _temporaryModifierIndex[tokenId][key] = uint16(active.length);
        } else {
            TimedStatModifier storage existing = active[indexPlusOne - 1];
            existing.delta = delta;
            existing.expiresAt = expiresAt;
        }
    }

    function _snapshotEquipment(uint256 tokenId) private {
        if (address(binderInventory) == address(0)) return;
        InventorySlot[20] memory slots = binderInventory.getSlots(tokenId);
        BattleUnit storage unit = _units[tokenId];
        IBook0fItems itemBook = binderInventory.book();
        for (uint256 i; i < slots.length; ++i) {
            InventorySlot memory item = slots[i];
            if (!item.occupied || item.family != ItemFamily.EQUIPMENT || !item.equipped) continue;
            uint8 slot = uint8(item.equippedAs);
            EqConfig memory cfg = itemBook.getEq(item.libraryId);
            unit.equipmentTokenIds[slot] = item.instanceTokenId;
            unit.equipmentConfigVersions[slot] = cfg.configVersion;
            for (uint256 stat; stat < 8; ++stat) {
                unit.equipmentModifiers[stat] +=
                    int32(uint32(cfg.statsChgInc[stat])) - int32(uint32(cfg.statsChgDec[stat]));
            }
        }
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
        emit BattleInitialized(
            factory, address(book0fArts), address(book0fRealms), mapId, mapVersion, _participantIds.length
        );
    }
}
