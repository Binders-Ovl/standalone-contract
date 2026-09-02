// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-4.8/access/Ownable.sol";
import "@openzeppelin/contracts-4.8/token/ERC721/utils/ERC721Holder.sol";
import "@openzeppelin/contracts-4.8/access/AccessControl.sol";
import "@openzeppelin/contracts-4.8/security/Pausable.sol";
import "@openzeppelin/contracts-4.8/security/ReentrancyGuard.sol";
import "@pythnetwork/entropy-sdk-solidity/IEntropyV2.sol";
import "@pythnetwork/entropy-sdk-solidity/IEntropyConsumer.sol";
import "./supportContract/binderStructs.sol";
import "./interfaces/IBinderData.sol";
import "./interfaces/IBook0fLife.sol";

/** Struct for Stats - Class Config - FUsionRequest */

// @notice: Array of stats that determine unit stats in following order
// STR  determine pATK (Weapon Based  Value)        ==>     uint8[0]
// INT  determine mATK (Skill Based Value)          ==>     uint8[1]
// AGI  Chance to hit                               ==>     uint8[2]
// DEX  Chance to Doodge pATK                       ==>     uint8[3]
// VIT  Detemine value of HP and pDef               ==>     uint8[4]
// WIS  Determine value of MP and mDef              ==>     uint8[5]
// SPD  Determine priority of actions               ==>     uint8[6]
// STA  Determine value of movement range           ==>     uint8[7]


