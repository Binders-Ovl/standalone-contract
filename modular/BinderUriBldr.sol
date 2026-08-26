// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-4.8/access/Ownable.sol";
import "@openzeppelin/contracts-4.8/utils/Base64.sol";
import "@openzeppelin/contracts-4.8/utils/Strings.sol";
import "./supportContract/binderStructs.sol";

interface IBinderDataURI {
    function getNFTDetails(uint256 tokenId) external view returns (binderStructs.NFTMetadata memory);
    function getUnitState(uint256 tokenId) external view returns (binderStructs.UnitStateView memory);
    function baseImageURI() external view returns (string memory);
}

interface IBook0fLifeURI {
    function getRarityName(uint8 rarityId) external view returns (string memory);
}

/// @notice Read-only dynamic metadata renderer and Binders frontend aggregate view.
/// @dev It never owns or mutates NFT gameplay state. BinderData and Book0fLife
/// remain the authoritative sources for instance state and rarity presentation.
contract BinderUriBldr is Ownable {
    struct UnitDetailsView {
        string name;
        uint256 classId;
        uint8 rarityId;
        string rarityName;
        binderStructs.StaticStats staticStats;
        binderStructs.DynamicStats dynamicStats;
        bool readyToArm;
        bool idle;
        bool transferable;
        binderStructs.ActivityState activity;
        string activityName;
    }

    IBinderDataURI public immutable binderData;
    IBook0fLifeURI public immutable book0fLife;
    mapping(uint8 => string) private _activityNames;

    event ActivityNameUpdated(uint8 indexed activityId, string displayName);

    error InvalidAddress();
    error EmptyActivityName();
    error InvalidIdleActivityName();

    constructor(address binderDataAddress, address book0fLifeAddress, address initialOwner) {
        if (binderDataAddress == address(0) || book0fLifeAddress == address(0) || initialOwner == address(0)) {
            revert InvalidAddress();
        }
        binderData = IBinderDataURI(binderDataAddress);
        book0fLife = IBook0fLifeURI(book0fLifeAddress);
        _activityNames[0] = "Idle";
        transferOwnership(initialOwner);
    }

    /// @notice Configures a presentation-only label. BinderData decides which IDs are valid/active.
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

    function tokenURI(uint256 tokenId) external view returns (string memory) {
        UnitDetailsView memory details = _buildUnitDetails(tokenId);
        string memory json = _buildJson(details);
        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(bytes(json))));
    }

    function getActivityName(uint8 activityId) external view returns (string memory) {
        return _activityName(activityId);
    }

    function _buildUnitDetails(uint256 tokenId) internal view returns (UnitDetailsView memory details) {
        binderStructs.NFTMetadata memory meta = binderData.getNFTDetails(tokenId);
        binderStructs.UnitStateView memory state = binderData.getUnitState(tokenId);
        details = UnitDetailsView({
            name: meta.name,
            classId: meta.classId,
            rarityId: meta.rarityId,
            rarityName: book0fLife.getRarityName(meta.rarityId),
            staticStats: meta.staticStats,
            dynamicStats: meta.dynamicStats,
            readyToArm: state.readyToArm,
            idle: state.idle,
            transferable: state.transferable,
            activity: state.activity,
            activityName: _activityName(state.activity.activityId)
        });
    }

    function _buildJson(UnitDetailsView memory details) internal view returns (string memory) {
        string memory image =
            string(abi.encodePacked(binderData.baseImageURI(), Strings.toString(details.classId), ".gif"));
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
        string memory classAndRarity = string(
            abi.encodePacked(
                _stringAttribute("ClassId", Strings.toString(details.classId)),
                ",",
                _stringAttribute("Rarity", details.rarityName)
            )
        );
        string memory staticAttributes = string(
            abi.encodePacked(
                _numberAttribute("STR", stats.stats[0]),
                ",",
                _numberAttribute("INT", stats.stats[1]),
                ",",
                _numberAttribute("AGI", stats.stats[2]),
                ",",
                _numberAttribute("DEX", stats.stats[3]),
                ",",
                _numberAttribute("VIT", stats.stats[4]),
                ",",
                _numberAttribute("WIS", stats.stats[5]),
                ",",
                _numberAttribute("SPD", stats.stats[6]),
                ",",
                _numberAttribute("STA", stats.stats[7])
            )
        );
        string memory dynamicAttributes = string(
            abi.encodePacked(
                _numberAttribute("MaxHP", dynamicStats.maxHP),
                ",",
                _numberAttribute("CurrentHP", dynamicStats.currentHP),
                ",",
                _numberAttribute("MaxMP", dynamicStats.maxMP),
                ",",
                _numberAttribute("CurrentMP", dynamicStats.currentMP)
            )
        );
        string memory stateAttributes = string(
            abi.encodePacked(
                _stringAttribute("Ready To Arm", _boolName(details.readyToArm)),
                ",",
                _stringAttribute("Activity", details.activityName),
                ",",
                _stringAttribute("Transfer Status", details.transferable ? "Transferable" : "Locked")
            )
        );
        return string(
            abi.encodePacked(classAndRarity, ",", staticAttributes, ",", dynamicAttributes, ",", stateAttributes)
        );
    }

    function _stringAttribute(string memory traitType, string memory value) internal pure returns (string memory) {
        return
            string(abi.encodePacked('{"trait_type":"', _escapeJson(traitType), '","value":"', _escapeJson(value), '"}'));
    }

    function _numberAttribute(string memory traitType, uint256 value) internal pure returns (string memory) {
        return string(abi.encodePacked('{"trait_type":"', traitType, '","value":', Strings.toString(value), "}"));
    }

    function _activityName(uint8 activityId) internal view returns (string memory) {
        string memory configuredName = _activityNames[activityId];
        if (bytes(configuredName).length != 0) return configuredName;
        return string(abi.encodePacked("Activity #", Strings.toString(activityId)));
    }

    function _boolName(bool value) internal pure returns (string memory) {
        return value ? "True" : "False";
    }

    /// @dev Escapes JSON-sensitive bytes in admin-configured class, rarity, activity, and URI strings.
    function _escapeJson(string memory raw) internal pure returns (string memory) {
        bytes memory source = bytes(raw);
        bytes memory escaped = new bytes(source.length * 6);
        uint256 outputLength;
        bytes16 hexSymbols = "0123456789abcdef";

        for (uint256 i = 0; i < source.length; ++i) {
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
