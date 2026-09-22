// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts-4.8/proxy/ERC1967/ERC1967Proxy.sol";
import {BinderData} from "../modular/BinderData.sol";
import {BinderSkills} from "../modular/BinderSkills.sol";
import {CentralConsole} from "../modular/supportContract/CentralConsole.sol";
import {Book0fArts} from "../modular/shelf/Book0fArts.sol";
import {Book0fItems} from "../modular/shelf/Book0fItems.sol";
import {binderStructs} from "../modular/supportContract/binderStructs.sol";
import {BinderIds} from "../modular/supportContract/binderIds.sol";
import {TomeConfig, TomeBurnPolicy} from "../modular/Items/ItemStruct.sol";

contract TomeInventoryMock {
    uint256 public consumed;
    uint256 public locked;
    uint16 public tomeId = 1;

    function isTomeInInventory(uint256, uint256) external pure returns (bool) {
        return true;
    }

    function tomeIdInInventory(uint256, uint256) external view returns (uint16) {
        return tomeId;
    }

    function consumeTomeForLearning(uint256, uint256 tomeTokenId) external {
        consumed = tomeTokenId;
    }

    function lockTomeForLearning(uint256, uint256 tomeTokenId) external {
        locked = tomeTokenId;
    }

    function unlockTomeForLearning(uint256, uint256) external {
        locked = 0;
    }

    function setTomeId(uint16 next) external {
        tomeId = next;
    }
}

interface EntropyCallbackTarget {
    function _entropyCallback(uint64 sequence, address provider, bytes32 randomNumber) external;
}

contract TomeEntropyMock {
    uint64 public constant SEQUENCE = 1;

    function getFeeV2(address, uint32) external pure returns (uint128) {
        return 0;
    }

    function requestV2(address, bytes32, uint32) external payable returns (uint64) {
        return SEQUENCE;
    }

    function resolve(address target, address provider, bytes32 randomNumber) external {
        EntropyCallbackTarget(target)._entropyCallback(SEQUENCE, provider, randomNumber);
    }
}

