// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../modular/BinderData.sol";
import "../modular/Book0fLife.sol";
import "../modular/BinderLogic.sol";
import "../modular/ScaleOfBalance.sol";
import "../modular/AllegianceRegistry.sol";
import "../modular/supportContract/binderIds.sol";
import "../modular/supportContract/CentralConsole.sol";
import "../modular/supportContract/Errors.sol";
import "../modular/interfaces/ICentralConsole.sol";
import "../modular/supportContract/binderStructs.sol";
import "../modular/Battle/BattleFactory.sol";
import "../modular/Battle/BattleProxy.sol";

contract MockCanonicalModule {}

contract BattleFactoryDependencyStub {
    address public immutable centralConsole;
    address public immutable battleImplementation;

    constructor(address consoleAddress, address implementationAddress) {
        centralConsole = consoleAddress;
        battleImplementation = implementationAddress;
    }
}

contract MockFusionModule {
    address public immutable binderData;
    address public immutable book0fLife;

    constructor(address binderDataAddress, address book0fLifeAddress) {
        binderData = binderDataAddress;
        book0fLife = book0fLifeAddress;
    }
}

/// @dev Models the minimum renderer compatibility surface checked by CentralConsole.
contract MockMetadataModule {
    address public immutable binderData;

    constructor(address binderDataAddress) {
        binderData = binderDataAddress;
    }
}

