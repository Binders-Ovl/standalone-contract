// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-4.8/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts-4.8/token/ERC721/extensions/ERC721Pausable.sol";
import "@openzeppelin/contracts-4.8/access/Ownable.sol";
import "@openzeppelin/contracts-4.8/access/AccessControl.sol";
import "@openzeppelin/contracts-4.8/utils/Strings.sol";
import "./supportContract/binderStructs.sol";

/// Interface for BinderUriBldr
interface IBinderUriBldr {
    function tokenURI(uint256 tokenId) external view returns (string memory);
}

contract BinderData is ERC721, ERC721Pausable, Ownable, AccessControl {

    // ==== ---- Roles ---- ====
    bytes32 public constant CONFIG_ROLE = keccak256("CONFIG_ROLE");
    bytes32 public constant BATTLE_ROLE = keccak256("BATTLE_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant FUSION_ROLE = keccak256("FUSION_ROLE");

    // ==== ---- Error Handling ---- ====
    error InvalidUriFormat();
    error MaxSupplyReached();
    error InvalidToken(uint256 tokenId);
    error AlreadyUpgraded();
    error NotDeadYet();
    error UriBuilderNotSet();
    error InvalidClassId();
    error InvalidNewVersionTooHigh();
    error GraveyardNotSet();

    // ==== ---- State Variables ---- =====
    uint256 public maxSupply = 1000000;  // Fake supply, as it expected to grow currently set to  1,000,000
    uint128 internal supplyBuffer = 125;
    uint256 internal supplyIncrement = 10000;
    uint128 private _tokenIdCounter = 1;

    string public baseImageURI;
    address public binderGraveyard;     //  Address of BinderGraveyard.sol
    address public binderUriBldrAddress; // Address of Binder NFT Decripter (BinderUriBldr.sol)

    // Mapping to store NFT Metadata
    mapping(uint256 => binderStructs.NFTMetadata) private _tokenMetadata;
    mapping(uint256 => uint16) public classVersion;             // Mapping to store classVersion for each Class [Not individual NFT, check configVersion for local variable]

    // ==== ---- Events ---- ====
    event NFTMinted(address indexed owner, uint256 tokenId, string rarity, string className);
    event NFTFusionMinted(address indexed owner, uint256 tokenId, string rarity, string className);
    event SupplyAdded(uint256 indexed amount);
    event NFTStatsUpdated(uint256 indexed tokenId, uint8[8] newStats, uint16 latestVersion);

    constructor(address initialOwner, string memory newBaseImageURI) ERC721("Binders", "UBIND") {
        if (bytes(newBaseImageURI).length > 0 && bytes(newBaseImageURI)[bytes(newBaseImageURI).length - 1] != '/'){
            revert InvalidUriFormat();
        }
        baseImageURI = newBaseImageURI;

        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
        _grantRole(CONFIG_ROLE, initialOwner);
        _grantRole(BATTLE_ROLE, initialOwner);
        _grantRole(MINTER_ROLE, initialOwner);
        _grantRole(FUSION_ROLE, initialOwner);
    }

    // ===== ---- Core Minting Function ---- ====
    /// ================= Internal Mint =================

    function _mintNFT(
        address recipient,
        uint256 classId,
        string memory className,
        string memory rarity,
        binderStructs.StaticStats memory staticStats,
        binderStructs.DynamicStats memory dynamicStats,
        uint16 configVersion
    ) internal returns (uint256) {

        if (_tokenIdCounter > maxSupply){
            revert MaxSupplyReached();
        }
        // Auto increment maxSupply when near the end
        if (maxSupply - _tokenIdCounter <= supplyBuffer) {
            maxSupply += supplyIncrement;
            emit SupplyAdded(supplyIncrement);
        }

        // TODO: Add check for rarity (Common, Uncommon, Rare, Epic, Legend) --> moved to Logic

        uint256 tokenId = _tokenIdCounter++;
        _safeMint(recipient, tokenId);

        _tokenMetadata[tokenId] = binderStructs.NFTMetadata({
            name: string(abi.encodePacked(className, "#", Strings.toString(tokenId))),
            classId: classId,
            rarity: rarity,
            staticStats: staticStats,
            dynamicStats: dynamicStats,
            configVersion: configVersion
        });

        return tokenId;
    }

    /// ================= Minting function and fusion  =================
    // External Minting Function to be called by BinderMinter.sol
    function _mintRandomNFT(
        address recipient,
        uint256 classId,
        string memory className,
        string memory rarity,
        binderStructs.StaticStats memory staticStats,
        binderStructs.DynamicStats memory dynamicStats
    ) external onlyRole(MINTER_ROLE) returns (uint256) {
        uint16 version = classVersion[classId]; //
        uint256 tokenId = _mintNFT(recipient, classId, className, rarity, staticStats, dynamicStats, version);
        emit NFTMinted(recipient, tokenId, rarity, className);
        return tokenId;
    }

    // External Minting Function to be called by FusionMinter.sol
    function _mint4Fusion(
        address recipient,
        uint256 classId,
        string memory className,
        string memory rarity,
        binderStructs.StaticStats memory staticStats,
        binderStructs.DynamicStats memory dynamicStats
    ) external onlyRole(FUSION_ROLE) returns (uint256) {
        uint16 version = classVersion[classId]; //
        uint256 tokenId = _mintNFT(recipient, classId, className, rarity, staticStats, dynamicStats, version);
        emit NFTFusionMinted(recipient, tokenId, className, rarity);
        return tokenId;
    }

    /// End of Core Minting Function
    /// ================= Update NFT Stats =================

    // =======------- Stats Update for Balancing thru Scale0fBalance.sol,
    // =======------- triggered after Library0fCreation.sol updated
    function updateNFTStats(
        uint256 tokenId,
        binderStructs.StaticStats calldata stats,
        binderStructs.DynamicStats calldata dynamicStats
    ) external onlyRole(CONFIG_ROLE) {
        if (!_exists(tokenId)){
            revert InvalidToken(tokenId);
        }

        binderStructs.NFTMetadata storage meta = _tokenMetadata[tokenId];
        uint256 classId = meta.classId;
        uint16 latestVersion = classVersion[classId];

        if (meta.configVersion >= latestVersion){
            revert AlreadyUpgraded();
        }

        meta.staticStats = stats;
        meta.dynamicStats = dynamicStats;
        meta.configVersion = classVersion[classId];

        emit NFTStatsUpdated(tokenId, stats.stats, latestVersion);
    }

    // ... Battle Logic Role
    function updateCurrentStats(uint256 tokenId, uint16 currentHP, uint16 currentMP) external onlyRole(BATTLE_ROLE) {
        if (!_exists(tokenId)){
            revert InvalidToken(tokenId);
        }

        binderStructs.NFTMetadata storage meta = _tokenMetadata[tokenId];

        meta.dynamicStats.currentHP = currentHP > meta.dynamicStats.maxHP ? meta.dynamicStats.maxHP : currentHP;
        meta.dynamicStats.currentMP = currentMP > meta.dynamicStats.maxMP ? meta.dynamicStats.maxMP : currentMP;

        if (meta.dynamicStats.currentHP == 0) {
            _autoTransferToGraveyard(tokenId);
        }
    }

    // Management function for automatic retirement when an NFT reaches zero HP.
    function _autoTransferToGraveyard(uint256 tokenId) internal {
        if (_tokenMetadata[tokenId].dynamicStats.currentHP != 0) {
            revert NotDeadYet();
        }

        if (binderGraveyard == address(0)) {
            revert GraveyardNotSet();
        }

        address owner = ownerOf(tokenId);
        _transfer(owner, binderGraveyard, tokenId);
    }

    // Explicit fusion retirement path. Fusion is authorized by FUSION_ROLE;
    function tfToGraveyard(uint256 tokenId) external onlyRole(FUSION_ROLE) {
        if (binderGraveyard == address(0)) {
            revert GraveyardNotSet();
        }

        address owner = ownerOf(tokenId);
        _transfer(owner, binderGraveyard, tokenId);
    }

    /// ================= tokenURI and Metadata =================

    // View functions to get NFT Metadata as JSON
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        if (!_exists(tokenId)){
            revert InvalidToken(tokenId);
        }
        if (binderUriBldrAddress == address(0)){
            revert UriBuilderNotSet();
        }

        return IBinderUriBldr(binderUriBldrAddress).tokenURI(tokenId);
    }

    // CL : _generateAtrributes moved BinderUriBldr.sol

    /// ======================= View Functions =======================

    function getNFTClass(uint256 tokenId) external view returns (uint256) {
        if (!_exists(tokenId)){
            revert InvalidToken(tokenId);
        }
        return _tokenMetadata[tokenId].classId;
    }

    function getNFTRarity(uint256 tokenId) external view returns (string memory) {
        if (!_exists(tokenId)){
            revert InvalidToken(tokenId);
        }
        return _tokenMetadata[tokenId].rarity;
    }

    // Getter functions for configVersion
    function getConfigVersion(uint256 tokenId) external view returns (uint16) {
       if (!_exists(tokenId)){
            revert InvalidToken(tokenId);
       }
       return _tokenMetadata[tokenId].configVersion;
    }

    function getNFTDetails(uint256 tokenId) external view returns (binderStructs.NFTMetadata memory) {
        if (!_exists(tokenId)){
            revert InvalidToken(tokenId);
        }
        return _tokenMetadata[tokenId];
    }


    /// ======================= Admin Functions =======================

    // Admin function to set the address of binderUriBldr contract incase we introduce new parameters
    function setBinderUriBldr (address _bldrAddress) external onlyOwner {
        binderUriBldrAddress = _bldrAddress;
    }

    // IPFS log to set base image URI, supposed to be "classId.gif"
    function setBaseImageURI(string memory newURI) external onlyOwner {
        if (bytes(newURI).length > 0 && bytes(newURI)[bytes(newURI).length-1] != '/'){
            revert InvalidUriFormat();
        }
        baseImageURI = newURI;
    }

   // setter functions for Graveyard
   function setGraveyard(address graveyard) external onlyOwner {
       if (graveyard == address(0)) {
           revert GraveyardNotSet();
       }
       binderGraveyard = graveyard;
   }

    // Setter functions for setClassVersion to be called by Scale0fBalance.sol
    function setClassVersion(uint256 classId, uint16 version) external onlyRole(CONFIG_ROLE) {
        if(classId == 0){
            revert InvalidClassId();
        }

        if(version <= classVersion[classId]){
            revert InvalidNewVersionTooHigh();
        }
        classVersion[classId] = version;
    }

    // Pause and Unpause
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // Override required functions from OpenZeppelin Contracts
    function _beforeTokenTransfer(address from, address to, uint256 tokenId, uint256 batchSize)
        internal override(ERC721, ERC721Pausable)
    {
        super._beforeTokenTransfer(from, to, tokenId, batchSize);
    }

    /** I Use OpenZeppelin 4.8.3 this functions not exist there
    function _update(address to, uint256 tokenId, address auth)
        internal override(ERC721Enumerable, ERC721Pausable) returns (address){
            if(to == binderGraveyard){
                require(_tokenMetadata[tokenId].dynamicStats.currentHP == 0, "Not Dead Yet");
            }
            return super._update(to, tokenId, auth);
        }
     */


    function supportsInterface(bytes4 interfaceId)
        public view override(ERC721, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
