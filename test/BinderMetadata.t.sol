// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts-4.8/proxy/ERC1967/ERC1967Proxy.sol";
import "../modular/BinderData.sol";
import "../modular/BinderSkills.sol";
import "../modular/Book0fLife.sol";
import "../modular/Book0fArts.sol";
import "../modular/supportContract/binderStructs.sol";
import "../modular/supportContract/BinderMetadata.sol";
import "../modular/supportContract/CentralConsole.sol";
import "../modular/interfaces/ICentralConsole.sol";

contract ForeignMetadata {
    address public immutable binderData;

    constructor(address binderDataAddress) {
        binderData = binderDataAddress;
    }

    function tokenURI(uint256) external pure returns (string memory) {
        return "";
    }
}

contract MetadataActivityController {
    function start(BinderData binderData, uint256 tokenId, uint8 activityId) external {
        binderData.startActivity(tokenId, activityId, 0);
    }

    function end(BinderData binderData, uint256 tokenId) external {
        binderData.endActivity(tokenId);
    }
}

contract BinderMetadataTest is Test {
    address internal constant ALICE = address(0xA11CE);
    uint256 internal constant TOKEN_ID = 1;

    BinderData internal binderData;
    BinderMetadata internal metadata;
    BinderSkills internal skills;
    Book0fLife internal book0fLife;
    Book0fArts internal book0fArts;
    CentralConsole internal centralConsole;
    MetadataActivityController internal expedition;

    function setUp() public {
        binderData = new BinderData(address(this), "ipfs://images/");
        binderData.setAuthorizedBinderLogic(address(this), true);
        centralConsole = new CentralConsole(address(this), address(binderData));
        binderData.grantRole(binderData.CONFIG_ROLE(), address(centralConsole));
        book0fLife = new Book0fLife();
        book0fArts = new Book0fArts(address(this));

        book0fLife.registerRarity(3, "Rare");
        book0fLife.addNewClass(12, "Knight", 3, _classConfig(), 1);
        binderData.setClassVersion(12, 1);
        _addArts();

        BinderSkills implementation = new BinderSkills();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(BinderSkills.initialize, (address(this), address(binderData), address(centralConsole)))
        );
        skills = BinderSkills(address(proxy));
        centralConsole.setBinderSkills(address(skills));
        centralConsole.setBook0fLife(address(book0fLife));
        centralConsole.setBook0fArts(address(book0fArts));
        binderData.grantRole(binderData.METADATA_REFRESH_ROLE(), address(skills));

        metadata = new BinderMetadata(
            address(binderData), address(skills), address(book0fLife), address(book0fArts), address(this)
        );
        centralConsole.setBinderMetadata(address(metadata));
        binderData.setBinderMetadata(address(metadata));

        expedition = new MetadataActivityController();
        binderData.setActivityController(8, address(expedition));
        metadata.setActivityName(8, "Expedition");
        _mintToken();
        skills.grantMoveSet(TOKEN_ID, 11);
        skills.grantMoveSet(TOKEN_ID, 12);
        skills.grantMoveSet(TOKEN_ID, 13);
        skills.grantActiveSkill(TOKEN_ID, 21);
        skills.grantActiveSkill(TOKEN_ID, 22);
        skills.grantPassiveSkill(TOKEN_ID, 31);
    }

    function testTypedAggregateResolvesNamesAndUsesPagedSkills() public view {
        BinderMetadata.UnitDetailsView memory details = metadata.getUnitDetails(TOKEN_ID);
        assertEq(details.name, "Knight#1");
        assertEq(details.classId, 12);
        assertEq(details.className, "Knight");
        assertEq(details.rarityId, 3);
        assertEq(details.rarityName, "Rare");
        assertTrue(details.idle);
        assertEq(details.activityName, "Idle");
        assertEq(details.moveSets[0], 11);
        assertEq(details.moveSets[2], 13);
        assertEq(details.moveSetNames[0], "Slash");
        assertEq(details.moveSetNames[1], "Shield Bash");
        assertEq(details.moveSetNames[2], "Impale");
        assertEq(details.activeSkillCount, 2);
        assertEq(details.passiveSkillCount, 1);

        (uint32[3] memory moveSets, string[3] memory moveSetNames) = metadata.getMoveSets(TOKEN_ID);
        assertEq(moveSets[0], 11);
        assertEq(moveSetNames[0], "Slash");

        BinderMetadata.SkillDetailsPage memory activePage = metadata.getActiveSkills(TOKEN_ID, 1, 1);
        assertEq(activePage.artIds.length, 1);
        assertEq(activePage.artIds[0], 22);
        assertEq(activePage.artNames[0], "Shield Wall");

        BinderMetadata.SkillDetailsPage memory passivePage = metadata.getPassiveSkills(TOKEN_ID, 0, 8);
        assertEq(passivePage.artIds.length, 1);
        assertEq(passivePage.artIds[0], 31);
        assertEq(passivePage.artNames[0], "Fortitude");
    }

    function testMetadataUriPreservesStableTraitsAndAddsArtsTraits() public view {
        string memory json = _decodeDataUri(binderData.tokenURI(TOKEN_ID));
        assertTrue(_contains(json, '"name":"Knight#1"'));
        assertTrue(_contains(json, '"image":"ipfs://images/12.gif"'));
        assertTrue(_contains(json, '"trait_type":"ClassId","value":"12"'));
        assertTrue(_contains(json, '"trait_type":"Rarity","value":"Rare"'));
        assertTrue(_contains(json, '"trait_type":"STR","value":11'));
        assertTrue(_contains(json, '"trait_type":"CurrentMP","value":54'));
        assertTrue(_contains(json, '"trait_type":"Ready To Arm","value":"True"'));
        assertTrue(_contains(json, '"trait_type":"Activity","value":"Idle"'));
        assertTrue(_contains(json, '"trait_type":"Transfer Status","value":"Transferable"'));
        assertTrue(_contains(json, '"trait_type":"Move Set 1","value":"Slash"'));
        assertTrue(_contains(json, '"trait_type":"Move Set 2","value":"Shield Bash"'));
        assertTrue(_contains(json, '"trait_type":"Move Set 3","value":"Impale"'));
        assertTrue(_contains(json, '"trait_type":"Active Skill Count","value":2'));
        assertTrue(_contains(json, '"trait_type":"Passive Skill Count","value":1'));
    }

    function testActivityLabelsAndUnknownFallbackAreReadOnlyPresentation() public {
        expedition.start(binderData, TOKEN_ID, 8);
        assertEq(metadata.getUnitDetails(TOKEN_ID).activityName, "Expedition");
        assertTrue(_contains(_decodeDataUri(metadata.tokenURI(TOKEN_ID)), "Expedition"));

        expedition.end(binderData, TOKEN_ID);
        binderData.setActivityController(9, address(expedition));
        expedition.start(binderData, TOKEN_ID, 9);
        assertEq(metadata.getUnitDetails(TOKEN_ID).activityName, "Activity #9");
        assertEq(metadata.getActivityName(0), "Idle");
    }

    function testCentralConsoleRejectsMetadataForAnotherCollection() public {
        BinderData otherBinderData = new BinderData(address(this), "");
        ForeignMetadata mismatchedMetadata = new ForeignMetadata(address(otherBinderData));
        vm.expectRevert(
            abi.encodeWithSelector(CanonicalPairMismatch.selector, address(binderData), address(otherBinderData))
        );
        centralConsole.setBinderMetadata(address(mismatchedMetadata));
    }

    function testBookOfArtsCutoverRequiresAndPerformsAtomicMetadataRewire() public {
        Book0fArts replacementArts = new Book0fArts(address(this));
        BinderMetadata replacementMetadata = new BinderMetadata(
            address(binderData), address(skills), address(book0fLife), address(replacementArts), address(this)
        );

        vm.expectRevert(
            abi.encodeWithSelector(CanonicalPairMismatch.selector, address(replacementArts), address(book0fArts))
        );
        centralConsole.setBook0fArts(address(replacementArts));

        centralConsole.configureBook0fArts(address(replacementArts), address(replacementMetadata));
        assertEq(centralConsole.book0fArts(), address(replacementArts));
        assertEq(centralConsole.binderMetadata(), address(replacementMetadata));
        assertEq(binderData.binderMetadataAddress(), address(replacementMetadata));
        ICentralConsole.WiringStatus memory status = centralConsole.getWiringStatus();
        assertTrue(status.binderDataMetadataMatch);
        assertTrue(status.metadataDependenciesMatch);
    }

    function testSkillsReplacementRequiresAtomicCompatibleMetadata() public {
        BinderSkills replacementSkills = _newSkillsProxy();
        BinderMetadata replacementMetadata = new BinderMetadata(
            address(binderData), address(replacementSkills), address(book0fLife), address(book0fArts), address(this)
        );

        vm.expectRevert(
            abi.encodeWithSelector(CanonicalSkillsMismatch.selector, address(replacementSkills), address(skills))
        );
        centralConsole.setBinderSkills(address(replacementSkills));
        assertEq(centralConsole.binderSkills(), address(skills));
        assertEq(binderData.binderMetadataAddress(), address(metadata));
        assertTrue(binderData.hasRole(binderData.METADATA_REFRESH_ROLE(), address(skills)));

        centralConsole.configureBinderSkills(address(replacementSkills), address(replacementMetadata));
        assertEq(centralConsole.binderSkills(), address(replacementSkills));
        assertEq(centralConsole.binderMetadata(), address(replacementMetadata));
        assertEq(binderData.binderMetadataAddress(), address(replacementMetadata));
        assertFalse(binderData.hasRole(binderData.METADATA_REFRESH_ROLE(), address(skills)));
        assertTrue(binderData.hasRole(binderData.METADATA_REFRESH_ROLE(), address(replacementSkills)));
    }

    function testCompositeSkillsCutoverRevertLeavesPointersAndRefreshAuthorityUntouched() public {
        BinderSkills replacementSkills = _newSkillsProxy();
        BinderMetadata incompatibleMetadata = new BinderMetadata(
            address(binderData), address(skills), address(book0fLife), address(book0fArts), address(this)
        );

        vm.expectRevert(
            abi.encodeWithSelector(CanonicalSkillsMismatch.selector, address(replacementSkills), address(skills))
        );
        centralConsole.configureBinderSkills(address(replacementSkills), address(incompatibleMetadata));

        assertEq(centralConsole.binderSkills(), address(skills));
        assertEq(centralConsole.binderMetadata(), address(metadata));
        assertEq(binderData.binderMetadataAddress(), address(metadata));
        assertTrue(binderData.hasRole(binderData.METADATA_REFRESH_ROLE(), address(skills)));
        assertFalse(binderData.hasRole(binderData.METADATA_REFRESH_ROLE(), address(replacementSkills)));
    }

    function _newSkillsProxy() internal returns (BinderSkills replacementSkills) {
        BinderSkills replacementImplementation = new BinderSkills();
        ERC1967Proxy replacementProxy = new ERC1967Proxy(
            address(replacementImplementation),
            abi.encodeCall(BinderSkills.initialize, (address(this), address(binderData), address(centralConsole)))
        );
        replacementSkills = BinderSkills(address(replacementProxy));
    }

    function _mintToken() internal {
        uint8[8] memory values = [uint8(11), 12, 13, 14, 15, 16, 17, 18];
        binderStructs.StaticStats memory staticStats = binderStructs.StaticStats({stats: values});
        binderStructs.DynamicStats memory dynamicStats =
            binderStructs.DynamicStats({maxHP: 150, maxMP: 70, currentHP: 143, currentMP: 54});
        binderData._mintRandomNFT(ALICE, 12, "Knight", 3, "Rare", staticStats, dynamicStats);
    }

    function _addArts() internal {
        uint256[] memory noEligibilityRestriction = new uint256[](0);
        book0fArts.addArt(_art(11, "Slash", 1), noEligibilityRestriction);
        book0fArts.addArt(_art(12, "Shield Bash", 1), noEligibilityRestriction);
        book0fArts.addArt(_art(13, "Impale", 1), noEligibilityRestriction);
        book0fArts.addArt(_art(21, "Fireball", 2), noEligibilityRestriction);
        book0fArts.addArt(_art(22, "Shield Wall", 2), noEligibilityRestriction);
        book0fArts.addArt(_art(31, "Fortitude", 3), noEligibilityRestriction);
    }

    function _classConfig() internal pure returns (binderStructs.ClassConfig memory config) {
        uint8[8] memory minStats = [uint8(1), 1, 1, 1, 1, 1, 1, 1];
        uint8[8] memory maxStats = [uint8(9), 9, 9, 9, 9, 9, 9, 9];
        config = binderStructs.ClassConfig({
            minStats: minStats,
            maxStats: maxStats,
            totalPoints: 8,
            hpPerVit: 10,
            mpPerWis: 10
        });
    }

    function _art(uint32 artId, string memory name, uint8 artTypeId)
        internal
        pure
        returns (binderStructs.ArtDefinition memory definition)
    {
        definition.artId = artId;
        definition.name = name;
        definition.artTypeId = artTypeId;
        definition.effectTypeId = 1;
        definition.patternTypeId = 1;
        definition.range = 1;
        definition.version = 1;
        definition.enabled = true;
    }

    function _decodeDataUri(string memory uri) internal pure returns (string memory) {
        bytes memory encodedUri = bytes(uri);
        bytes memory prefix = bytes("data:application/json;base64,");
        require(encodedUri.length >= prefix.length, "URI too short");
        for (uint256 i; i < prefix.length; ++i) {
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
        for (uint256 i; i <= source.length - target.length; ++i) {
            bool matches = true;
            for (uint256 j; j < target.length; ++j) {
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