contract Phase1ArchitectureTest is Test {
    address internal constant OTHER_ADMIN = address(0xB0B);

    BinderData internal binderData;
    CentralConsole internal centralConsole;
    MockCanonicalModule internal moduleA;
    MockCanonicalModule internal moduleB;
    MockMetadataModule internal metadataModule;
    MockFusionModule internal fusionModule;
    Book0fLife internal life;
    BattleProxy internal battleImplementation;
    BattleFactory internal battleFactory;

    function setUp() public {
        binderData = new BinderData(address(this), "");
        centralConsole = new CentralConsole(address(this), address(binderData));
        binderData.grantRole(binderData.CONFIG_ROLE(), address(centralConsole));
        life = new Book0fLife();
        life.grantRole(life.CONFIG_ROLE(), address(centralConsole));
        moduleA = new MockCanonicalModule();
        moduleB = new MockCanonicalModule();
        metadataModule = new MockMetadataModule(address(binderData));
        fusionModule = new MockFusionModule(address(binderData), address(life));
        battleImplementation = new BattleProxy();
        battleFactory = new BattleFactory(address(this), address(centralConsole), address(battleImplementation));
    }

    function testImmutableBinderDataAndTypedReadSurface() public view {
        ICentralConsole registry = ICentralConsole(address(centralConsole));

        assertEq(registry.binderData(), address(binderData));
        assertEq(registry.canonicalModule(BinderIds.MODULE_BINDER_DATA), address(binderData));
        assertTrue(registry.isCanonicalModule(address(binderData)));
        assertFalse(registry.isCanonicalModule(address(0)));
        assertTrue(centralConsole.hasRole(centralConsole.CONFIG_ROLE(), address(this)));
    }

    function testRegistersReplaceableCanonicalModules() public {
        centralConsole.setBook0fLife(address(life));
        centralConsole.setBook0fArts(address(moduleA));
        centralConsole.setBook0fRealms(address(moduleA));
        centralConsole.setFusionMinter(address(fusionModule));
        centralConsole.setAllegianceRegistry(address(moduleA));
        centralConsole.setActivityModule(99, address(moduleA));

        assertEq(centralConsole.binderSkills(), address(0));
        assertEq(centralConsole.binderMetadata(), address(0));
        assertEq(centralConsole.book0fLife(), address(life));
        assertEq(centralConsole.book0fArts(), address(moduleA));
        assertEq(centralConsole.book0fRealms(), address(moduleA));
        assertEq(centralConsole.binderLogic(), address(0));
        assertEq(centralConsole.fusionMinter(), address(fusionModule));
        assertEq(centralConsole.scaleOfBalance(), address(0));
        assertEq(centralConsole.allegianceRegistry(), address(moduleA));
        assertEq(centralConsole.activityModule(99), address(moduleA));
        assertEq(binderData.getActivityController(BinderIds.ACTIVITY_FUSION), address(fusionModule));
        assertEq(centralConsole.canonicalModule(BinderIds.MODULE_BOOK_OF_ARTS), address(moduleA));
        assertTrue(centralConsole.isCanonicalModule(address(moduleA)));
    }

    function testBattleFactoryRequiresStrictlyIncreasingVersion() public {
        vm.expectRevert(abi.encodeWithSelector(CanonicalPairMismatch.selector, address(centralConsole), address(0)));
        centralConsole.setBattleFactory(address(moduleA), 1);

        centralConsole.setBattleFactory(address(battleFactory), 1);
        assertEq(centralConsole.battleFactory(), address(battleFactory));
        assertEq(centralConsole.battleFactoryVersion(), 1);

        vm.expectRevert(
            abi.encodeWithSelector(InvalidModuleVersion.selector, BinderIds.MODULE_BATTLE_FACTORY, uint32(1), uint32(1))
        );
        centralConsole.setBattleFactory(address(battleFactory), 1);

        BattleProxy replacementImplementation = new BattleProxy();
        BattleFactory replacement =
            new BattleFactory(address(this), address(centralConsole), address(replacementImplementation));
        centralConsole.setBattleFactory(address(replacement), 2);
        assertEq(centralConsole.battleFactory(), address(replacement));
        assertEq(centralConsole.battleFactoryVersion(), 2);
    }

    function testBattleFactoryRejectsWrongConsoleAndNoCodeImplementation() public {
        CentralConsole otherConsole = new CentralConsole(address(this), address(binderData));
        BattleProxy implementation = new BattleProxy();
        BattleFactory wrongConsoleFactory =
            new BattleFactory(address(this), address(otherConsole), address(implementation));
        vm.expectRevert(
            abi.encodeWithSelector(CanonicalPairMismatch.selector, address(centralConsole), address(otherConsole))
        );
        centralConsole.setBattleFactory(address(wrongConsoleFactory), 1);

        BattleFactoryDependencyStub noCodeImplementation =
            new BattleFactoryDependencyStub(address(centralConsole), makeAddr("no-code-battle-implementation"));
        vm.expectRevert(
            abi.encodeWithSelector(
                InvalidModuleAddress.selector,
                BinderIds.MODULE_BATTLE_FACTORY,
                noCodeImplementation.battleImplementation()
            )
        );
        centralConsole.setBattleFactory(address(noCodeImplementation), 1);
    }

    function testConsoleAtomicallyWiresBookAndAllegianceConsumers() public {
        AllegianceRegistry registry = new AllegianceRegistry(address(this));
        ScaleOfBalance scale = new ScaleOfBalance(address(binderData), address(life));
        BinderLogic logic = new BinderLogic(
            address(moduleA), address(this), address(binderData), address(life), address(registry), address(this)
        );
        scale.grantRole(scale.CONFIG_ROLE(), address(centralConsole));
        logic.grantRole(logic.CONFIG_ROLE(), address(centralConsole));

        centralConsole.setBook0fLife(address(life));
        centralConsole.setScaleOfBalance(address(scale));
        centralConsole.setBinderLogic(address(logic));
        centralConsole.setAllegianceRegistry(address(registry));
        assertTrue(binderData.authorizedBinderLogic(address(logic)));
        assertEq(address(life.allegianceRegistry()), address(registry));
        assertEq(address(logic.allegianceRegistry()), address(registry));

        Book0fLife replacementLife = new Book0fLife();
        replacementLife.grantRole(replacementLife.CONFIG_ROLE(), address(centralConsole));
        centralConsole.setBook0fLife(address(replacementLife));
        assertEq(address(scale.book0fLife()), address(replacementLife));
        assertEq(address(logic.book0fLife()), address(replacementLife));
        assertEq(address(replacementLife.allegianceRegistry()), address(registry));

        ICentralConsole.WiringStatus memory status = centralConsole.getWiringStatus();
        assertTrue(status.allegianceDependenciesMatch);
    }

    function testRegistryRejectsInvalidModulesAndUnauthorizedCallers() public {
        vm.expectRevert(
            abi.encodeWithSelector(InvalidModuleAddress.selector, BinderIds.MODULE_BINDER_SKILLS, address(0))
        );
        centralConsole.setBinderSkills(address(0));

        address noCodeAddress = makeAddr("no-code-module");
        vm.expectRevert(
            abi.encodeWithSelector(InvalidModuleAddress.selector, BinderIds.MODULE_BOOK_OF_LIFE, noCodeAddress)
        );
        centralConsole.setBook0fLife(noCodeAddress);

        vm.expectRevert(abi.encodeWithSelector(InvalidActivityModuleId.selector, uint8(0)));
        centralConsole.setActivityModule(0, address(moduleA));

        vm.prank(OTHER_ADMIN);
        vm.expectRevert();
        centralConsole.setBook0fArts(address(moduleA));

        bytes32 unknownModule = keccak256("unknown-module");
        vm.expectRevert(abi.encodeWithSelector(UnknownCanonicalModule.selector, unknownModule));
        centralConsole.canonicalModule(unknownModule);
    }

    function testStableIdsAndFormulaTypesAreAvailableWithoutChangingExistingLayouts() public pure {
        assertEq(BinderIds.STAT_STR, 0);
        assertEq(BinderIds.STAT_INT, 1);
        assertEq(BinderIds.STAT_STA, 7);
        assertEq(BinderIds.STAT_COUNT, 8);
        assertEq(BinderIds.ART_TYPE_MOVE_SET, 1);
        assertEq(BinderIds.ART_TYPE_ACTIVE, 2);
        assertEq(BinderIds.ART_TYPE_PASSIVE, 3);
        assertEq(BinderIds.MOVE_SET_SLOTS, 3);
        assertEq(BinderIds.MAX_FORMULA_TERMS, 8);

        binderStructs.Formula memory formula;
        formula.formulaTypeId = 1;
        formula.termCount = 1;
        formula.terms[0] = binderStructs.FormulaTerm({
            sourceId: BinderIds.FORMULA_SOURCE_ACTOR,
            statId: BinderIds.STAT_INT,
            coefficientBps: 7_000
        });
        formula.flatValue = 30;

        assertEq(formula.terms[0].sourceId, BinderIds.FORMULA_SOURCE_ACTOR);
        assertEq(formula.terms[0].statId, BinderIds.STAT_INT);
        assertEq(formula.terms[0].coefficientBps, 7_000);
        assertEq(formula.flatValue, 30);
    }
}
