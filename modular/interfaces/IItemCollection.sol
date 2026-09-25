// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Typed control-plane API shared by all three recognised item collections.
interface IItemCollection {
    function approveQuestController(address controller) external;
    function questControllers(address controller) external view returns (bool);
    function owner() external view returns (address);
    function getTransferValidator() external view returns (address);
    function setIssuer(address issuer, bool allowed) external;
    function setInventory(address inventoryAddress) external;
    function setTransferValidator(address validator) external;
    function configureTransferRuleset(
        uint8 rulesetId,
        address customRuleset,
        uint8 globalOptions,
        uint16 rulesetOptions
    ) external;
    function applyTransferList(uint48 listId) external;
    function setBaseImageURI(string calldata value) external;
    function setImageURI(uint16 libraryId, string calldata value) external;
}
