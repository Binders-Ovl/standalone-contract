// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../modular/BinderData.sol";
import "../modular/BinderUriBldr.sol";
import "../modular/Book0fLife.sol";
import "../modular/BattleManager.sol";
import "../modular/scripts/InitializeGameData.sol";
import "../modular/supportContract/binderStructs.sol";

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

contract NftStateAndUriTest is Test {
    event MetadataUpdate(uint256 tokenId);
    event BatchMetadataUpdate(uint256 fromTokenId, uint256 toTokenId);

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant MARKET = address(0xBEEF);
    address internal constant GRAVEYARD = address(0xDEAD);
    uint256 internal constant TOKEN_ID = 1;

    BinderData internal binderData;
    BinderUriBldr internal uriBuilder;
    Book0fLife internal book0fLife;
    MockActivityController internal expedition;
    MockActivityController internal otherActivity;

    function setUp() public {
        binderData = new BinderData(address(this), "ipfs://images/");
        book0fLife = new Book0fLife();
        book0fLife.registerRarity(1, "Rare");
        binderData.setClassVersion(1, 1);

        uriBuilder = new BinderUriBldr(address(binderData), address(book0fLife), address(this));
        binderData.setBinderUriBldr(address(uriBuilder));

        expedition = new MockActivityController(binderData);
        otherActivity = new MockActivityController(binderData);
        binderData.setActivityController(8, address(expedition));
        binderData.setActivityController(9, address(otherActivity));
        uriBuilder.setActivityName(8, "Expedition");
        binderData.refreshAllMetadata();

        uint8[8] memory statValues = [uint8(11), 12, 13, 14, 15, 16, 17, 18];
        binderStructs.StaticStats memory staticStats = binderStructs.StaticStats({stats: statValues});
        binderStructs.DynamicStats memory dynamicStats =
            binderStructs.DynamicStats({maxHP: 150, maxMP: 70, currentHP: 143, currentMP: 54});
        binderData._mintRandomNFT(ALICE, 1, 'Knight "One"', 1, "Rare", staticStats, dynamicStats);
    }

    function testDecodedTokenURIAndAggregateStateStayConsistent() public view {
        binderStructs.NFTMetadata memory metadata = binderData.getNFTDetails(TOKEN_ID);
        binderStructs.UnitStateView memory state = binderData.getUnitState(TOKEN_ID);
        BinderUriBldr.UnitDetailsView memory details = uriBuilder.getUnitDetails(TOKEN_ID);
        string memory json = _decodeDataUri(binderData.tokenURI(TOKEN_ID));

        assertEq(metadata.name, 'Knight "One"#1');
        assertEq(details.name, metadata.name);
        assertEq(details.classId, metadata.classId);
        assertEq(details.rarityId, metadata.rarityId);
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

    function testFutureActivityIsConfigOnlyAndBlocksStaleListingTransfer() public {
        vm.prank(ALICE);
        binderData.approve(MARKET, TOKEN_ID);

        vm.expectEmit(false, false, false, true, address(binderData));
        emit MetadataUpdate(TOKEN_ID);
        expedition.start(TOKEN_ID, 8, uint48(block.timestamp + 1 days));

        binderStructs.UnitStateView memory state = binderData.getUnitState(TOKEN_ID);
        BinderUriBldr.UnitDetailsView memory details = uriBuilder.getUnitDetails(TOKEN_ID);
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
        BinderUriBldr.UnitDetailsView memory details = uriBuilder.getUnitDetails(TOKEN_ID);
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
        binderData.updateCurrentStats(TOKEN_ID, 0, 54);

        binderStructs.UnitStateView memory state = binderData.getUnitState(TOKEN_ID);
        assertEq(binderData.ownerOf(TOKEN_ID), GRAVEYARD);
        assertTrue(state.idle);
        assertFalse(state.transferable);

        vm.expectRevert(abi.encodeWithSelector(BinderData.TokenInGraveyard.selector, TOKEN_ID));
        vm.prank(GRAVEYARD);
        binderData.transferFrom(GRAVEYARD, BOB, TOKEN_ID);
    }

    function testErc4906AndPauseSemantics() public {
        assertTrue(binderData.supportsInterface(0x49064906));
        assertEq(uint256(uint32(binderData.ERC4906_INTERFACE_ID())), uint256(uint32(0x49064906)));

        binderData.pause();
        assertFalse(binderData.getUnitState(TOKEN_ID).transferable);
        binderData.unpause();
        assertTrue(binderData.getUnitState(TOKEN_ID).transferable);

        vm.recordLogs();
        binderData.updateCurrentStats(TOKEN_ID, 140, 53);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "ordinary HP/MP updates do not emit metadata refreshes");
    }

    function testBattleManagerRequiresRoleOnBinderDataItself() public {
        BinderBattleManager battleManager = new BinderBattleManager(address(binderData));
        battleManager.grantRole(battleManager.BATTLE_ROLE(), address(this));

        vm.expectRevert();
        battleManager.applyDamage(TOKEN_ID, 3, 0);

        binderData.grantRole(binderData.BATTLE_ROLE(), address(battleManager));
        battleManager.applyDamage(TOKEN_ID, 3, 0);
        assertEq(binderData.getNFTDetails(TOKEN_ID).dynamicStats.currentHP, 140);
    }

    function testRuntimeRoleConfiguratorAssignsRolesOnTargetContracts() public {
        InitializeGameData initializer = new InitializeGameData();
        address binderLogic = address(0xB1);
        address fusionMinter = address(0xF1);
        address scaleOfBalance = address(0x5CA1E);
        BinderBattleManager battleManager = new BinderBattleManager(address(binderData));

        binderData.grantRole(binderData.DEFAULT_ADMIN_ROLE(), address(initializer));
        book0fLife.grantRole(book0fLife.DEFAULT_ADMIN_ROLE(), address(initializer));
        initializer.configureRuntimeRoles(
            address(book0fLife), address(binderData), binderLogic, fusionMinter, scaleOfBalance
        );
        initializer.configureBattleManagerRole(address(binderData), address(battleManager));

        assertTrue(binderData.hasRole(binderData.MINTER_ROLE(), binderLogic));
        assertTrue(binderData.hasRole(binderData.FUSION_ROLE(), fusionMinter));
        assertTrue(binderData.hasRole(binderData.CONFIG_ROLE(), scaleOfBalance));
        assertTrue(binderData.hasRole(binderData.BATTLE_ROLE(), address(battleManager)));
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
