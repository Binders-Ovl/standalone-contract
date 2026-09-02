// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-4.8/access/Ownable.sol";
import "@openzeppelin/contracts-4.8/utils/Base64.sol";
import "@openzeppelin/contracts-4.8/utils/Strings.sol";
import "../interfaces/IBinderData.sol";
import "../interfaces/IBinderSkills.sol";
import "../interfaces/IBook0fLife.sol";
import "../interfaces/IBook0fArts.sol";
import "./binderStructs.sol";

/// @notice Read-only typed NFT lens and dynamic Base64 metadata renderer.
/// @dev It owns no gameplay state and only reads the canonical
/// BinderData/BinderSkills/Book inputs.
contract BinderMetadata is Ownable {
    struct UnitDetailsView {
        string name;
        uint256 classId;
        string className;
        uint8 rarityId;
        string rarityName;
        binderStructs.StaticStats staticStats;
        binderStructs.DynamicStats dynamicStats;
        bool readyToArm;
        bool idle;
        bool transferable;
        binderStructs.ActivityState activity;
        string activityName;
        uint32[3] moveSets;
        string[3] moveSetNames;
        uint256 activeSkillCount;
        uint256 passiveSkillCount;
    }

    struct SkillDetailsPage {
        uint32[] artIds;
        string[] artNames;
    }

    IBinderData public immutable binderData;
    IBinderSkills public immutable binderSkills;
    IBook0fLife public immutable book0fLife;
    IBook0fArts public immutable book0fArts;
    mapping(uint8 => string) private _activityNames;

    event ActivityNameUpdated(uint8 indexed activityId, string displayName);

    error InvalidAddress();
    error CanonicalInputMismatch(address expectedBinderData, address actualBinderData);
    error EmptyActivityName();
    error InvalidIdleActivityName();

    constructor(
        address binderDataAddress,
        address binderSkillsAddress,
        address book0fLifeAddress,
        address book0fArtsAddress,
        address initialOwner
    ) {
        if (
            binderDataAddress == address(0) || binderSkillsAddress == address(0) || book0fLifeAddress == address(0)
                || book0fArtsAddress == address(0) || initialOwner == address(0) || binderDataAddress.code.length == 0
                || binderSkillsAddress.code.length == 0 || book0fLifeAddress.code.length == 0
                || book0fArtsAddress.code.length == 0
        ) revert InvalidAddress();

        binderData = IBinderData(binderDataAddress);
        binderSkills = IBinderSkills(binderSkillsAddress);
        book0fLife = IBook0fLife(book0fLifeAddress);
        book0fArts = IBook0fArts(book0fArtsAddress);
        address skillsBinderData;
        try binderSkills.binderData() returns (address resolvedBinderData) {
            skillsBinderData = resolvedBinderData;
        } catch {
            revert CanonicalInputMismatch(binderDataAddress, address(0));
        }
        if (skillsBinderData != binderDataAddress) revert CanonicalInputMismatch(binderDataAddress, skillsBinderData);
        _activityNames[0] = "Idle";
        transferOwnership(initialOwner);
    }

    /// @notice Configures a presentation-only activity label; ID zero always remains Idle.
    function setActivityName(uint8 activityId, string calldata displayName) external onlyOwner {
        if (bytes(displayName).length == 0) revert EmptyActivityName();
        if (activityId == 0 && keccak256(bytes(displayName)) != keccak256(bytes("Idle"))) {
            revert InvalidIdleActivityName();
        }
        _activityNames[activityId] = displayName;
        emit ActivityNameUpdated(activityId, displayName);
    }

    function getUnitDetails(uint256 tokenId) external view returns (UnitDetailsView memory) {
        return _buildUnitDetails(tokenId);
    }

    function getMoveSets(uint256 tokenId) external view returns (uint32[3] memory moveSets, string[3] memory moveSetNames) {
        moveSets = binderSkills.getMoveSets(tokenId);
        for (uint256 i; i < moveSets.length; ++i) {
            moveSetNames[i] = _artName(moveSets[i]);
        }
    }

    function getActiveSkills(uint256 tokenId, uint256 offset, uint256 limit)
        external
        view
        returns (SkillDetailsPage memory)
    {
        return _skillPage(binderSkills.getActiveSkills(tokenId, offset, limit));
    }

    function getPassiveSkills(uint256 tokenId, uint256 offset, uint256 limit)
        external
        view
        returns (SkillDetailsPage memory)
    {
        return _skillPage(binderSkills.getPassiveSkills(tokenId, offset, limit));
    }

    function getActivityName(uint8 activityId) external view returns (string memory) {
        return _activityName(activityId);
    }

    function tokenURI(uint256 tokenId) external view returns (string memory) {
        UnitDetailsView memory details = _buildUnitDetails(tokenId);
        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(bytes(_buildJson(details)))));
    }

    function _buildUnitDetails(uint256 tokenId) internal view returns (UnitDetailsView memory details) {
        binderStructs.NFTMetadata memory meta = binderData.getNFTDetails(tokenId);
        binderStructs.UnitStateView memory state = binderData.getUnitState(tokenId);
        uint32[3] memory moveSets = binderSkills.getMoveSets(tokenId);
        string[3] memory moveSetNames;
        for (uint256 i; i < moveSets.length; ++i) moveSetNames[i] = _artName(moveSets[i]);

        details = UnitDetailsView({
            name: meta.name,
            classId: meta.classId,
            className: book0fLife.getClassName(meta.classId),
            rarityId: meta.rarityId,
            rarityName: book0fLife.getRarityName(meta.rarityId),
            staticStats: meta.staticStats,
            dynamicStats: meta.dynamicStats,
            readyToArm: state.readyToArm,
            idle: state.idle,
            transferable: state.transferable,
            activity: state.activity,
            activityName: _activityName(state.activity.activityId),
            moveSets: moveSets,
            moveSetNames: moveSetNames,
            activeSkillCount: binderSkills.getActiveSkillCount(tokenId),
            passiveSkillCount: binderSkills.getPassiveSkillCount(tokenId)
        });
    }

    function _skillPage(uint32[] memory artIds) internal view returns (SkillDetailsPage memory page) {
        string[] memory artNames = new string[](artIds.length);
        for (uint256 i; i < artIds.length; ++i) artNames[i] = _artName(artIds[i]);
        page = SkillDetailsPage({artIds: artIds, artNames: artNames});
    }

    function _buildJson(UnitDetailsView memory details) internal view returns (string memory) {
        string memory image = string(abi.encodePacked(binderData.baseImageURI(), Strings.toString(details.classId), ".gif"));
        return string(
            abi.encodePacked(
                '{"name":"',
                _escapeJson(details.name),
                '","description":"Binders Character NFT","image":"',
                _escapeJson(image),
                '","attributes":[',
                _buildAttributes(details),
                "]}"
            )
        );
    }

    function _buildAttributes(UnitDetailsView memory details) internal pure returns (string memory) {
        binderStructs.StaticStats memory stats = details.staticStats;
        binderStructs.DynamicStats memory dynamicStats = details.dynamicStats;
        string memory coreAttributes = string(
            abi.encodePacked(
                _stringAttribute("ClassId", Strings.toString(details.classId)),
                ",",
                _stringAttribute("Class", details.className),
                ",",
                _stringAttribute("Rarity", details.rarityName)
            )
        );
        string memory staticAttributes = string(
            abi.encodePacked(
                _numberAttribute("STR", stats.stats[0]), ",", _numberAttribute("INT", stats.stats[1]), ",",
                _numberAttribute("AGI", stats.stats[2]), ",", _numberAttribute("DEX", stats.stats[3]), ",",
                _numberAttribute("VIT", stats.stats[4]), ",", _numberAttribute("WIS", stats.stats[5]), ",",
                _numberAttribute("SPD", stats.stats[6]), ",", _numberAttribute("STA", stats.stats[7])
            )
        );
        string memory dynamicAttributes = string(
            abi.encodePacked(
                _numberAttribute("MaxHP", dynamicStats.maxHP), ",", _numberAttribute("CurrentHP", dynamicStats.currentHP),
                ",", _numberAttribute("MaxMP", dynamicStats.maxMP), ",",
                _numberAttribute("CurrentMP", dynamicStats.currentMP)
            )
        );
        string memory stateAttributes = string(
            abi.encodePacked(
                _stringAttribute("Ready To Arm", _boolName(details.readyToArm)), ",",
                _stringAttribute("Activity", details.activityName), ",",
                _stringAttribute("Transfer Status", details.transferable ? "Transferable" : "Locked")
            )
        );
        string memory skillAttributes = string(
            abi.encodePacked(
                _stringAttribute("Move Set 1", details.moveSetNames[0]), ",",
                _stringAttribute("Move Set 2", details.moveSetNames[1]), ",",
                _stringAttribute("Move Set 3", details.moveSetNames[2]), ",",
                _numberAttribute("Active Skill Count", details.activeSkillCount), ",",
                _numberAttribute("Passive Skill Count", details.passiveSkillCount)
            )
        );
        return string(
            abi.encodePacked(coreAttributes, ",", staticAttributes, ",", dynamicAttributes, ",", stateAttributes, ",", skillAttributes)
        );
    }

    function _artName(uint32 artId) internal view returns (string memory) {
        if (artId == 0) return "Empty";
        return book0fArts.getArtDefinition(artId).name;
    }

    function _activityName(uint8 activityId) internal view returns (string memory) {
        string memory configuredName = _activityNames[activityId];
        if (bytes(configuredName).length != 0) return configuredName;
        return string(abi.encodePacked("Activity #", Strings.toString(activityId)));
    }

    function _stringAttribute(string memory traitType, string memory value) internal pure returns (string memory) {
        return string(abi.encodePacked('{"trait_type":"', _escapeJson(traitType), '","value":"', _escapeJson(value), '"}'));
    }

    function _numberAttribute(string memory traitType, uint256 value) internal pure returns (string memory) {
        return string(abi.encodePacked('{"trait_type":"', traitType, '","value":', Strings.toString(value), "}"));
    }

    function _boolName(bool value) internal pure returns (string memory) {
        return value ? "True" : "False";
    }

    function _escapeJson(string memory raw) internal pure returns (string memory) {
        bytes memory source = bytes(raw);
        bytes memory escaped = new bytes(source.length * 6);
        uint256 outputLength;
        bytes16 hexSymbols = "0123456789abcdef";

        for (uint256 i; i < source.length; ++i) {
            bytes1 char = source[i];
            if (char == '"' || char == "\\") {
                escaped[outputLength++] = "\\";
                escaped[outputLength++] = char;
            } else if (char == bytes1(0x08)) {
                escaped[outputLength++] = "\\";
                escaped[outputLength++] = "b";
            } else if (char == bytes1(0x0c)) {
                escaped[outputLength++] = "\\";
                escaped[outputLength++] = "f";
            } else if (char == bytes1(0x0a)) {
                escaped[outputLength++] = "\\";
                escaped[outputLength++] = "n";
            } else if (char == bytes1(0x0d)) {
                escaped[outputLength++] = "\\";
                escaped[outputLength++] = "r";
            } else if (char == bytes1(0x09)) {
                escaped[outputLength++] = "\\";
                escaped[outputLength++] = "t";
            } else if (uint8(char) < 0x20) {
                escaped[outputLength++] = "\\";
                escaped[outputLength++] = "u";
                escaped[outputLength++] = "0";
                escaped[outputLength++] = "0";
                escaped[outputLength++] = hexSymbols[uint8(char) >> 4];
                escaped[outputLength++] = hexSymbols[uint8(char) & 0x0f];
            } else {
                escaped[outputLength++] = char;
            }
        }
        assembly ("memory-safe") {
            mstore(escaped, outputLength)
        }
        return string(escaped);
    }
}
