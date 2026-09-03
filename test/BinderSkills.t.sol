// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts-4.8/proxy/ERC1967/ERC1967Proxy.sol";
import "../modular/BinderData.sol";
import "../modular/BinderSkills.sol";
import "../modular/Book0fArts.sol";
import "../modular/supportContract/binderIds.sol";
import "../modular/supportContract/CentralConsole.sol";
import "../modular/supportContract/Errors.sol";
import "../modular/supportContract/binderStructs.sol";

contract SkillsActivityController {
    function start(BinderData binderData, uint256 tokenId, uint8 activityId) external {
        binderData.startActivity(tokenId, activityId, 0);
    }
}

/// @dev Test-only append-only successor used to prove UUPS proxy storage survives an upgrade.
contract BinderSkillsV2 is BinderSkills {
    uint256 public upgradeMarker;

    function setUpgradeMarker(uint256 marker) external onlyRole(DEFAULT_ADMIN_ROLE) {
        upgradeMarker = marker;
    }
}

contract BinderSkillsTest is Test {
    event MetadataUpdate(uint256 tokenId);

    address internal constant ALICE = address(0xA11CE);
    address internal constant OTHER = address(0xB0B);
    uint256 internal constant TOKEN_ID = 1;

    BinderData internal binderData;
    CentralConsole internal centralConsole;
    BinderSkills internal implementation;
    BinderSkills internal skills;
    Book0fArts internal arts;

    function setUp() public {
        binderData = new BinderData(address(this), "");
        binderData.setAuthorizedBinderLogic(address(this), true);
        centralConsole = new CentralConsole(address(this), address(binderData));
        binderData.grantRole(binderData.CONFIG_ROLE(), address(centralConsole));
        implementation = new BinderSkills();

        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(BinderSkills.initialize, (address(this), address(binderData), address(centralConsole)))
        );
        skills = BinderSkills(address(proxy));

        centralConsole.setBinderSkills(address(skills));
        binderData.grantRole(binderData.METADATA_REFRESH_ROLE(), address(skills));
        arts = new Book0fArts(address(this));
        centralConsole.setBook0fArts(address(arts));
        _configureArts();
        _mintToken();
    }

    function testImplementationIsLockedAndProxyIsCanonicallyBound() public {
        vm.expectRevert("Initializable: contract is already initialized");
        implementation.initialize(address(this), address(binderData), address(centralConsole));

        assertEq(skills.binderData(), address(binderData));
        assertEq(skills.centralConsole(), address(centralConsole));
        assertTrue(skills.isCanonicalPair());
        assertEq(centralConsole.binderSkills(), address(skills));
    }

    function testPermanentSkillLearningIsBoundedDeduplicatedAndPaginated() public {
        vm.expectEmit(false, false, false, true, address(binderData));
        emit MetadataUpdate(TOKEN_ID);
        skills.grantMoveSet(TOKEN_ID, 11);
        skills.grantMoveSet(TOKEN_ID, 12);
        skills.grantMoveSet(TOKEN_ID, 13);

        uint32[3] memory moveSets = skills.getMoveSets(TOKEN_ID);
        assertEq(moveSets[0], 11);
        assertEq(moveSets[1], 12);
        assertEq(moveSets[2], 13);

        vm.expectRevert(abi.encodeWithSelector(MoveSetSlotsFull.selector, TOKEN_ID));
        skills.grantMoveSet(TOKEN_ID, 14);

        skills.grantActiveSkill(TOKEN_ID, 21);
        skills.grantActiveSkill(TOKEN_ID, 22);
        skills.grantActiveSkill(TOKEN_ID, 23);
        skills.grantPassiveSkill(TOKEN_ID, 31);
        skills.grantPassiveSkill(TOKEN_ID, 32);

        assertTrue(skills.hasActiveSkill(TOKEN_ID, 21));
        assertFalse(skills.hasActiveSkill(TOKEN_ID, 31));
        assertTrue(skills.hasPassiveSkill(TOKEN_ID, 31));
        assertEq(skills.getActiveSkillCount(TOKEN_ID), 3);
        assertEq(skills.getPassiveSkillCount(TOKEN_ID), 2);

        uint32[] memory activePage = skills.getActiveSkills(TOKEN_ID, 1, 8);
        assertEq(activePage.length, 2);
        assertEq(activePage[0], 22);
        assertEq(activePage[1], 23);

        uint32[] memory emptyPage = skills.getPassiveSkills(TOKEN_ID, 99, 1);
        assertEq(emptyPage.length, 0);

        vm.expectRevert(abi.encodeWithSelector(SkillAlreadyLearned.selector, TOKEN_ID, uint32(21)));
        skills.grantActiveSkill(TOKEN_ID, 21);
    }

    function testLearningRequiresCanonicalPairIdleTokenAndValidArtId() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidArtId.selector, uint32(0)));
        skills.grantActiveSkill(TOKEN_ID, 0);

        SkillsActivityController controller = new SkillsActivityController();
        binderData.setActivityController(77, address(controller));
        controller.start(binderData, TOKEN_ID, 77);

        vm.expectRevert(abi.encodeWithSelector(UnitNotIdle.selector, TOKEN_ID, uint8(77)));
        skills.grantPassiveSkill(TOKEN_ID, 41);

        BinderSkills alternateImplementation = new BinderSkills();
        ERC1967Proxy alternateProxy = new ERC1967Proxy(
            address(alternateImplementation),
            abi.encodeCall(BinderSkills.initialize, (address(this), address(binderData), address(centralConsole)))
        );
        BinderSkills alternateSkills = BinderSkills(address(alternateProxy));

        vm.expectRevert(
            abi.encodeWithSelector(CanonicalSkillsMismatch.selector, address(skills), address(alternateSkills))
        );
        alternateSkills.grantActiveSkill(TOKEN_ID, 42);
    }

    function testLearningValidatesCurrentArtDefinitionAndClassEligibility() public {
        vm.expectRevert(abi.encodeWithSelector(BinderSkills.ArtDoesNotExist.selector, uint32(999)));
        skills.grantActiveSkill(TOKEN_ID, 999);

        vm.expectRevert(
            abi.encodeWithSelector(
                BinderSkills.ArtTypeMismatch.selector,
                uint32(21),
                BinderIds.ART_TYPE_MOVE_SET,
                BinderIds.ART_TYPE_ACTIVE
            )
        );
        skills.grantMoveSet(TOKEN_ID, 21);

        arts.addArt(_art(41, BinderIds.ART_TYPE_PASSIVE), new uint256[](0));
        arts.setArtEnabled(41, false, 2);
        vm.expectRevert(abi.encodeWithSelector(BinderSkills.ArtNotEnabled.selector, uint32(41), uint16(2)));
        skills.grantPassiveSkill(TOKEN_ID, 41);

        uint256[] memory onlyAnotherClass = new uint256[](1);
        onlyAnotherClass[0] = 2;
        arts.addArt(_art(42, BinderIds.ART_TYPE_ACTIVE), onlyAnotherClass);
        vm.expectRevert(
            abi.encodeWithSelector(
                BinderSkills.ArtClassIneligible.selector, TOKEN_ID, uint256(1), uint32(42), uint16(1)
            )
        );
        skills.grantActiveSkill(TOKEN_ID, 42);
    }

    function testLearningRejectsOutdatedAndGraveyardBinders() public {
        binderData.setClassVersion(1, 2);
        vm.expectRevert(abi.encodeWithSelector(BinderSkills.UnitNotReadyToLearn.selector, TOKEN_ID));
        skills.grantActiveSkill(TOKEN_ID, 21);

        uint8[8] memory updatedValues = [uint8(10), 10, 10, 10, 10, 10, 10, 10];
        binderStructs.StaticStats memory updatedStats = binderStructs.StaticStats({stats: updatedValues});
        binderStructs.DynamicStats memory updatedVitals =
            binderStructs.DynamicStats({maxHP: 100, maxMP: 50, currentHP: 100, currentMP: 50});
        binderData.updateNFTStats(TOKEN_ID, updatedStats, updatedVitals);
        binderData.setGraveyard(address(0xDEAD));
        binderData.adminUpdatePersistentVitals(TOKEN_ID, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(BinderSkills.UnitInGraveyard.selector, TOKEN_ID));
        skills.grantActiveSkill(TOKEN_ID, 21);
    }

    function testUupsUpgradePreservesLearnedSkillStorage() public {
        skills.grantMoveSet(TOKEN_ID, 11);
        skills.grantActiveSkill(TOKEN_ID, 21);
        skills.grantPassiveSkill(TOKEN_ID, 31);

        BinderSkillsV2 versionTwoImplementation = new BinderSkillsV2();
        vm.prank(OTHER);
        vm.expectRevert();
        skills.upgradeTo(address(versionTwoImplementation));

        skills.upgradeTo(address(versionTwoImplementation));
        BinderSkillsV2 upgradedSkills = BinderSkillsV2(address(skills));

        uint32[3] memory moveSets = upgradedSkills.getMoveSets(TOKEN_ID);
        assertEq(moveSets[0], 11);
        assertTrue(upgradedSkills.hasActiveSkill(TOKEN_ID, 21));
        assertTrue(upgradedSkills.hasPassiveSkill(TOKEN_ID, 31));
        assertEq(upgradedSkills.binderData(), address(binderData));
        assertEq(upgradedSkills.centralConsole(), address(centralConsole));

        upgradedSkills.setUpgradeMarker(2);
        assertEq(upgradedSkills.upgradeMarker(), 2);
    }

    function testCentralConsoleMigrationPreservesLearnedSkills() public {
        skills.grantActiveSkill(TOKEN_ID, 21);
        CentralConsole replacementConsole = new CentralConsole(address(this), address(binderData));
        binderData.grantRole(binderData.CONFIG_ROLE(), address(replacementConsole));
        skills.grantRole(skills.DEFAULT_ADMIN_ROLE(), address(replacementConsole));
        replacementConsole.setBinderSkills(address(skills));

        assertEq(skills.centralConsole(), address(replacementConsole));
        assertTrue(skills.hasActiveSkill(TOKEN_ID, 21));
        assertTrue(skills.isCanonicalPair());
    }

    function _mintToken() internal {
        binderData.setClassVersion(1, 1);
        uint8[8] memory statValues = [uint8(10), 10, 10, 10, 10, 10, 10, 10];
        binderStructs.StaticStats memory staticStats = binderStructs.StaticStats({stats: statValues});
        binderStructs.DynamicStats memory dynamicStats =
            binderStructs.DynamicStats({maxHP: 100, maxMP: 50, currentHP: 100, currentMP: 50});
        binderData._mintRandomNFT(ALICE, 1, "Knight", 1, "Rare", staticStats, dynamicStats);
    }

    function _configureArts() internal {
        for (uint32 artId = 11; artId <= 14; ++artId) {
            arts.addArt(_art(artId, BinderIds.ART_TYPE_MOVE_SET), new uint256[](0));
        }
        for (uint32 artId = 21; artId <= 23; ++artId) {
            arts.addArt(_art(artId, BinderIds.ART_TYPE_ACTIVE), new uint256[](0));
        }
        for (uint32 artId = 31; artId <= 32; ++artId) {
            arts.addArt(_art(artId, BinderIds.ART_TYPE_PASSIVE), new uint256[](0));
        }
    }

    function _art(uint32 artId, uint8 artTypeId)
        internal
        pure
        returns (binderStructs.ArtDefinition memory definition)
    {
        definition.artId = artId;
        definition.name = "Test Art";
        definition.artTypeId = artTypeId;
        definition.effectTypeId = BinderIds.EFFECT_TYPE_DAMAGE;
        definition.patternTypeId = BinderIds.PATTERN_TYPE_SELF;
        definition.version = 1;
        definition.enabled = true;
    }
}
