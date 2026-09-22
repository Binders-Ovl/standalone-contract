// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ICreatorTokenTransferValidatorV5 {
    struct CollectionSecurityPolicy {
        uint8 rulesetId;
        uint48 listId;
        address customRuleset;
        uint8 globalOptions;
        uint16 rulesetOptions;
        uint16 tokenType;
    }

    function setRulesetOfCollection(
        address collection,
        uint8 rulesetId,
        address customRuleset,
        uint8 globalOptions,
        uint16 rulesetOptions
    ) external;

    function applyListToCollection(address collection, uint48 listId) external;
    function createList(string calldata name) external returns (uint48 listId);
    function addAccountsToList(uint48 listId, uint8 listType, address[] calldata accounts) external;
    function addCodeHashesToList(uint48 listId, uint8 listType, bytes32[] calldata codehashes) external;
    function getCollectionSecurityPolicy(address collection) external view returns (CollectionSecurityPolicy memory);
    function listOwners(uint48 listId) external view returns (address);
}
