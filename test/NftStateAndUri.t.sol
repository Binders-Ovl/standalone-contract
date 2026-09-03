// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../modular/BinderData.sol";
import "../modular/Book0fLife.sol";
import "../modular/Book0fArts.sol";
import "../modular/scripts/InitializeGameData.sol";
import "../modular/supportContract/binderStructs.sol";
import "../modular/supportContract/BinderMetadata.sol";

/// @dev Narrow read-only Skills stand-in for URI/state regression coverage.
contract MetadataSkillsStub {
    address public immutable binderData;

    constructor(address binderDataAddress) {
        binderData = binderDataAddress;
    }

    function getMoveSets(uint256) external pure returns (uint32[3] memory moveSets) {
        return moveSets;
    }

    function hasActiveSkill(uint256, uint32) external pure returns (bool) {
        return false;
    }

    function hasPassiveSkill(uint256, uint32) external pure returns (bool) {
        return false;
    }

    function getActiveSkillCount(uint256) external pure returns (uint256) {
        return 0;
    }

    function getPassiveSkillCount(uint256) external pure returns (uint256) {
        return 0;
    }

    function getActiveSkills(uint256, uint256, uint256) external pure returns (uint32[] memory) {
        return new uint32[](0);
    }

    function getPassiveSkills(uint256, uint256, uint256) external pure returns (uint32[] memory) {
        return new uint32[](0);
    }
}

/// @dev Test-only controller. Production activity controllers own their own
/// authorization and settlement rules before invoking these BinderData calls.
contract MockActivityController {
    BinderData internal immutable binderData;

    constructor(BinderData binderData_) {
        binderData = binderData_;
    }

    function start(uint256 tokenId, uint8 activityId, uint48 lockedUntil) external {
        binderData.startActivity(tokenId, activityId, lockedUntil);
    }

    function end(uint256 tokenId) external {
        binderData.endActivity(tokenId);
    }
}

/// @dev Test-only stand-in for the future Graveyard's item/rule validator.
contract GraveyardResurrectionController {
    function resurrect(BinderData binderData, uint256 tokenId, address recipient, uint16 currentHP, uint16 currentMP)
        external
    {
        binderData.resurrectFromGraveyard(tokenId, recipient, currentHP, currentMP);
    }
}

