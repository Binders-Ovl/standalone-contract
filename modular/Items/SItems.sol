// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./ItemCollectionBase.sol";
import "@limitbreak/tm-core-lib/src/token/erc1155/ERC1155C.sol";

/// @notice Stackable ERC-1155C items; maximumStack is enforced only by BinderInventory.
contract SItems is ItemCollectionBase, ERC1155C {
    mapping(uint16 => string) private _imageURIBySItemId;

    event SItemIssued(uint16 indexed sItemId, uint128 amount, address indexed recipient, bytes32 provenance);
    event ImageURIUpdated(uint16 indexed sItemId, string value);

    error DisabledSItem(uint16 sItemId);

    constructor(address centralConsole, address validator, address bookAddress, address metadataBuilderAddress)
        ItemCollectionBase(centralConsole, validator, bookAddress, metadataBuilderAddress)
        ERC1155C("")
    {}

    function mintToWallet(address to, uint16 sItemId, uint128 amount, bytes32 provenance) external onlyIssuer {
        _requireInventoryRoute(address(0), to);
        if (!book.isSItemEnabled(sItemId) || amount == 0) revert DisabledSItem(sItemId);
        _mint(to, sItemId, amount, "");
        emit SItemIssued(sItemId, amount, to, provenance);
    }

    function mintToBinder(uint256 binderId, uint16 sItemId, uint128 amount, bytes32 provenance) external onlyIssuer {
        if (!book.isSItemEnabled(sItemId) || amount == 0) revert DisabledSItem(sItemId);
        address account = IBinderInventory(inventory).prepareSItemMint(binderId, sItemId, amount);
        _mint(account, sItemId, amount, "");
        emit SItemIssued(sItemId, amount, account, provenance);
    }

    function burnForProtocol(address from, uint16 sItemId, uint128 amount) external onlyInventory {
        _burn(from, sItemId, amount);
    }

    function protocolTransfer(address from, address to, uint16 sItemId, uint128 amount, bytes calldata data)
        external
        onlyInventory
    {
        safeTransferFrom(from, to, sItemId, amount, data);
    }

    function setImageURI(uint16 sItemId, string calldata value) external onlyOwner {
        if (!book.isSItemEnabled(sItemId) && !book.getSItem(sItemId).exists) revert DisabledSItem(sItemId);
        _imageURIBySItemId[sItemId] = value;
        emit ImageURIUpdated(sItemId, value);
    }

    function uri(uint256 id) public view override returns (string memory) {
        if (id > type(uint16).max) revert DisabledSItem(uint16(id));
        uint16 sItemId = uint16(id);
        SItemConfig memory cfg = book.getSItem(sItemId);
        if (!cfg.exists) revert DisabledSItem(sItemId);
        string memory image =
            bytes(_imageURIBySItemId[sItemId]).length == 0 ? baseImageURI : _imageURIBySItemId[sItemId];
        return metadataBuilder.tokenURI(cfg.itemName, image, sItemId, cfg.configVersion);
    }

    function isApprovedForAll(address owner_, address operator) public view override returns (bool) {
        return operator == inventory || super.isApprovedForAll(owner_, operator);
    }

    function _preValidateTransfer(
        address caller,
        address from,
        address to,
        uint256 tokenId,
        uint256 amount,
        uint256 value
    ) internal override {
        _requireInventoryRoute(caller, to);
        super._preValidateTransfer(caller, from, to, tokenId, amount, value);
    }
}
