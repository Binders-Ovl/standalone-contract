// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./ItemCollectionBase.sol";
import "@limitbreak/tm-core-lib/src/token/erc721/ERC721C.sol";

/// @notice Unique ERC-721C Tome/Grimoire instances; Art eligibility is deliberately not duplicated here.
contract TomeAndGrimoires is ItemCollectionBase, ERC721C {
    uint256 private _nextTokenId;
    mapping(uint256 => uint16) private _tomeIdOfToken;
    mapping(uint16 => string) private _imageURIByTomeId;

    event TomeIssued(uint256 indexed tokenId, uint16 indexed tomeId, address indexed recipient, bytes32 provenance);
    event ImageURIUpdated(uint16 indexed tomeId, string value);

    error DisabledTome(uint16 tomeId);

    constructor(address centralConsole, address validator, address bookAddress, address metadataBuilderAddress)
        ItemCollectionBase(centralConsole, validator, bookAddress, metadataBuilderAddress)
        ERC721C("Binders Tomes", "BTOME")
    {}

    function mintToWallet(address to, uint16 tomeId, bytes32 provenance)
        external
        onlyIssuer
        returns (uint256 tokenId)
    {
        _requireInventoryRoute(address(0), to);
        if (!book.isTomeEnabled(tomeId)) revert DisabledTome(tomeId);
        tokenId = ++_nextTokenId;
        _tomeIdOfToken[tokenId] = tomeId;
        _safeMint(to, tokenId);
        emit TomeIssued(tokenId, tomeId, to, provenance);
    }

    function mintToBinder(uint256 binderId, uint16 tomeId, bytes32 provenance)
        external
        onlyIssuer
        returns (uint256 tokenId)
    {
        if (!book.isTomeEnabled(tomeId)) revert DisabledTome(tomeId);
        tokenId = ++_nextTokenId;
        address account = IBinderInventory(inventory).prepareTomeMint(binderId, tomeId, tokenId);
        _tomeIdOfToken[tokenId] = tomeId;
        _safeMint(account, tokenId);
        emit TomeIssued(tokenId, tomeId, account, provenance);
    }

    function burnForProtocol(uint256 tokenId) external onlyInventory {
        _burn(tokenId);
    }

    function protocolTransfer(address from, address to, uint256 tokenId) external onlyInventory {
        transferFrom(from, to, tokenId);
    }

    function tomeIdOf(uint256 tokenId) external view returns (uint16) {
        ownerOf(tokenId);
        return _tomeIdOfToken[tokenId];
    }

    function setImageURI(uint16 tomeId, string calldata value) external onlyOwner {
        if (!book.isTomeEnabled(tomeId) && !book.getTome(tomeId).exists) revert DisabledTome(tomeId);
        _imageURIByTomeId[tomeId] = value;
        emit ImageURIUpdated(tomeId, value);
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        uint16 tomeId = _tomeIdOfToken[tokenId];
        ownerOf(tokenId);
        TomeConfig memory cfg = book.getTome(tomeId);
        string memory image = bytes(_imageURIByTomeId[tomeId]).length == 0 ? baseImageURI : _imageURIByTomeId[tomeId];
        return metadataBuilder.tokenURI(cfg.itemName, image, tomeId, cfg.configVersion);
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