contract NftStateAndUriTest is Test {
    event MetadataUpdate(uint256 tokenId);
    event AdminPersistentVitalsUpdated(
        uint256 indexed tokenId, uint16 currentHP, uint16 currentMP, address indexed admin
    );
    event BatchMetadataUpdate(uint256 fromTokenId, uint256 toTokenId);

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant MARKET = address(0xBEEF);
    address internal constant GRAVEYARD = address(0xDEAD);
    uint256 internal constant TOKEN_ID = 1;

    BinderData internal binderData;
    BinderMetadata internal metadata;
    Book0fLife internal book0fLife;
    Book0fArts internal book0fArts;
    MockActivityController internal expedition;
    MockActivityController internal otherActivity;

    function setUp() public {
        binderData = new BinderData(address(this), "ipfs://images/");
        binderData.setAuthorizedBinderLogic(address(this), true);
        book0fLife = new Book0fLife();
        book0fArts = new Book0fArts(address(this));
        book0fLife.registerRarity(1, "Rare");
        uint8[8] memory minStats = [uint8(1), 1, 1, 1, 1, 1, 1, 1];
        uint8[8] memory maxStats = [uint8(20), 20, 20, 20, 20, 20, 20, 20];
        book0fLife.addNewClass(
            1,
            "Knight",
            1,
            binderStructs.ClassConfig({
                minStats: minStats,
                maxStats: maxStats,
                totalPoints: 8,
                hpPerVit: 10,
                mpPerWis: 10
            }),
            1
        );
        binderData.setClassVersion(1, 1);

        MetadataSkillsStub skills = new MetadataSkillsStub(address(binderData));
        metadata = new BinderMetadata(
            address(binderData), address(skills), address(book0fLife), address(book0fArts), address(this)
        );
        binderData.setBinderMetadata(address(metadata));

        expedition = new MockActivityController(binderData);
        otherActivity = new MockActivityController(binderData);
        binderData.setActivityController(8, address(expedition));
        binderData.setActivityController(9, address(otherActivity));
        metadata.setActivityName(8, "Expedition");
        binderData.refreshAllMetadata();

        uint8[8] memory statValues = [uint8(11), 12, 13, 14, 15, 16, 17, 18];
        binderStructs.StaticStats memory staticStats = binderStructs.StaticStats({stats: statValues});
        binderStructs.DynamicStats memory dynamicStats =
            binderStructs.DynamicStats({maxHP: 150, maxMP: 70, currentHP: 143, currentMP: 54});
        binderData._mintRandomNFT(ALICE, 1, 'Knight "One"', 1, "Rare", staticStats, dynamicStats);
    }

    function testDecodedTokenURIAndAggregateStateStayConsistent() public view {
        binderStructs.NFTMetadata memory nftMetadata = binderData.getNFTDetails(TOKEN_ID);
        binderStructs.UnitStateView memory state = binderData.getUnitState(TOKEN_ID);
        BinderMetadata.UnitDetailsView memory details = metadata.getUnitDetails(TOKEN_ID);
        string memory json = _decodeDataUri(binderData.tokenURI(TOKEN_ID));

        assertEq(nftMetadata.name, 'Knight "One"#1');
        assertEq(details.name, nftMetadata.name);
        assertEq(details.classId, nftMetadata.classId);
        assertEq(details.rarityId, nftMetadata.rarityId);
        assertEq(details.rarityName, "Rare");
        assertEq(details.staticStats.stats[7], 18);
        assertEq(details.dynamicStats.maxHP, 150);
        assertEq(details.dynamicStats.currentHP, 143);
        assertEq(details.dynamicStats.maxMP, 70);
        assertEq(details.dynamicStats.currentMP, 54);
        assertEq(details.readyToArm, state.readyToArm);
        assertEq(details.idle, state.idle);
        assertEq(details.transferable, state.transferable);
        assertEq(details.activity.activityId, state.activity.activityId);
        assertEq(details.activity.lockedUntil, state.activity.lockedUntil);
        assertEq(details.activityName, "Idle");

        assertTrue(_contains(json, '"name":"Knight \\"One\\"#1"'));
        assertTrue(_contains(json, '"image":"ipfs://images/1.gif"'));
        assertTrue(_contains(json, '"trait_type":"ClassId","value":"1"'));
        assertTrue(_contains(json, '"trait_type":"Rarity","value":"Rare"'));
        assertTrue(_contains(json, '"trait_type":"STR","value":11'));
        assertTrue(_contains(json, '"trait_type":"STA","value":18'));
        assertTrue(_contains(json, '"trait_type":"MaxHP","value":150'));
        assertTrue(_contains(json, '"trait_type":"CurrentHP","value":143'));
        assertTrue(_contains(json, '"trait_type":"MaxMP","value":70'));
        assertTrue(_contains(json, '"trait_type":"CurrentMP","value":54'));
        assertTrue(_contains(json, '"trait_type":"Ready To Arm","value":"True"'));
        assertTrue(_contains(json, '"trait_type":"Activity","value":"Idle"'));
        assertTrue(_contains(json, '"trait_type":"Transfer Status","value":"Transferable"'));
        assertFalse(_contains(json, "nationId"));
    }

    function testPermanentMintAndFullStatsRejectInvalidIdsVersionsAndVitals() public {
        uint8[8] memory statValues = [uint8(1), 1, 1, 1, 1, 1, 1, 1];
        binderStructs.StaticStats memory staticStats = binderStructs.StaticStats({stats: statValues});
        binderStructs.DynamicStats memory validVitals =
            binderStructs.DynamicStats({maxHP: 10, maxMP: 10, currentHP: 10, currentMP: 10});

        vm.expectRevert(
            abi.encodeWithSelector(BinderData.InvalidPermanentMetadata.selector, uint256(0), uint8(1), uint16(0))
        );
        binderData._mintRandomNFT(ALICE, 0, "Invalid", 1, "Rare", staticStats, validVitals);

        binderStructs.DynamicStats memory invalidVitals =
            binderStructs.DynamicStats({maxHP: 10, maxMP: 10, currentHP: 11, currentMP: 10});
        vm.expectRevert(
            abi.encodeWithSelector(
                BinderData.InvalidPermanentVitals.selector, uint16(11), uint16(10), uint16(10), uint16(10)
            )
        );
        binderData._mintRandomNFT(ALICE, 1, "Invalid", 1, "Rare", staticStats, invalidVitals);

        binderData.setClassVersion(1, 2);
        vm.expectRevert(
            abi.encodeWithSelector(
                BinderData.InvalidPermanentVitals.selector, uint16(11), uint16(10), uint16(10), uint16(10)
            )
        );
        binderData.updateNFTStats(TOKEN_ID, staticStats, invalidVitals);
    }

    function testFuzzAdminPersistentVitalsRemainWithinConfiguredBounds(uint16 requestedHP, uint16 requestedMP) public {
        vm.assume(requestedHP != 0);
        binderData.adminUpdatePersistentVitals(TOKEN_ID, requestedHP, requestedMP);
        binderStructs.DynamicStats memory vitals = binderData.getNFTDetails(TOKEN_ID).dynamicStats;
        assertLe(vitals.currentHP, vitals.maxHP);
        assertLe(vitals.currentMP, vitals.maxMP);
    }

    function testFutureActivityIsConfigOnlyAndBlocksStaleListingTransfer() public {
        vm.prank(ALICE);
        binderData.approve(MARKET, TOKEN_ID);

        vm.expectEmit(false, false, false, true, address(binderData));
        emit MetadataUpdate(TOKEN_ID);
        expedition.start(TOKEN_ID, 8, uint48(block.timestamp + 1 days));

        binderStructs.UnitStateView memory state = binderData.getUnitState(TOKEN_ID);
        BinderMetadata.UnitDetailsView memory details = metadata.getUnitDetails(TOKEN_ID);
        assertFalse(state.idle);
        assertFalse(state.transferable);
        assertEq(state.activity.activityId, 8);
        assertEq(details.activityName, "Expedition");
        assertTrue(
            _contains(_decodeDataUri(binderData.tokenURI(TOKEN_ID)), '"trait_type":"Activity","value":"Expedition"')
        );

        vm.expectRevert(abi.encodeWithSelector(BinderData.TokenBusy.selector, TOKEN_ID, 8));
        vm.prank(MARKET);
        binderData.transferFrom(ALICE, BOB, TOKEN_ID);

        vm.expectRevert(
            abi.encodeWithSelector(BinderData.UnauthorizedActivityController.selector, 8, address(otherActivity))
        );
        otherActivity.end(TOKEN_ID);

        vm.expectEmit(false, false, false, true, address(binderData));
        emit MetadataUpdate(TOKEN_ID);
        expedition.end(TOKEN_ID);
        assertTrue(binderData.getUnitState(TOKEN_ID).idle);
        assertTrue(binderData.getUnitState(TOKEN_ID).transferable);
    }

    function testUnknownActivityFallbackAndEmergencyClear() public {
        otherActivity.start(TOKEN_ID, 9, 0);
        BinderMetadata.UnitDetailsView memory details = metadata.getUnitDetails(TOKEN_ID);
        assertEq(details.activityName, "Activity #9");
        assertTrue(_contains(_decodeDataUri(binderData.tokenURI(TOKEN_ID)), "Activity #9"));

        vm.expectEmit(false, false, false, true, address(binderData));
        emit MetadataUpdate(TOKEN_ID);
        binderData.forceClearActivity(TOKEN_ID);
        assertTrue(binderData.getUnitState(TOKEN_ID).idle);
    }

    function testVersionSnapshotAllowsExitButPreventsAnotherEntryUntilUpgrade() public {
        expedition.start(TOKEN_ID, 8, 0);

        vm.expectEmit(false, false, false, true, address(binderData));
        emit BatchMetadataUpdate(1, 1);
        binderData.setClassVersion(1, 2);

        binderStructs.UnitStateView memory activeState = binderData.getUnitState(TOKEN_ID);
        assertFalse(activeState.readyToArm);
        assertFalse(activeState.idle);
        assertFalse(activeState.transferable);
        assertTrue(
            _contains(_decodeDataUri(binderData.tokenURI(TOKEN_ID)), '"trait_type":"Ready To Arm","value":"False"')
        );

        uint8[8] memory replacementStatValues = [uint8(21), 22, 23, 24, 25, 26, 27, 28];
        binderStructs.StaticStats memory replacementStatic = binderStructs.StaticStats({stats: replacementStatValues});
        binderStructs.DynamicStats memory replacementDynamic =
            binderStructs.DynamicStats({maxHP: 250, maxMP: 120, currentHP: 200, currentMP: 100});
        vm.expectRevert(abi.encodeWithSelector(BinderData.TokenBusy.selector, TOKEN_ID, 8));
        binderData.updateNFTStats(TOKEN_ID, replacementStatic, replacementDynamic);

        expedition.end(TOKEN_ID);
        binderStructs.UnitStateView memory idleOutdatedState = binderData.getUnitState(TOKEN_ID);
        assertFalse(idleOutdatedState.readyToArm);
        assertTrue(idleOutdatedState.idle);
        assertTrue(idleOutdatedState.transferable);

        vm.prank(ALICE);
        binderData.transferFrom(ALICE, BOB, TOKEN_ID);
        assertEq(binderData.ownerOf(TOKEN_ID), BOB);

        vm.expectRevert(abi.encodeWithSelector(BinderData.UnitNotReadyToArm.selector, TOKEN_ID));
        expedition.start(TOKEN_ID, 8, 0);

        vm.expectEmit(false, false, false, true, address(binderData));
        emit MetadataUpdate(TOKEN_ID);
        binderData.updateNFTStats(TOKEN_ID, replacementStatic, replacementDynamic);
        assertTrue(binderData.getUnitState(TOKEN_ID).readyToArm);
        expedition.start(TOKEN_ID, 8, 0);
    }

    function testGraveyardClearsActivityAndIsTerminallyNonTransferable() public {
        binderData.setGraveyard(GRAVEYARD);
        expedition.start(TOKEN_ID, 8, 0);

        vm.expectRevert(abi.encodeWithSelector(BinderData.TokenBusy.selector, TOKEN_ID, uint8(8)));
        binderData.adminUpdatePersistentVitals(TOKEN_ID, 0, 54);
        expedition.end(TOKEN_ID);
        binderData.adminUpdatePersistentVitals(TOKEN_ID, 0, 54);

        binderStructs.UnitStateView memory state = binderData.getUnitState(TOKEN_ID);
        assertEq(binderData.ownerOf(TOKEN_ID), GRAVEYARD);
        assertTrue(state.idle);
        assertFalse(state.transferable);

        vm.expectRevert(abi.encodeWithSelector(BinderData.TokenInGraveyard.selector, TOKEN_ID));
        vm.prank(GRAVEYARD);
        binderData.transferFrom(GRAVEYARD, BOB, TOKEN_ID);
    }

    function testGraveyardIsOneTimeAndResurrectionIsNarrowAndReversible() public {
        GraveyardResurrectionController graveyard = new GraveyardResurrectionController();
        binderData.setGraveyard(address(graveyard));
        binderData.adminUpdatePersistentVitals(TOKEN_ID, 0, 50);
        assertEq(binderData.ownerOf(TOKEN_ID), address(graveyard));

        vm.expectRevert(abi.encodeWithSelector(BinderData.GraveyardAlreadyConfigured.selector, address(graveyard)));
        binderData.setGraveyard(address(0xBEEF));

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(BinderData.UnauthorizedResurrection.selector, ALICE));
        binderData.resurrectFromGraveyard(TOKEN_ID, ALICE, 50, 25);

        vm.expectRevert(
            abi.encodeWithSelector(
                BinderData.InvalidResurrectionVitals.selector, TOKEN_ID, uint16(0), uint16(25), uint16(150), uint16(70)
            )
        );
        graveyard.resurrect(binderData, TOKEN_ID, ALICE, 0, 25);

        graveyard.resurrect(binderData, TOKEN_ID, ALICE, 50, 25);
        assertEq(binderData.ownerOf(TOKEN_ID), ALICE);
        binderStructs.NFTMetadata memory resurrected = binderData.getNFTDetails(TOKEN_ID);
        assertEq(resurrected.dynamicStats.currentHP, 50);
        assertEq(resurrected.dynamicStats.currentMP, 25);

        binderData.adminUpdatePersistentVitals(TOKEN_ID, 0, 25);
        binderData.burnGraveyardedBinder(TOKEN_ID);
        vm.expectRevert(abi.encodeWithSelector(BinderData.InvalidToken.selector, TOKEN_ID));
        graveyard.resurrect(binderData, TOKEN_ID, ALICE, 50, 25);
    }

    function testErc4906AndPauseSemantics() public {
        assertTrue(binderData.supportsInterface(0x49064906));
        assertEq(uint256(uint32(binderData.ERC4906_INTERFACE_ID())), uint256(uint32(0x49064906)));

        binderData.pause();
        assertFalse(binderData.getUnitState(TOKEN_ID).transferable);
        binderData.unpause();
        assertTrue(binderData.getUnitState(TOKEN_ID).transferable);

        vm.expectEmit(true, false, false, true, address(binderData));
        emit AdminPersistentVitalsUpdated(TOKEN_ID, 140, 53, address(this));
        binderData.adminUpdatePersistentVitals(TOKEN_ID, 140, 53);
        binderStructs.NFTMetadata memory nftMetadata = binderData.getNFTDetails(TOKEN_ID);
        assertEq(nftMetadata.dynamicStats.currentHP, 140);
        assertEq(nftMetadata.dynamicStats.currentMP, 53);
    }

    function testRuntimeRoleConfiguratorAssignsRolesOnTargetContracts() public {
        InitializeGameData initializer = new InitializeGameData();
        address binderLogic = address(new MockActivityController(binderData));
        address fusionMinter = address(new MockActivityController(binderData));
        address scaleOfBalance = address(0x5CA1E);

        binderData.grantRole(binderData.DEFAULT_ADMIN_ROLE(), address(initializer));
        book0fLife.grantRole(book0fLife.DEFAULT_ADMIN_ROLE(), address(initializer));
        initializer.configureRuntimeRoles(
            address(book0fLife), address(binderData), binderLogic, fusionMinter, scaleOfBalance
        );

        assertTrue(binderData.authorizedBinderLogic(binderLogic));
        assertTrue(binderData.authorizedFusionMinter(fusionMinter));
        assertFalse(binderData.hasRole(binderData.MINTER_ROLE(), binderLogic));
        assertFalse(binderData.hasRole(binderData.FUSION_ROLE(), fusionMinter));
        assertTrue(binderData.hasRole(binderData.CONFIG_ROLE(), scaleOfBalance));
        assertTrue(book0fLife.hasRole(book0fLife.FUSION_MINTER(), fusionMinter));
        assertTrue(book0fLife.hasRole(book0fLife.CONFIG_ROLE(), scaleOfBalance));
    }

    function _decodeDataUri(string memory uri) internal pure returns (string memory) {
        bytes memory encodedUri = bytes(uri);
        bytes memory prefix = bytes("data:application/json;base64,");
        require(encodedUri.length >= prefix.length, "URI too short");
        for (uint256 i = 0; i < prefix.length; ++i) {
            require(encodedUri[i] == prefix[i], "Unexpected URI prefix");
        }

        uint256 encodedLength = encodedUri.length - prefix.length;
        require(encodedLength % 4 == 0, "Invalid Base64 length");
        uint256 padding;
        if (encodedUri[encodedUri.length - 1] == "=") ++padding;
        if (encodedUri[encodedUri.length - 2] == "=") ++padding;

        bytes memory decoded = new bytes((encodedLength / 4) * 3 - padding);
        uint256 outputIndex;
        for (uint256 i = prefix.length; i < encodedUri.length; i += 4) {
            uint24 chunk = (uint24(_base64Value(encodedUri[i])) << 18) | (uint24(_base64Value(encodedUri[i + 1])) << 12)
                | (uint24(_base64Value(encodedUri[i + 2])) << 6) | uint24(_base64Value(encodedUri[i + 3]));
            decoded[outputIndex++] = bytes1(uint8(chunk >> 16));
            if (encodedUri[i + 2] != "=") decoded[outputIndex++] = bytes1(uint8(chunk >> 8));
            if (encodedUri[i + 3] != "=") decoded[outputIndex++] = bytes1(uint8(chunk));
        }
        return string(decoded);
    }

    function _base64Value(bytes1 character) internal pure returns (uint8) {
        uint8 value = uint8(character);
        if (value >= 65 && value <= 90) return value - 65;
        if (value >= 97 && value <= 122) return value - 71;
        if (value >= 48 && value <= 57) return value + 4;
        if (character == "+") return 62;
        if (character == "/" || character == "=") return 63;
        revert("Invalid Base64 character");
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory source = bytes(haystack);
        bytes memory target = bytes(needle);
        if (target.length == 0) return true;
        if (target.length > source.length) return false;
        for (uint256 i = 0; i <= source.length - target.length; ++i) {
            bool matches = true;
            for (uint256 j = 0; j < target.length; ++j) {
                if (source[i + j] != target[j]) {
                    matches = false;
                    break;
                }
            }
            if (matches) return true;
        }
        return false;
    }
}