contract TomeLearningTest is Test {
    address private constant ALICE = address(0xA11CE);
    BinderData private binderData;
    BinderSkills private skills;
    CentralConsole private registry;
    Book0fArts private arts;
    Book0fItems private items;
    TomeInventoryMock private inventory;
    TomeEntropyMock private entropy;

    function setUp() public {
        binderData = new BinderData(address(this), "");
        binderData.setAuthorizedBinderLogic(address(this), true);
        registry = new CentralConsole(address(this), address(binderData));
        binderData.grantRole(binderData.CONFIG_ROLE(), address(registry));
        BinderSkills implementation = new BinderSkills();
        skills = BinderSkills(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(BinderSkills.initialize, (address(this), address(binderData), address(registry)))
                )
            )
        );
        registry.setBinderSkills(address(skills));
        binderData.grantRole(binderData.METADATA_REFRESH_ROLE(), address(skills));
        arts = new Book0fArts(address(this));
        registry.setBook0fArts(address(arts));
        arts.addArt(_art(), new uint256[](0));
        items = new Book0fItems(address(registry), address(this), address(arts));
        inventory = new TomeInventoryMock();
        vm.prank(address(registry));
        items.addTome(_tome());
        vm.prank(address(registry));
        items.addTome(_unstableTome());
        vm.prank(address(registry));
        skills.setTomeLearningDependencies(address(items), address(inventory), address(0), address(0));
        _mintBinder();
    }

    function testDeterministicTomeBurnsAndRecordsCurrentArtVersion() public {
        vm.prank(ALICE);
        skills.learnFromTome(1, 77);

        assertEq(inventory.consumed(), 77);
        assertTrue(skills.hasActiveSkill(1, 1));
        assertEq(skills.getLearnedArtVersion(1, 1), 1);
    }

    function testUnstableTomeLocksThenResolvesThroughEntropy() public {
        entropy = new TomeEntropyMock();
        vm.prank(address(registry));
        skills.setTomeLearningDependencies(address(items), address(inventory), address(entropy), address(0xBEEF));
        inventory.setTomeId(2);

        vm.prank(ALICE);
        skills.learnFromTome(1, 88);
        assertEq(inventory.locked(), 88);

        entropy.resolve(address(skills), address(0xBEEF), bytes32(0));
        assertEq(inventory.consumed(), 88);
        assertTrue(skills.hasActiveSkill(1, 1));
    }

    function testTomeRefreshesAnObsoleteVersionWithoutDuplicatingTheSkill() public {
        vm.prank(ALICE);
        skills.learnFromTome(1, 77);
        binderStructs.ArtDefinition memory definition = _art();
        definition.version = 2;
        arts.updateArt(definition, new uint256[](0));
        assertEq(skills.getLearnedArtVersion(1, 1), 1);

        vm.prank(ALICE);
        skills.learnFromTome(1, 78);
        assertEq(skills.getLearnedArtVersion(1, 1), 2);
        assertEq(skills.getActiveSkillCount(1), 1);
        assertEq(inventory.consumed(), 78);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSignature("SkillAlreadyLearned(uint256,uint32)", uint256(1), uint32(1)));
        skills.learnFromTome(1, 79);
        assertEq(inventory.consumed(), 78);
    }

    function testGrantAndTomeShareVersionRefreshForEveryArtType() public {
        for (uint8 kind = BinderIds.ART_TYPE_MOVE_SET; kind <= BinderIds.ART_TYPE_PASSIVE; ++kind) {
            uint32 artId = uint32(kind) + 10;
            binderStructs.ArtDefinition memory definition = _art();
            definition.artId = artId;
            definition.artTypeId = kind;
            arts.addArt(definition, new uint256[](0));
            TomeConfig memory tome = _tome();
            tome.artId = artId;
            vm.prank(address(registry));
            uint16 tomeId = items.addTome(tome);
            inventory.setTomeId(tomeId);
            vm.prank(ALICE);
            skills.learnFromTome(1, artId);

            definition.version = 2;
            arts.updateArt(definition, new uint256[](0));
            if (kind == BinderIds.ART_TYPE_MOVE_SET) skills.grantMoveSet(1, artId);
            else if (kind == BinderIds.ART_TYPE_ACTIVE) skills.grantActiveSkill(1, artId);
            else skills.grantPassiveSkill(1, artId);
            assertEq(skills.getLearnedArtVersion(1, artId), 2);
        }
        assertEq(skills.getActiveSkillCount(1), 1);
        assertEq(skills.getPassiveSkillCount(1), 1);
        uint32[3] memory moves = skills.getMoveSets(1);
        assertEq(moves[0], uint32(BinderIds.ART_TYPE_MOVE_SET) + 10);
        assertEq(moves[1], 0);
    }

    function _mintBinder() private {
        binderData.setClassVersion(1, 1);
        binderStructs.StaticStats memory stats =
            binderStructs.StaticStats({stats: [uint8(10), 10, 10, 10, 10, 10, 10, 10]});
        binderStructs.DynamicStats memory vitals =
            binderStructs.DynamicStats({maxHP: 100, maxMP: 50, currentHP: 100, currentMP: 50});
        binderData._mintRandomNFT(ALICE, 1, "Knight", 1, "Rare", stats, vitals);
    }

    function _art() private pure returns (binderStructs.ArtDefinition memory definition) {
        definition.artId = 1;
        definition.name = "Tome Art";
        definition.artTypeId = BinderIds.ART_TYPE_ACTIVE;
        definition.effectTypeId = BinderIds.EFFECT_TYPE_DAMAGE;
        definition.patternTypeId = BinderIds.PATTERN_TYPE_SELF;
        definition.version = 1;
        definition.enabled = true;
    }

    function _tome() private pure returns (TomeConfig memory config) {
        config.enabled = true;
        config.itemName = "Deterministic Tome";
        config.artId = 1;
        config.learnSuccessBps = 10_000;
        config.burnPolicy = TomeBurnPolicy.ON_SUCCESS;
    }

    function _unstableTome() private pure returns (TomeConfig memory config) {
        config = _tome();
        config.itemName = "Unstable Tome";
        config.learnSuccessBps = 5_000;
        config.burnPolicy = TomeBurnPolicy.ON_ATTEMPT;
    }
}
