// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@limitbreak/tm-core-lib/src/utils/access/OwnableBasic.sol";
import "@limitbreak/tm-core-lib/src/utils/token/CreatorTokenBase.sol";
import "../interfaces/IBook0fItems.sol";
import "../interfaces/IBinderInventory.sol";
import "../interfaces/ICreatorTokenTransferValidatorV5.sol";
import "../interfaces/IItemMetadataBuilder.sol";

/// @notice Shared authority and transfer-policy plumbing for the three item collections.
abstract contract ItemCollectionBase is OwnableBasic, CreatorTokenBase {
    IBook0fItems public immutable book;
    IItemMetadataBuilder public immutable metadataBuilder;
    address public inventory;
    string public baseImageURI;
    mapping(address => bool) public issuers;

    event IssuerUpdated(address indexed issuer, bool allowed);
    event InventoryUpdated(address indexed inventory);
    event BaseImageURIUpdated(string value);
    event TransferRulesetConfigured(
        uint8 rulesetId, address indexed customRuleset, uint8 globalOptions, uint16 rulesetOptions
    );
    event TransferListApplied(uint48 indexed listId);

    error UnauthorizedIssuer(address caller);
    error UnauthorizedInventory(address caller);
    error InvalidAddress();
    error DirectBinderDepositBlocked(address account);

    constructor(address centralConsole, address validator, address bookAddress, address metadataBuilderAddress)
        Ownable(centralConsole)
        CreatorTokenBase(validator)
    {
        if (bookAddress.code.length == 0 || metadataBuilderAddress.code.length == 0) revert InvalidAddress();
        book = IBook0fItems(bookAddress);
        metadataBuilder = IItemMetadataBuilder(metadataBuilderAddress);
    }

    modifier onlyIssuer() {
        if (!issuers[msg.sender]) revert UnauthorizedIssuer(msg.sender);
        _;
    }

    modifier onlyInventory() {
        if (msg.sender != inventory) revert UnauthorizedInventory(msg.sender);
        _;
    }

    function setIssuer(address issuer, bool allowed) external onlyOwner {
        if (issuer == address(0)) revert InvalidAddress();
        issuers[issuer] = allowed;
        emit IssuerUpdated(issuer, allowed);
    }

    function setInventory(address inventoryAddress) external onlyOwner {
        if (inventoryAddress.code.length == 0 || (inventory != address(0) && inventory != inventoryAddress)) {
            revert InvalidAddress();
        }
        inventory = inventoryAddress;
        emit InventoryUpdated(inventoryAddress);
    }

    function setBaseImageURI(string calldata value) external onlyOwner {
        baseImageURI = value;
        emit BaseImageURIUpdated(value);
    }

    function configureTransferRuleset(
        uint8 rulesetId,
        address customRuleset,
        uint8 globalOptions,
        uint16 rulesetOptions
    ) external onlyOwner {
        ICreatorTokenTransferValidatorV5(getTransferValidator()).setRulesetOfCollection(
            address(this), rulesetId, customRuleset, globalOptions, rulesetOptions
        );
        emit TransferRulesetConfigured(rulesetId, customRuleset, globalOptions, rulesetOptions);
    }

    function applyTransferList(uint48 listId) external onlyOwner {
        ICreatorTokenTransferValidatorV5(getTransferValidator()).applyListToCollection(address(this), listId);
        emit TransferListApplied(listId);
    }

    function policyDiagnostics()
        external
        view
        returns (address validator, ICreatorTokenTransferValidatorV5.CollectionSecurityPolicy memory policy)
    {
        validator = getTransferValidator();
        policy = ICreatorTokenTransferValidatorV5(validator).getCollectionSecurityPolicy(address(this));
    }

    function _requireInventoryRoute(address caller, address to) internal view {
        if (inventory != address(0) && IBinderInventory(inventory).isBinderAccount(to) && caller != inventory) {
            revert DirectBinderDepositBlocked(to);
        }
    }
}
