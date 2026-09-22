// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../supportContract/binderStructs.sol";

/// @notice Narrow configuration/read surface used by CentralConsole.
interface IScaleOfBalance {
    function binderData() external view returns (address);
    function book0fLife() external view returns (address);
    function book0fArts() external view returns (address);
    function book0fRealms() external view returns (address);
    function book0fItems() external view returns (address);
    function CONFIG_ROLE() external view returns (bytes32);
    function setBook0fLife(address book) external;
    function setBook0fArts(address book) external;
    function setBook0fRealms(address book) external;
    function setBook0fItems(address book) external;
    function updateArtBalance(binderStructs.ArtDefinition calldata definition, uint256[] calldata eligibleClassIds)
        external;
    function updateMapBalance(uint32 mapId, bool enabled, binderStructs.TileDefinition[] calldata tiles) external;
}
