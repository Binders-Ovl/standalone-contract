// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts-4.8/proxy/ERC1967/ERC1967Proxy.sol";
import "../modular/Battle/BattleFactory.sol";
import "../modular/Battle/BattleProxy.sol";
import "../modular/BinderData.sol";
import "../modular/supportContract/binderIds.sol";
import "../modular/BinderSkills.sol";
import "../modular/Book0fArts.sol";
import "../modular/Book0fRealms.sol";
import "../modular/supportContract/CentralConsole.sol";
import "../modular/supportContract/binderStructs.sol";

contract BattleFactoryProxyTest is Test {
    event MetadataUpdate(uint256 tokenId);

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CHARLIE = address(0xCA11CE);

    BinderData internal binderData;
    BinderSkills internal skills;
    Book0fArts internal arts;
    Book0fRealms internal realms;
    CentralConsole internal centralConsole;
    BattleProxy internal battleImplementation;
    BattleFactory internal factory;

    function setUp() public {
        binderData = new BinderData(address(this), "");
        binderData.setAuthorizedBinderLogic(address(this), true);
        binderData.setAuthorizedFusionMinter(address(this), true);
        centralConsole = new CentralConsole(address(this), address(binderData));
        binderData.grantRole(binderData.CONFIG_ROLE(), address(centralConsole));
        arts = new Book0fArts(address(this));
        realms = new Book0fRealms(address(this));
        _configureMapAndArt();

        BinderSkills skillsImplementation = new BinderSkills();
        ERC1967Proxy skillsProxy = new ERC1967Proxy(
            address(skillsImplementation),
            abi.encodeCall(BinderSkills.initialize, (address(this), address(binderData), address(centralConsole)))
        );
        skills = BinderSkills(address(skillsProxy));
        centralConsole.setBinderSkills(address(skills));
        binderData.grantRole(binderData.METADATA_REFRESH_ROLE(), address(skills));
        centralConsole.setBook0fArts(address(arts));
        centralConsole.setBook0fRealms(address(realms));

        battleImplementation = new BattleProxy();
        factory = new BattleFactory(address(this), address(centralConsole), address(battleImplementation));
        centralConsole.setBattleFactory(address(factory), 1);
        binderData.setClassVersion(1, 1);

        _mintAndTeach(1, ALICE);
        _mintAndTeach(2, BOB);
        skills.grantActiveSkill(1, 102);
        skills.grantActiveSkill(1, 103);
    }

    function testCanonicalFactoryEscrowsSnapshotsAndRefereesWithoutMutatingBinderData() public {
        BattleProxy battle = _createBattle();
        assertTrue(factory.isBattleProxy(address(battle)));
        assertTrue(battle.isActive());
        assertEq(battle.participantCount(), 2);
        assertEq(binderData.ownerOf(1), address(battle));
        assertEq(binderData.ownerOf(2), address(battle));
        assertEq(binderData.getUnitState(1).activity.activityId, BinderIds.ACTIVITY_BATTLE);
        assertEq(battle.mapId(), 7);
        assertEq(battle.mapVersion(), 1);
        assertEq(address(battle.book0fArts()), address(arts));
        assertEq(address(battle.book0fRealms()), address(realms));
        assertEq(battle.getArtVersion(101), 1);
        assertEq(battle.getPosition(1), 1);
        assertEq(battle.getPosition(2), 2);

        // A later Book version cannot alter the selected Art behavior of this match.
        binderStructs.ArtDefinition memory artV2 = _damageArt(2, 1_000);
        arts.updateArt(artV2, new uint256[](0));
        assertEq(arts.getArtDefinition(101).version, 2);
        assertEq(battle.getArtVersion(101), 1);

        vm.prank(ALICE);
        battle.useArt(1, 101, 2);
        (uint16 targetHP,, bool targetAlive) = battle.getCurrentVitals(2);
        assertEq(targetHP, 90);
        assertTrue(targetAlive);
        assertEq(battle.actionNumber(), 1);
        // Phase 6 intentionally keeps live vitals local; Phase 7 adds pulses.
        assertEq(binderData.getNFTDetails(2).dynamicStats.currentHP, 100);
    }

    function testCurrentEligibilityBlocksNewBattleButDoesNotRewriteActiveSnapshot() public {
        BattleProxy activeBattle = _createBattle();
        _mintAndTeach(3, ALICE);
        _mintAndTeach(4, BOB);
        binderStructs.ArtDefinition memory versionTwo = _damageArt(2, 10_000);
        uint256[] memory onlyAnotherClass = new uint256[](1);
        onlyAnotherClass[0] = 2;
        arts.updateArt(versionTwo, onlyAnotherClass);

        // The active clone uses its immutable version-one snapshot.
        vm.prank(ALICE);
        activeBattle.useArt(1, 101, 2);
        assertEq(activeBattle.getArtVersion(101), 1);

        vm.startPrank(ALICE);
        binderData.approve(address(factory), 3);
        uint256 invitationId = factory.createBattleInvitation(BOB, 7, uint48(block.timestamp + 1 hours), _party(3, 1));
        vm.stopPrank();
        vm.prank(BOB);
        binderData.approve(address(factory), 4);
        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(
                BattleProxy.BattleArtClassIneligible.selector, uint256(3), uint32(101), uint256(1), uint16(2)
            )
        );
        factory.acceptBattleInvitation(invitationId, _party(4, 2));
    }

    function testDisabledAndPassiveArtsCannotEnterNewActionableLoadout() public {
        arts.setArtEnabled(101, false, 2);
        uint256 disabledInvitation = _createInvitation(1);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(BattleProxy.BattleArtUnavailable.selector, uint32(101)));
        factory.acceptBattleInvitation(disabledInvitation, _party(2, 2));

        binderStructs.ArtDefinition memory passive = _damageArt(1, 10_000);
        passive.artId = 104;
        passive.name = "Passive Strike";
        passive.artTypeId = BinderIds.ART_TYPE_PASSIVE;
        arts.addArt(passive, new uint256[](0));
        skills.grantPassiveSkill(1, 104);
        vm.startPrank(ALICE);
        binderData.approve(address(factory), 1);
        uint256 passiveInvitation =
            factory.createBattleInvitation(BOB, 7, uint48(block.timestamp + 1 hours), _partyWithArt(1, 1, 104));
        vm.stopPrank();
        vm.prank(BOB);
        binderData.approve(address(factory), 2);
        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(BattleProxy.UnsupportedBattleArtType.selector, BinderIds.ART_TYPE_PASSIVE)
        );
        factory.acceptBattleInvitation(passiveInvitation, _party(2, 2));
    }

    function testUnwalkableSpawnTileIsRejected() public {
        binderStructs.MapDefinition memory blockedMap = realms.getMap(7);
        blockedMap.version = 2;
        binderStructs.TileDefinition[] memory tiles = new binderStructs.TileDefinition[](6);
        for (uint16 tileId = 1; tileId <= 6; ++tileId) {
            tiles[tileId - 1] = binderStructs.TileDefinition({
                tileId: tileId,
                elevation: 0,
                terrainTypeId: 1,
                terrainFlags: 0,
                walkable: tileId != 1,
                movementCost: 1
            });
        }
        realms.updateMapVersion(blockedMap, tiles);

        uint256 invitationId = _createInvitation(1);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(BattleProxy.UnwalkableSpawnTile.selector, uint16(1)));
        factory.acceptBattleInvitation(invitationId, _party(2, 2));
        assertEq(binderData.ownerOf(1), ALICE);
        assertEq(binderData.ownerOf(2), BOB);
    }

    function testRefereeRejectsWrongControllerUnselectedArtAndOutOfRangeIntent() public {
        // Tile 1 to tile 6 is Manhattan distance 3; the snapshot Art range is 1.
        BattleProxy battle = _createBattleAt(1, 6);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(BattleProxy.UnauthorizedBattleActor.selector, uint256(1), BOB));
        battle.useArt(1, 101, 2);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(BattleProxy.ArtNotSelected.selector, uint256(1), uint32(999)));
        battle.useArt(1, 999, 2);

        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(BattleProxy.TargetOutOfRange.selector, uint256(1), uint256(2), uint16(3), uint16(1))
        );
        battle.useArt(1, 101, 2);
    }

    function testUnstartedCancellationUsesTheFactoryGatewayAndReturnsEachNft() public {
        BattleProxy battle = _createBattle();
        vm.prank(ALICE);
        battle.cancelUnstarted();

        assertFalse(battle.isActive());
        assertEq(binderData.ownerOf(1), ALICE);
        assertEq(binderData.ownerOf(2), BOB);
        assertTrue(binderData.getUnitState(1).idle);
        assertTrue(binderData.getUnitState(2).idle);
    }

    function testInvitationRequiresOwnersExplicitConsentDespiteNftApproval() public {
        vm.prank(ALICE);
        binderData.approve(address(factory), 1);

        vm.prank(CHARLIE);
        vm.expectRevert(
            abi.encodeWithSelector(
                BattleFactory.InvitationTokenOwnerMismatch.selector, uint256(1), uint256(1), CHARLIE, ALICE
            )
        );
        factory.createBattleInvitation(BOB, 7, uint48(block.timestamp + 1 hours), _party(1, 1));

        uint256 invitationId = _createInvitation(1);
        vm.prank(CHARLIE);
        vm.expectRevert(
            abi.encodeWithSelector(BattleFactory.UnauthorizedInvitationParty.selector, invitationId, BOB, CHARLIE)
        );
        factory.acceptBattleInvitation(invitationId, _party(2, 2));

        vm.prank(BOB);
        BattleProxy battle = BattleProxy(factory.acceptBattleInvitation(invitationId, _party(2, 2)));
        assertTrue(factory.isBattleProxy(address(battle)));
        assertEq(binderData.ownerOf(1), address(battle));
        assertEq(binderData.ownerOf(2), address(battle));

        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(BattleFactory.BattleInvitationAlreadyAccepted.selector, invitationId));
        factory.acceptBattleInvitation(invitationId, _party(2, 2));
    }

    function testExpiredInvitationCannotActivateAndCanBePermissionlesslyCancelled() public {
        uint256 invitationId = _createInvitation(1);
        BattleFactory.BattleInvitation memory invitation = factory.getBattleInvitation(invitationId);
        vm.warp(invitation.expiresAt);

        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(BattleFactory.BattleInvitationExpired.selector, invitationId, invitation.expiresAt)
        );
        factory.acceptBattleInvitation(invitationId, _party(2, 2));

        vm.prank(CHARLIE);
        factory.cancelBattleInvitation(invitationId);
        assertTrue(factory.getBattleInvitation(invitationId).cancelled);
        assertEq(binderData.ownerOf(1), ALICE);
        assertEq(binderData.ownerOf(2), BOB);
    }

    function testDirtyVitalsPulseUsesCanonicalProxyNonceAndSkipsCleanUnits() public {
        BattleProxy battle = _createBattle();
        vm.prank(ALICE);
        battle.useArt(1, 101, 2);
        assertEq(battle.dirtyUnitBitmap(), 2);

        binderData.setBattleCheckpointMetadataEnabled(true);
        vm.expectEmit(true, false, false, true, address(binderData));
        emit MetadataUpdate(2);
        battle.checkpointDirtyVitals();

        assertEq(battle.checkpointNonce(), 1);
        assertEq(battle.dirtyUnitBitmap(), 0);
        assertEq(binderData.getNFTDetails(2).dynamicStats.currentHP, 90);
        assertEq(binderData.battleCheckpointNonce(2), 1);
        assertEq(binderData.getNFTDetails(1).dynamicStats.currentHP, 100);
        assertEq(binderData.battleCheckpointNonce(1), 0);

        uint256[] memory tokenIds = new uint256[](1);
        uint16[] memory hpValues = new uint16[](1);
        uint16[] memory mpValues = new uint16[](1);
        tokenIds[0] = 2;
        hpValues[0] = 90;
        mpValues[0] = 50;
        vm.prank(address(battle));
        vm.expectRevert(
            abi.encodeWithSelector(BinderData.StaleBattleCheckpoint.selector, uint256(2), uint32(1), uint32(1))
        );
        binderData.checkpointBattleVitals(tokenIds, hpValues, mpValues, 1);

        hpValues[0] = 101;
        vm.prank(address(battle));
        vm.expectRevert(
            abi.encodeWithSelector(
                BinderData.BattleVitalsExceedMaximum.selector,
                uint256(2),
                uint16(101),
                uint16(50),
                uint16(100),
                uint16(50)
            )
        );
        binderData.checkpointBattleVitals(tokenIds, hpValues, mpValues, 2);
    }

    function testCheckpointNonceResetsForNewBattleAndOldProxyCannotWrite() public {
        BattleProxy firstBattle = _createBattle();
        _checkpointToken(firstBattle, 1, 1, 100, 50);
        assertEq(binderData.battleCheckpointNonce(1), 1);

        vm.prank(ALICE);
        firstBattle.cancelUnstarted();
        assertEq(binderData.activeBattleProxy(1), address(0));

        BattleProxy secondBattle = _createBattle();
        assertEq(binderData.battleCheckpointNonce(1), 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                BinderData.BattleProxyMismatch.selector, uint256(1), address(secondBattle), address(firstBattle)
            )
        );
        _checkpointToken(firstBattle, 1, 99, 100, 50);

        _checkpointToken(secondBattle, 1, 1, 100, 50);
        assertEq(binderData.battleCheckpointNonce(1), 1);
    }

    function testSelfSacrificialArtResolvesThenOpponentWinsAndCasterCannotActAgain() public {
        address graveyard = address(0xDEAD);
        binderData.setGraveyard(graveyard);
        binderData.adminUpdatePersistentVitals(1, 10, 50);
        BattleProxy battle = _createSelfSacrificeBattle();

        vm.prank(ALICE);
        battle.useArt(1, 102, 2);
        (uint16 actorHP,, bool actorAlive) = battle.getCurrentVitals(1);
        (uint16 targetHP,, bool targetAlive) = battle.getCurrentVitals(2);
        assertEq(actorHP, 0);
        assertFalse(actorAlive);
        assertEq(targetHP, 90);
        assertTrue(targetAlive);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(BattleProxy.BattleUnitNotAlive.selector, uint256(1)));
        battle.useArt(1, 102, 2);

        battle.settleDefeatedBattle();
        assertEq(binderData.ownerOf(1), graveyard);
        assertEq(binderData.ownerOf(2), BOB);
    }

    function testSelfSacrificialArtSupportsZeroSurvivorDraw() public {
        address graveyard = address(0xDEAD);
        binderData.setGraveyard(graveyard);
        binderData.adminUpdatePersistentVitals(1, 10, 50);
        binderData.adminUpdatePersistentVitals(2, 10, 50);
        BattleProxy battle = _createSelfSacrificeBattle();

        vm.prank(ALICE);
        battle.useArt(1, 102, 2);
        assertFalse(battle.getBattleUnit(1).alive);
        assertFalse(battle.getBattleUnit(2).alive);

        battle.settleDefeatedBattle();
        assertEq(binderData.ownerOf(1), graveyard);
        assertEq(binderData.ownerOf(2), graveyard);
    }

    function testSelfDefeatedSelfHealCannotLeaveEscrowedBinder() public {
        address graveyard = address(0xDEAD);
        binderData.setGraveyard(graveyard);
        binderData.adminUpdatePersistentVitals(1, 10, 50);
        BattleProxy battle = _createSelfHealBattle();

        vm.prank(ALICE);
        battle.useArt(1, 103, 1);
        (uint16 actorHP,, bool actorAlive) = battle.getCurrentVitals(1);
        assertEq(actorHP, 0);
        assertFalse(actorAlive);

        battle.settleDefeatedBattle();
        assertEq(binderData.ownerOf(1), graveyard);
        assertEq(binderData.ownerOf(2), BOB);
        assertEq(binderData.activeBattleProxy(1), address(0));
    }

    function testOnePlayerMayRetainMultipleSurvivingBinders() public {
        _mintAndTeach(3, ALICE);
        binderData.setGraveyard(address(0xDEAD));
        binderData.adminUpdatePersistentVitals(2, 10, 50);

        vm.startPrank(ALICE);
        binderData.approve(address(factory), 1);
        binderData.approve(address(factory), 3);
        uint256 invitationId =
            factory.createBattleInvitation(BOB, 7, uint48(block.timestamp + 1 hours), _twoTokenParty(1, 1, 3, 2));
        vm.stopPrank();
        vm.prank(BOB);
        binderData.approve(address(factory), 2);
        vm.prank(BOB);
        BattleProxy battle = BattleProxy(factory.acceptBattleInvitation(invitationId, _party(2, 3)));

        vm.prank(ALICE);
        battle.useArt(3, 101, 2);
        battle.settleDefeatedBattle();

        assertEq(binderData.ownerOf(1), ALICE);
        assertEq(binderData.ownerOf(3), ALICE);
        assertEq(binderData.ownerOf(2), address(0xDEAD));
    }

    function testEmergencyPathsCannotOrphanActiveBattleBindings() public {
        BattleProxy battle = _createBattle();

        vm.expectRevert(abi.encodeWithSelector(BinderData.ActiveBattleBinding.selector, uint256(1), address(battle)));
        binderData.adminUpdatePersistentVitals(1, 1, 1);

        vm.expectRevert(abi.encodeWithSelector(BinderData.ActiveBattleBinding.selector, uint256(1), address(battle)));
        binderData.forceClearActivity(1);

        vm.expectRevert(abi.encodeWithSelector(BinderData.ActiveBattleBinding.selector, uint256(1), address(battle)));
        binderData.tfToGraveyard(1);

        assertEq(binderData.activeBattleProxy(1), address(battle));
        assertEq(binderData.activeBattleCountByFactory(address(factory)), 2);
        assertEq(binderData.getUnitState(1).activity.activityId, BinderIds.ACTIVITY_BATTLE);
    }

    function testFinalSettlementReturnsSurvivorGraveyardsDefeatedAndKeepsOldFactoryAuthorizedUntilExit() public {
        address graveyard = address(0xDEAD);
        binderData.setGraveyard(graveyard);
        // Snapshot a 10-HP defender; the canonical formula produces 10 damage.
        binderData.adminUpdatePersistentVitals(2, 10, 50);
        BattleProxy battle = _createBattle();

        vm.expectRevert(
            abi.encodeWithSelector(BinderData.BattleFactoryHasActiveEscrows.selector, address(factory), uint256(2))
        );
        binderData.setAuthorizedBattleFactory(address(factory), false);

        vm.prank(ALICE);
        battle.useArt(1, 101, 2);
        assertFalse(battle.getBattleUnit(2).alive);
        battle.settleDefeatedBattle();

        assertFalse(battle.isActive());
        assertEq(binderData.ownerOf(1), ALICE);
        assertEq(binderData.ownerOf(2), graveyard);
        assertTrue(binderData.getUnitState(1).idle);
        assertEq(binderData.getNFTDetails(2).dynamicStats.currentHP, 0);
        assertEq(binderData.activeBattleProxy(1), address(0));
        assertEq(binderData.activeBattleProxy(2), address(0));
        assertEq(binderData.activeBattleCountByFactory(address(factory)), 0);

        binderData.setAuthorizedBattleFactory(address(factory), false);
        assertFalse(binderData.authorizedBattleFactory(address(factory)));
    }

    function testObsoleteFactoryCannotCreateNewBattleAndUnregisteredCallerCannotEndActivity() public {
        BattleProxy replacementImplementation = new BattleProxy();
        BattleFactory replacementFactory =
            new BattleFactory(address(this), address(centralConsole), address(replacementImplementation));
        centralConsole.setBattleFactory(address(replacementFactory), 2);

        BattleFactory.PartySubmission memory party = _party(1, 1);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                BattleFactory.NotCanonicalBattleFactory.selector, address(replacementFactory), address(factory)
            )
        );
        factory.createBattleInvitation(BOB, 7, uint48(block.timestamp + 1 hours), party);

        vm.expectRevert(abi.encodeWithSelector(InvalidBattleProxy.selector, address(this)));
        factory.endBattle(new uint256[](0));
    }

    function testOldInvitationFailsBeforeCustodyAfterFactoryCutover() public {
        uint256 invitationId = _createInvitation(1);
        BattleProxy replacementImplementation = new BattleProxy();
        BattleFactory replacementFactory =
            new BattleFactory(address(this), address(centralConsole), address(replacementImplementation));
        centralConsole.setBattleFactory(address(replacementFactory), 2);

        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(
                BattleFactory.NotCanonicalBattleFactory.selector, address(replacementFactory), address(factory)
            )
        );
        factory.acceptBattleInvitation(invitationId, _party(2, 2));

        assertEq(binderData.ownerOf(1), ALICE);
        assertEq(binderData.ownerOf(2), BOB);
        assertTrue(binderData.getUnitState(1).idle);
        assertTrue(binderData.getUnitState(2).idle);
    }

    function testOutgoingFactorySettlesItsBattleAfterControllerCutover() public {
        address graveyard = address(0xDEAD);
        binderData.setGraveyard(graveyard);
        binderData.adminUpdatePersistentVitals(2, 10, 50);
        BattleProxy firstVersionBattle = _createBattle();

        BattleProxy replacementImplementation = new BattleProxy();
        BattleFactory replacementFactory =
            new BattleFactory(address(this), address(centralConsole), address(replacementImplementation));
        centralConsole.setBattleFactory(address(replacementFactory), 2);
        assertEq(binderData.getActivityController(BinderIds.ACTIVITY_BATTLE), address(replacementFactory));

        vm.prank(ALICE);
        firstVersionBattle.useArt(1, 101, 2);
        firstVersionBattle.settleDefeatedBattle();

        assertEq(binderData.ownerOf(1), ALICE);
        assertEq(binderData.ownerOf(2), graveyard);
        assertEq(binderData.activeBattleCountByFactory(address(factory)), 0);
        assertTrue(binderData.getUnitState(1).idle);
    }

    function _createBattle() internal returns (BattleProxy) {
        return _createBattleAt(1, 2);
    }

    function _createBattleAt(uint16 firstTile, uint16 secondTile) internal returns (BattleProxy) {
        uint256 invitationId = _createInvitation(firstTile);
        vm.prank(BOB);
        return BattleProxy(factory.acceptBattleInvitation(invitationId, _party(2, secondTile)));
    }

    function _createSelfSacrificeBattle() internal returns (BattleProxy) {
        vm.startPrank(ALICE);
        binderData.approve(address(factory), 1);
        uint256 invitationId =
            factory.createBattleInvitation(BOB, 7, uint48(block.timestamp + 1 hours), _partyWithArt(1, 1, 102));
        vm.stopPrank();
        vm.startPrank(BOB);
        binderData.approve(address(factory), 2);
        BattleProxy battle = BattleProxy(factory.acceptBattleInvitation(invitationId, _party(2, 2)));
        vm.stopPrank();
        return battle;
    }

    function _createSelfHealBattle() internal returns (BattleProxy) {
        vm.startPrank(ALICE);
        binderData.approve(address(factory), 1);
        uint256 invitationId =
            factory.createBattleInvitation(BOB, 7, uint48(block.timestamp + 1 hours), _partyWithArt(1, 1, 103));
        vm.stopPrank();
        vm.startPrank(BOB);
        binderData.approve(address(factory), 2);
        BattleProxy battle = BattleProxy(factory.acceptBattleInvitation(invitationId, _party(2, 2)));
        vm.stopPrank();
        return battle;
    }

    function _createInvitation(uint16 firstTile) internal returns (uint256 invitationId) {
        vm.startPrank(ALICE);
        binderData.approve(address(factory), 1);
        invitationId = factory.createBattleInvitation(BOB, 7, uint48(block.timestamp + 1 hours), _party(1, firstTile));
        vm.stopPrank();
        vm.startPrank(BOB);
        binderData.approve(address(factory), 2);
        vm.stopPrank();
    }

    function _party(uint256 tokenId, uint16 tileId)
        internal
        pure
        returns (BattleFactory.PartySubmission memory party)
    {
        return _partyWithArt(tokenId, tileId, 101);
    }

    function _partyWithArt(uint256 tokenId, uint16 tileId, uint32 artId)
        internal
        pure
        returns (BattleFactory.PartySubmission memory party)
    {
        party.tokenIds = new uint256[](1);
        party.tokenIds[0] = tokenId;
        party.spawnTileIds = new uint16[](1);
        party.spawnTileIds[0] = tileId;
        party.selectedArtIds = new uint32[][](1);
        party.selectedArtIds[0] = new uint32[](1);
        party.selectedArtIds[0][0] = artId;
    }

    function _twoTokenParty(uint256 firstTokenId, uint16 firstTileId, uint256 secondTokenId, uint16 secondTileId)
        internal
        pure
        returns (BattleFactory.PartySubmission memory party)
    {
        party.tokenIds = new uint256[](2);
        party.tokenIds[0] = firstTokenId;
        party.tokenIds[1] = secondTokenId;
        party.spawnTileIds = new uint16[](2);
        party.spawnTileIds[0] = firstTileId;
        party.spawnTileIds[1] = secondTileId;
        party.selectedArtIds = new uint32[][](2);
        party.selectedArtIds[0] = new uint32[](1);
        party.selectedArtIds[0][0] = 101;
        party.selectedArtIds[1] = new uint32[](1);
        party.selectedArtIds[1][0] = 101;
    }

    function _checkpointToken(BattleProxy battle, uint256 tokenId, uint32 nonce, uint16 hp, uint16 mp) internal {
        uint256[] memory tokenIds = new uint256[](1);
        uint16[] memory hpValues = new uint16[](1);
        uint16[] memory mpValues = new uint16[](1);
        tokenIds[0] = tokenId;
        hpValues[0] = hp;
        mpValues[0] = mp;
        vm.prank(address(battle));
        binderData.checkpointBattleVitals(tokenIds, hpValues, mpValues, nonce);
    }

    function _mintAndTeach(uint256 ignoredTokenId, address owner) internal {
        ignoredTokenId;
        uint8[8] memory values = [uint8(10), 10, 10, 10, 10, 10, 10, 10];
        binderStructs.StaticStats memory staticStats = binderStructs.StaticStats({stats: values});
        binderStructs.DynamicStats memory dynamicStats =
            binderStructs.DynamicStats({maxHP: 100, maxMP: 50, currentHP: 100, currentMP: 50});
        binderData._mintRandomNFT(owner, 1, "Fighter", 1, "Common", staticStats, dynamicStats);
        skills.grantActiveSkill(ignoredTokenId, 101);
    }

    function _configureMapAndArt() internal {
        binderStructs.MapDefinition memory map =
            binderStructs.MapDefinition({mapId: 7, name: "Arena", width: 3, height: 2, version: 1, enabled: true});
        binderStructs.TileDefinition[] memory tiles = new binderStructs.TileDefinition[](6);
        for (uint16 tileId = 1; tileId <= 6; ++tileId) {
            tiles[tileId - 1] = binderStructs.TileDefinition({
                tileId: tileId,
                elevation: 0,
                terrainTypeId: 1,
                terrainFlags: 0,
                walkable: true,
                movementCost: 1
            });
        }
        realms.addMap(map, tiles);
        arts.addArt(_damageArt(1, 10_000), new uint256[](0));
        arts.addArt(_selfSacrificeArt(), new uint256[](0));
        arts.addArt(_selfSacrificialHealArt(), new uint256[](0));
    }

    function _damageArt(uint16 version, int16 coefficientBps)
        internal
        pure
        returns (binderStructs.ArtDefinition memory definition)
    {
        definition.artId = 101;
        definition.name = "Strike";
        definition.artTypeId = BinderIds.ART_TYPE_ACTIVE;
        definition.effectTypeId = BinderIds.EFFECT_TYPE_DAMAGE;
        definition.patternTypeId = BinderIds.PATTERN_TYPE_SINGLE;
        definition.range = 1;
        definition.primaryFormula.termCount = 1;
        definition.primaryFormula.terms[0] = binderStructs.FormulaTerm({
            sourceId: BinderIds.FORMULA_SOURCE_ACTOR,
            statId: BinderIds.STAT_STR,
            coefficientBps: coefficientBps
        });
        definition.version = version;
        definition.enabled = true;
    }

    function _selfSacrificeArt() internal pure returns (binderStructs.ArtDefinition memory definition) {
        definition = _damageArt(1, 10_000);
        definition.artId = 102;
        definition.name = "Last Strike";
        definition.hpCost = 10;
    }

    function _selfSacrificialHealArt() internal pure returns (binderStructs.ArtDefinition memory definition) {
        definition = _damageArt(1, 10_000);
        definition.artId = 103;
        definition.name = "Last Prayer";
        definition.effectTypeId = BinderIds.EFFECT_TYPE_HEAL;
        definition.patternTypeId = BinderIds.PATTERN_TYPE_SELF;
        definition.range = 0;
        definition.hpCost = 10;
        definition.primaryFormula.termCount = 0;
        definition.primaryFormula.flatValue = 20;
    }
}
