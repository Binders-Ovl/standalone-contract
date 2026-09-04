// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts-4.8/proxy/ERC1967/ERC1967Proxy.sol";
import "../modular/AllegianceRegistry.sol";
import "../modular/BinderData.sol";
import "../modular/BinderLogic.sol";
import "../modular/BinderSkills.sol";
import "../modular/Book0fArts.sol";
import "../modular/Book0fLife.sol";
import "../modular/Book0fRealms.sol";
import "../modular/FusionMinter.sol";
import "../modular/ScaleOfBalance.sol";
import "../modular/Battle/BattleFactory.sol";
import "../modular/Battle/BattleProxy.sol";
import "../modular/supportContract/BinderMetadata.sol";
import "../modular/supportContract/CentralConsole.sol";
import "../modular/supportContract/Errors.sol";
import "../modular/supportContract/binderIds.sol";
import "../modular/interfaces/ICentralConsole.sol";

contract WiringEntropyStub {}

contract CentralConsoleWiringTest is Test {
    address internal constant GRAVEYARD = address(0xDEAD);

    BinderData internal binderData;
    CentralConsole internal centralConsole;
    AllegianceRegistry internal allegiance;
    Book0fLife internal life;
    Book0fArts internal arts;
    Book0fRealms internal realms;
    BinderSkills internal skills;
    BinderMetadata internal metadata;
    BinderLogic internal logic;
    FusionMinter internal fusion;
    ScaleOfBalance internal scale;
    BattleFactory internal battleFactory;

    function setUp() public {
        binderData = new BinderData(address(this), "");
        binderData.setGraveyard(GRAVEYARD);
        centralConsole = new CentralConsole(address(this), address(binderData));
        binderData.grantRole(binderData.CONFIG_ROLE(), address(centralConsole));
        allegiance = new AllegianceRegistry(address(this));
        life = new Book0fLife();
        arts = new Book0fArts(address(this));
        realms = new Book0fRealms(address(this));
        life.grantRole(life.CONFIG_ROLE(), address(centralConsole));

        BinderSkills skillsImplementation = new BinderSkills();
        ERC1967Proxy skillsProxy = new ERC1967Proxy(
            address(skillsImplementation),
            abi.encodeCall(BinderSkills.initialize, (address(this), address(binderData), address(centralConsole)))
        );
        skills = BinderSkills(address(skillsProxy));
        metadata = new BinderMetadata(address(binderData), address(skills), address(life), address(arts), address(this));
        WiringEntropyStub entropy = new WiringEntropyStub();
        logic = new BinderLogic(
            address(entropy), address(0xBEEF), address(binderData), address(life), address(allegiance), address(this)
        );
        logic.grantRole(logic.CONFIG_ROLE(), address(centralConsole));
        fusion = new FusionMinter(address(binderData), address(life), address(entropy), address(0xBEEF), address(this));
        scale = new ScaleOfBalance(address(binderData), address(life));
        BattleProxy implementation = new BattleProxy();
        battleFactory = new BattleFactory(address(this), address(centralConsole), address(implementation));

        centralConsole.setBook0fLife(address(life));
        centralConsole.setBook0fArts(address(arts));
        centralConsole.setBook0fRealms(address(realms));
        centralConsole.setBinderSkills(address(skills));
        centralConsole.setBinderMetadata(address(metadata));
        centralConsole.setAllegianceRegistry(address(allegiance));
        centralConsole.setBinderLogic(address(logic));
        centralConsole.setFusionMinter(address(fusion));
        centralConsole.setScaleOfBalance(address(scale));
        centralConsole.setBattleFactory(address(battleFactory), 1);
    }

    function testCompleteDeploymentReportsFullyWired() public view {
        ICentralConsole.WiringStatus memory status = centralConsole.getWiringStatus();
        assertTrue(status.binderDataMetadataMatch);
        assertTrue(status.binderSkillsPairMatch);
        assertTrue(status.metadataDependenciesMatch);
        assertTrue(status.metadataRefreshAuthorityMatch);
        assertTrue(status.bookLifeDependenciesMatch);
        assertTrue(status.book0fRealmsConfigured);
        assertTrue(status.battleFactoryMatch);
        assertTrue(status.battleFactoryDependenciesMatch);
        assertTrue(status.battleActivityControllerMatch);
        assertTrue(status.fusionDependenciesMatch);
        assertTrue(status.fusionActivityControllerMatch);
        assertTrue(status.binderLogicCanonicalAndAccepting);
        assertTrue(status.scaleDependenciesAndAuthorityMatch);
        assertTrue(status.allegianceDependenciesMatch);
        assertTrue(status.graveyardConfigured);
        assertTrue(status.consoleAuthorityMatch);
        assertTrue(centralConsole.isFullyWired());
    }

    function testReplacementConsoleStagesSameModulesAndRevokesOldControlPlane() public {
        CentralConsole replacement = new CentralConsole(address(this), address(binderData));
        binderData.grantRole(binderData.CONFIG_ROLE(), address(replacement));
        life.grantRole(life.CONFIG_ROLE(), address(replacement));
        logic.grantRole(logic.CONFIG_ROLE(), address(replacement));
        skills.grantRole(skills.DEFAULT_ADMIN_ROLE(), address(replacement));

        replacement.setBook0fLife(address(life));
        replacement.setBook0fArts(address(arts));
        replacement.setBook0fRealms(address(realms));
        replacement.setBinderSkills(address(skills));
        replacement.setBinderMetadata(address(metadata));
        replacement.setAllegianceRegistry(address(allegiance));
        replacement.setBinderLogic(address(logic));
        replacement.setFusionMinter(address(fusion));
        replacement.setScaleOfBalance(address(scale));
        BattleProxy implementation = new BattleProxy();
        BattleFactory replacementFactory =
            new BattleFactory(address(this), address(replacement), address(implementation));
        replacement.setBattleFactory(address(replacementFactory), 2);
        assertTrue(replacement.isFullyWired());
        assertEq(skills.centralConsole(), address(replacement));

        binderData.revokeRole(binderData.CONFIG_ROLE(), address(centralConsole));
        life.revokeRole(life.CONFIG_ROLE(), address(centralConsole));
        logic.revokeRole(logic.CONFIG_ROLE(), address(centralConsole));
        centralConsole.revokeRole(centralConsole.CONFIG_ROLE(), address(this));
        assertFalse(logic.hasRole(logic.CONFIG_ROLE(), address(centralConsole)));
        vm.expectRevert();
        centralConsole.setBook0fArts(address(arts));
    }

    function testReservedActivityIdsCannotUseGenericSetter() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidActivityModuleId.selector, BinderIds.ACTIVITY_BATTLE));
        centralConsole.setActivityModule(BinderIds.ACTIVITY_BATTLE, address(battleFactory));

        vm.expectRevert(abi.encodeWithSelector(InvalidActivityModuleId.selector, BinderIds.ACTIVITY_FUSION));
        centralConsole.setActivityModule(BinderIds.ACTIVITY_FUSION, address(fusion));
    }

    function testDiagnosticsHandleUnconfiguredOptionalModulesWithoutReverting() public {
        CentralConsole blank = new CentralConsole(address(this), address(binderData));
        ICentralConsole.WiringStatus memory status = blank.getWiringStatus();
        assertFalse(status.binderSkillsPairMatch);
        assertFalse(status.battleFactoryDependenciesMatch);
        assertFalse(blank.isFullyWired());
    }

    function testDiagnosticsDetectMissingGraveyard() public {
        BinderData unconfiguredData = new BinderData(address(this), "");
        CentralConsole blank = new CentralConsole(address(this), address(unconfiguredData));
        assertFalse(blank.getWiringStatus().graveyardConfigured);
        assertFalse(blank.isFullyWired());
    }
}
