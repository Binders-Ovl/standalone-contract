// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./ItemCollectionBase.sol";
import "@limitbreak/tm-core-lib/src/token/erc721/ERC721C.sol";

/// @notice Unique ERC-721C equipment instances. Gameplay configuration remains in Book0fItems.
contract Equipment is ItemCollectionBase, ERC721C {
    uint256 private _nextTokenId;
    mapping(uint256 => uint16) private _eqIdOfToken;
    mapping(uint16 => string) private _imageURIByEqId;

    event EquipmentIssued(uint256 indexed tokenId, uint16 indexed eqId, address indexed recipient, bytes32 provenance);
    event ImageURIUpdated(uint16 indexed eqId, string value);

    error DisabledEquipment(uint16 eqId);

    constructor(address centralConsole, address validator, address bookAddress, address metadataBuilderAddress)
        ItemCollectionBase(centralConsole, validator, bookAddress, metadataBuilderAddress)
        ERC721C("Binders Equipment", "BEQ")
    {}

    function mintToWallet(address to, uint16 eqId, bytes32 provenance) external returns (uint256 tokenId) {
        bool snapshotted = _authorizeWalletMint(to, eqId, 1, provenance);
        _requireInventoryRoute(address(0), to);
        if (!snapshotted && !book.isEqEnabled(eqId)) revert DisabledEquipment(eqId);
        tokenId = ++_nextTokenId;
        _eqIdOfToken[tokenId] = eqId;
        _safeMint(to, tokenId);
        emit EquipmentIssued(tokenId, eqId, to, provenance);
    }

    function mintToBinder(uint256 binderId, uint16 eqId, bytes32 provenance)
        external
        onlyIssuer
        returns (uint256 tokenId)
    {
        if (!book.isEqEnabled(eqId)) revert DisabledEquipment(eqId);
        tokenId = ++_nextTokenId;
        address account = IBinderInventory(inventory).prepareEquipmentMint(binderId, eqId, tokenId);
        _eqIdOfToken[tokenId] = eqId;
        _safeMint(account, tokenId);
        emit EquipmentIssued(tokenId, eqId, account, provenance);
    }

    function burnForProtocol(uint256 tokenId) external onlyInventory {
        _burn(tokenId);
    }

    function protocolTransfer(address from, address to, uint256 tokenId) external onlyInventory {
        transferFrom(from, to, tokenId);
    }

    function eqIdOf(uint256 tokenId) external view returns (uint16) {
        ownerOf(tokenId);
        return _eqIdOfToken[tokenId];
    }

    function setImageURI(uint16 eqId, string calldata value) external onlyOwner {
        if (!book.isEqEnabled(eqId) && !book.getEq(eqId).exists) revert DisabledEquipment(eqId);
        _imageURIByEqId[eqId] = value;
        emit ImageURIUpdated(eqId, value);
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        uint16 eqId = _eqIdOfToken[tokenId];
        ownerOf(tokenId);
        EqConfig memory cfg = book.getEq(eqId);
        string memory image = bytes(_imageURIByEqId[eqId]).length == 0 ? baseImageURI : _imageURIByEqId[eqId];
        return metadataBuilder.tokenURI(cfg.itemName, image, eqId, cfg.configVersion);
    }

    function isApprovedForAll(address owner_, address operator) public view override returns (bool) {
        return operator == inventory || super.isApprovedForAll(owner_, operator);
    }

    function _preValidateTransfer(address caller, address from, address to, uint256 tokenId, uint256 value)
        internal
        override
    {
        _requireInventoryRoute(caller, to);
        super._preValidateTransfer(caller, from, to, tokenId, value);
    }
}