contract FusionMinter is ERC721Holder, Ownable, AccessControl, Pausable, ReentrancyGuard, IEntropyConsumer {
    bytes32 public constant FUSION_OVERLORD = keccak256("FUSION_OVERLORD");
    uint32 public constant ACQ_FUSION = uint32(1) << 1;

    IBinderData public binderData;
    IBook0fLife public book0fLife;
    IEntropyV2 public entropy;
    address public entropyProvider;

    uint256 public nextFusionId;
    uint256 public fusionCost = 0.01 ether;

    mapping(uint256 => binderStructs.FusionRequest) private _fusionRequest;
    mapping(uint256 => binderStructs.AdvancedFusionRequest) private _fusionRequestAdvanced;   // PlaceHolder not Gonna be used anytime soon
    mapping(uint64 => uint256) private _entropyToFusionId;

    event FusionRequested(uint256 indexed fusionId, address user, uint256 nftId1, uint256 nftId2);
    event FusionResult(uint256 indexed fusionId, address indexed user, bool success, uint256 newTokenId, uint256 class1, uint256 class2, uint256 targetClass);
    event BaseBinderUpdated(address newBinder);
    event Book0fLifeUpdated(address newFusionLibrary);
    event AdvancedFusionRequested(uint256 fusionId, address user, uint256[] nftIds, address[] catalysts); // Placeholder for Advanced fusion emission
    event NativeFundsWithdrawn(address indexed recipient, uint256 amount);


    constructor(address binderData_, address book0fLife_, address entropyAddress, address providerAddress, address initialOwner) {
        transferOwnership(initialOwner);
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
        _grantRole(FUSION_OVERLORD, initialOwner);

        binderData = IBinderData(binderData_);
        book0fLife = IBook0fLife(book0fLife_);
        entropy = IEntropyV2(entropyAddress);
        entropyProvider = providerAddress;
    }

    /* View Functions */
    function getEntropy() internal view override returns (address) {
        return address(entropy);
    }

    /* Fusion Operations */
    // 1. Initiate riteFusion Function
    function riteFusion(uint256 nftId1, uint256 nftId2) external payable nonReentrant whenNotPaused {
        uint256 totalCost = entropy.getFeeV2(entropyProvider, 0) + fusionCost;
        require(msg.value >= totalCost, "Not enough gold my lord");

        require(
            binderData.ownerOf(nftId1) == msg.sender &&
            binderData.ownerOf(nftId2) == msg.sender,
            "Cannot sacrifice what u dont own"
        );

        binderData.safeTransferFrom(msg.sender, address(this), nftId1);
        binderData.safeTransferFrom(msg.sender, address(this), nftId2);

        uint256 fusionId = ++nextFusionId;
        _fusionRequest[fusionId] = binderStructs.FusionRequest({ user: msg.sender, nftId1: nftId1, nftId2: nftId2, resolved: false });

        _processEntropyRequest(fusionId);

        emit FusionRequested(fusionId, msg.sender, nftId1, nftId2);
    }

    // 2. Callback function for entropy request After user Initiate riteFusion Function and send entropy request to entropyCallback Function
    function entropyCallback(uint64 sequenceNumber, address _providerAddress, bytes32 randomBytes) internal nonReentrant override {
        require(msg.sender == address(entropy), "Unauthorized");
        require(_providerAddress == entropyProvider, "Invalid provider");

        uint256 fusionId = _entropyToFusionId[sequenceNumber];
        binderStructs.FusionRequest storage request = _fusionRequest[fusionId];
        require(!request.resolved, "Already processed");

        // Cache all necessary field early that will be used later
        address user = request.user;
        uint256 sId1 = request.nftId1;
        uint256 sId2 = request.nftId2;

        request.resolved = true;
        delete _entropyToFusionId[sequenceNumber];

        // Class Sorting
        (uint256 class1, uint256 class2) = _sortMi(
            binderData.getNFTClass(sId1),
            binderData.getNFTClass(sId2)
        );

        // Block I: Calculate class ID and fusion Outcome
        (bool success, uint256 targetClass) = _getFusionOutcome(class1, class2, randomBytes);
        if (success) {
            require(book0fLife.hasClassAcquisition(targetClass, ACQ_FUSION), "Fusion disabled for target");
        }

        uint256 newTokenId = _mintFusionResult(user, targetClass, randomBytes);

        binderData.tfToGraveyard(sId1);
        binderData.tfToGraveyard(sId2);

        _emitFusionResult(fusionId, user, success, newTokenId, class1, class2, targetClass);
    }

    // 3. Calculate Outcome of riteFusion Function
    function _calculateOutcome(uint256 class1, uint256 class2, bytes32 entropyBytes, uint256 outcomeClassId, uint16 successChance) internal pure
        returns (bool success, uint256 targetClass) {

        bool hasRecipe = outcomeClassId != 0;

        uint256 successRand = uint256(entropyBytes) % 10000;    // 0 - 10000 (0.00% - 100.00%)
        uint256 classRand = uint256(entropyBytes >> 128) % 10000;   // Randomized success chance for outcome class if fails

        if (hasRecipe) {
            success = successRand < successChance;
            targetClass = success ? outcomeClassId : (classRand % 2 == 0 ? class1 : class2);
        } else {
            success = false;
            targetClass = (classRand % 2 == 0) ? class1 : class2;
        }
    }

    // 4. Allocate Stats to riteFusion Function
        function _allocateStats(binderStructs.ClassConfig memory config, bytes32 seed) internal pure returns (binderStructs.StaticStats memory stats) {
        stats = binderStructs.StaticStats({ stats: config.minStats });
        bytes memory entropyBytes = abi.encodePacked(seed);
        uint8[8] memory statOrder = _generateAllocationOrder(seed);
        uint8[32] memory byteOrder = _generateBytesOrder(seed);
        uint8 usedBytes = 0;
        uint16 remainingPoints = config.totalPoints;

        while (remainingPoints > 0 && usedBytes < 32) {
            for (uint8 i = 0; i < 8 && remainingPoints > 0; i++) {
                if (usedBytes >= 32) break;
                uint8 statIndex = statOrder[i];
                uint8 byteIndex = byteOrder[usedBytes++];
                uint8 randByte = uint8(entropyBytes[byteIndex]);

                uint8 current = stats.stats[statIndex];
                uint8 maxAdd = config.maxStats[statIndex] - current;
                if (maxAdd == 0) continue;
                uint8 alloc = randByte % (maxAdd + 1);
                alloc = alloc < remainingPoints ? alloc : uint8(remainingPoints);
                stats.stats[statIndex] = current + alloc;
                remainingPoints -= alloc;
            }
        }

        while (remainingPoints > 0) {
            for (uint i = 0; i < 8 && remainingPoints > 0; i++) {
                uint8 statIndex = statOrder[i];
                uint8 current = stats.stats[statIndex];
                uint8 maxAdd = config.maxStats[statIndex] - current;
                if (maxAdd == 0) continue;
                stats.stats[statIndex] = current + 1;
                remainingPoints--;
            }
        }
    }

    /* Internal Helper Functions */

    // Core | Helper Emit function because the @dev dumb enough to manage the stack depth of entropyCallback
    function _emitFusionResult(uint256 fusionId, address user, bool success, uint256 newTokenId, uint256 class1, uint256 class2, uint256 targetClass) internal {
        emit FusionResult(fusionId, user, success, newTokenId, class1, class2, targetClass);
    }

    // Core | Helper to Resolve Outcome to reduce Stack Depth at entropyCallback
    function _resolveOutcome(uint256 class1, uint256 class2, bytes32 randomBytes, binderStructs.FusionOutcome[] memory outcomes, uint16 successChance) internal pure returns (
    bool success, uint256 targetClass) {
        uint256 outcomeClassId = outcomes.length == 0
            ? 0
            : _selectOutcome(outcomes, randomBytes);
        return _calculateOutcome(class1, class2, randomBytes, outcomeClassId, successChance);
    }

    // Core | Helper to get Fusion Outcome to reduce Stack Depth at entropyCallback
    function _getFusionOutcome(uint256 class1, uint256 class2, bytes32 randomBytes) internal view returns (bool success, uint256 targetClass) {
        binderStructs.FusionRecipe memory recipe = book0fLife.getFusionRecipe(class1, class2);
        return _resolveOutcome(class1, class2, randomBytes, recipe.outcomes, recipe.successChance);
    }

    // Core | Helper to generate all necessary metadata for minting the new token at entropyCallback
    function _getNFTDetailsAndStats(uint256 targetClass, bytes32 entropyBytes) internal view returns (
        string memory className, uint8 rarityId, string memory rarityName, binderStructs.StaticStats memory stats, binderStructs.DynamicStats memory dynamicStats){
            bytes32 statSeed = keccak256(abi.encodePacked(entropyBytes, "STATS"));
            binderStructs.ClassConfig memory config;
            (className, rarityId, rarityName, config) = _getTargetMetadata(targetClass);
            stats = _allocateStats(config, statSeed);
            dynamicStats = _buildDynStats(stats, config);
        }

    function _mintFusionResult(address user, uint256 targetClass, bytes32 entropyBytes) internal returns (uint256) {
        (
            string memory className,
            uint8 rarityId,
            string memory rarityName,
            binderStructs.StaticStats memory stats,
            binderStructs.DynamicStats memory dynamicStats
        ) = _getNFTDetailsAndStats(targetClass, entropyBytes);
        return binderData._mint4Fusion(user, targetClass, className, rarityId, rarityName, stats, dynamicStats);
    }

    // Helper Functions to generate allocation order and byte order for allocateStats function
    function _generateAllocationOrder(bytes32 seed) private pure returns (uint8[8] memory order) {
        order = [0, 1, 2, 3, 4, 5, 6, 7];
        for (uint8 i = 7; i > 0; i--) {
            uint8 j = uint8(seed[i]) % (i + 1);
            (order[i], order[j]) = (order[j], order[i]);
        }
    }

    function _generateBytesOrder(bytes32 seed) private pure returns (uint8[32] memory order) {
        for (uint8 i = 0; i < 32; i++) {
            order[i] = i;
        }
        for (uint8 i = 31; i > 0; i--) {
            uint8 j = uint8(seed[i]) % (i + 1);
            (order[i], order[j]) = (order[j], order[i]);
        }
    }

    // InternalHelper function for multipleOut-cum probabilities
    function _selectOutcome(binderStructs.FusionOutcome[] memory outcomes, bytes32 seed) internal pure returns (uint256 outcomeClassId) {
        if (outcomes.length == 0) return 0;

        bytes32 outcomeSeed = keccak256(abi.encodePacked(seed, "OUTCUM"));
        uint256 totalWeight = 0;

        // sum total weight
        for (uint8 i = 0; i < outcomes.length; i++) {
            totalWeight += outcomes[i].multiProbChance;
        }
        require(totalWeight > 0, "Invalid Weight");

        uint256 roll = uint256(outcomeSeed) % totalWeight;
        uint256 cum = 0;

        for (uint8 i = 0; i < outcomes.length; i++){
            cum += outcomes[i].multiProbChance;
            if (roll < cum){
                return outcomes[i].outcomeClassId;
            }
        }
        return outcomes[outcomes.length - 1].outcomeClassId; // fallback
    }

    // Internal Helper function to be used at entropyCallback _buildDynStats and _getTargetMetadata
    function _buildDynStats(binderStructs.StaticStats memory stats, binderStructs.ClassConfig memory config
    ) internal pure returns (binderStructs.DynamicStats memory) {
        return binderStructs.DynamicStats({
            maxHP: stats.stats[4] * config.hpPerVit,
            maxMP: stats.stats[5] * config.mpPerWis,
            currentHP: stats.stats[4] * config.hpPerVit,
            currentMP: stats.stats[5] * config.mpPerWis
        });
    }

    function _getTargetMetadata (uint256 classId
    ) internal view returns (string memory className, uint8 rarityId, string memory rarityName, binderStructs.ClassConfig memory config) {
        rarityId = book0fLife.getClassRarityId(classId);
        return (book0fLife.getClassName(classId), rarityId, book0fLife.getRarityName(rarityId), book0fLife.getClassConfig(classId));
    }

    // Entropy Request Information - Requested by User thru riteFusion Function to be used in entropyCallback Function
    function _processEntropyRequest(uint256 fusionId) internal {
        uint256 fee = entropy.getFeeV2(entropyProvider, 0);
        bytes32 userSeed = keccak256(abi.encodePacked(block.timestamp, fusionId));
        uint64 sequence = entropy.requestV2{value: fee}(
            entropyProvider,
            userSeed,
            0
        );

        _entropyToFusionId[sequence] = fusionId;
    }

    // Enforce class order to ensure recipe lookup is consistent with Book0fLife formart
    // Book0fLife assume class1 < class2 for all recipe keys
    // Tobe used in normal fusion with 2 Nft
    function _sortMi(uint256 a, uint256 b) internal pure returns (uint256, uint256) {
        return a < b? (a, b) : (b, a);
    }

/*
    // This will not be used anytime soon please ignore
    // Sorting Hash of Class IDs to prevent duplicate Recipes to be used in riteFusion Function for advance FUSION
    // TODO : Implement this function lateron down the road, now just act as placeholder and reminder
    // bubble sort expected not something big
    function _sortedHash(uint256[] memory input, address[] memory erc20s) internal pure returns (bytes32) {
       uint256 n = input.length;
       for (uint i = 0; i < n; i++){
            for (uint j = i+1; j < n; j++){
                if (input[i] > input [j]) {
                    (input[i], input[j]) = (input[j], input[i]);
                }
            }
       }

        return keccak256(abi.encodePacked(input, erc20s));
    }

    // Another STUB for advance FUSION
    function advanceFuse(uint256[] memory nftIds, ERC20Input[] memory catalysts) external payable nonReentrant whenNotPaused {

        uint256 totalCost = entropy.getFeeV2(entropyProvider, 0) + fusionCost;
        require(msg.value >= totalCost, "Not enough gold my lord");
        require(nftIds.length >= 3, "Invalid number of NFTs");

        // 1. Handling Catalyst Transfer
        address[] memory catalystsAddrs = new address[](catalysts.length);
        for (uint i = 0; i < catalysts.length; i++) {
            IERC20(catalysts[i].token).transferFrom(msg.sender, address(this), catalysts[i].amount);
            catalystsAddrs[i] = catalysts[i].token;
        }

        // 2. Handling NFT Transfer
        uint256[] memory classIds = new uint256[](nftIds.length);
        for (uint i = 0; i < nftIds.length; i++) {
            require(binderData.ownerOf(nftIds[i]) == msg.sender, "Cannot sacrifice what u dont own");
            binderData.safeTransferFrom(msg.sender, address(this), nftIds[i]);
            classIds[i] = binderData.getNFTClass(nftIds[i]);
        }

        // 3. Generating Sorted Reciepe Hash
        bytes32 recipeHash = _sortedHash(classIds, catalystsAddrs);

        // 4. Processing Entropy Request
        uint256 fusionId = ++nextFusionId;
        _fusionRequestAdvanced[fusionId] = AdvancedFusionRequest({
            user: msg.sender,
            nftIds: nftIds,
            recipeHash: recipeHash,
            resolved: false
        });

        _processEntropyRequest(fusionId);

        emit AdvancedFusionRequested(fusionId, msg.sender, nftIds, catalystsAddrs);
    }
 */

    /* Admin Functions */
    // Less Likely to be used, used to update BinderData.sol and Book0fLife.sol
    function setBaseBinder(address newBinder) external onlyRole(DEFAULT_ADMIN_ROLE) {
        binderData = IBinderData(newBinder);
        emit BaseBinderUpdated(newBinder);
    }

    function setFusionLibrary(address newFusionLibrary) external onlyRole(DEFAULT_ADMIN_ROLE) {
        book0fLife = IBook0fLife(newFusionLibrary);
        emit Book0fLifeUpdated(newFusionLibrary);
    }

    function withdraw() external onlyOwner nonReentrant {
        address payable recipient = payable(owner());
        uint256 amount = address(this).balance;
        require(amount > 0, "No funds");

        (bool sent, ) = recipient.call{value: amount}("");
        require(sent, "Withdrawal failed");
        emit NativeFundsWithdrawn(recipient, amount);
    }

    // Pause/Unpause and supportInterface Functions
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function supportsInterface(bytes4 interfaceId) public view override(AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
