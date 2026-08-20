// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-4.8/access/Ownable.sol";
import "@openzeppelin/contracts-4.8/access/AccessControl.sol";
import "@openzeppelin/contracts-4.8/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts-4.8/utils/math/Math.sol";
import "@pythnetwork/entropy-sdk-solidity/IEntropyConsumer.sol";
import "@pythnetwork/entropy-sdk-solidity/IEntropyV2.sol";
import "./supportContract/binderStructs.sol";

interface IBinderData {
    function _mintRandomNFT(address, uint256, string memory, string memory, binderStructs.StaticStats memory, binderStructs.DynamicStats memory) external returns (uint256);
}

interface IBook0fLife {
    function getClassName(uint256 classId) external view returns (string memory);
    function getClassConfig(uint256 classId) external view returns (binderStructs.ClassConfig memory);
    function getClassesByRarity(string memory rarity) external view returns (uint256[] memory);
}

contract BinderLogic is Ownable, AccessControl, ReentrancyGuard, IEntropyConsumer {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    IEntropyV2 public entropy;          // Update to V2
    address public provider;
    IBinderData public binderData;
    IBook0fLife public book0fLife;

    uint256 public mintPrice = 0.0125 ether;
    bytes32 public previousRandomNumber;                // Logging previous user Random number
    mapping(uint64 => address) private entropyRequests; // sequenceNumber => minter address

    // Rarity thresholds (basis points out of 10000)
    uint256 public constant MAX_CHANCE_VALUE = 10000; // 100% with 2 decimal places
    uint256 public commonChance = 7500;
    uint256 public uncommonChance = 1500;
    uint256 public rareChance = 1000;
    uint256 public epicChance = 0;
    uint256 public legendChance = 0;

    event RandomRequest(address indexed user, uint64 indexed sequenceNumber);
    event RandomMintCompleted(address indexed user, uint64 indexed sequenceNumber);
    event NativeFundsWithdrawn(address indexed recipient, uint256 amount);

    constructor(
        address _entropy,
        address _provider,
        address _binderData,
        address _book0fLife,
        address initialOwner
    ) {
        entropy = IEntropyV2(_entropy);     // Update to V2
        provider = _provider;
        binderData = IBinderData(_binderData);
        book0fLife = IBook0fLife(_book0fLife);

        transferOwnership(initialOwner);
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
    }

    /// Request randomness from entropy
    function requestMint(bytes32 userSeed) external payable nonReentrant {
        uint256 fee = entropy.getFeeV2(provider, 0);     // Update to V2 change getFee(provider) ==> getFeeV2(Provider,gasFee)
        uint256 requiredPayment = fee + mintPrice;
        require(msg.value >= requiredPayment, "Not enough gold MyLord");

        uint64 sequenceNumber = entropy.requestV2{value: fee}(    // Update to V2 change requestWithCallback(provider, userSeed) ==> requestv22(Provider, userSeed, gasFee)
            provider, userSeed, 0);
        entropyRequests[sequenceNumber] = msg.sender;

        emit RandomRequest(msg.sender, sequenceNumber);
    }

    /// Entropy callback
    function entropyCallback(
        uint64 sequenceNumber,
        address providerAddress,
        bytes32 randomNumber
    ) internal override {
        require(providerAddress == provider, "Invalid entropy provider");
        address recipient = entropyRequests[sequenceNumber];
        require(recipient != address(0), "Invalid entropy request");

        _generateAndMint(recipient, sequenceNumber, randomNumber);

        previousRandomNumber = randomNumber; // Logging random Number to be used partially for next User
        delete entropyRequests[sequenceNumber];
    }

    /// Core logic
    function _generateAndMint(address recipient, uint64 sequenceNumber, bytes32 seed) internal {
        (string memory rarity, uint256 classId, binderStructs.StaticStats memory stats, binderStructs.DynamicStats memory dynamicStats) = _generateProperties(seed);

        binderData._mintRandomNFT(
            recipient,
            classId,
            book0fLife.getClassName(classId),
            rarity,
            stats,
            dynamicStats
        );

        emit RandomMintCompleted(recipient, sequenceNumber);
    }

    /// Generate full NFT properties from seed
    function _generateProperties(bytes32 seed) internal view returns (
        string memory rarity,
        uint256 classId,
        binderStructs.StaticStats memory stats,
        binderStructs.DynamicStats memory dynamicStats
        ) {
        // Split the seed into two parts
        bytes16 prevHead = bytes16(previousRandomNumber);                       // First 16 bytes of previous user randomNumber
        bytes16 currTail = bytes16(uint128(uint256(seed)));                       // Last 16 bytes of current user randomNumber
        bytes16 classSeed = bytes16(seed);                      // First 16 bytes of current randomNumber for class / rarity randomizer
        bytes32 statSeed = bytes32(bytes.concat(prevHead,currTail));            // Full 32-bytes stat side

        rarity = _determineRarity(uint128(classSeed));
        uint256[] memory candidates = book0fLife.getClassesByRarity(rarity);    // fetch possible classes for rarity at book0fLife
        require(candidates.length > 0, "No available class for rarity");

        classId = candidates[uint128(classSeed) % candidates.length];           // rand for getting class

        binderStructs.ClassConfig memory config = book0fLife.getClassConfig(classId);
        stats = _allocateStats(config, statSeed);

        dynamicStats = binderStructs.DynamicStats({
            maxHP: uint16(stats.stats[4]) * config.hpPerVit,
            maxMP: uint16(stats.stats[5]) * config.mpPerWis,
            currentHP: uint16(stats.stats[4]) * config.hpPerVit,
            currentMP: uint16(stats.stats[5]) * config.mpPerWis
        });

        return (rarity, classId, stats, dynamicStats);
    }

    /// Rarity Determination
    function _determineRarity(uint256 randomness) internal view returns (string memory) {
        uint256 roll = randomness % MAX_CHANCE_VALUE;
        uint256 threshold = commonChance;

        if (roll < threshold) return "Common";
        threshold += uncommonChance;
        if (roll < threshold) return "Uncommon";
        threshold += rareChance;
        if (roll < threshold) return "Rare";
        threshold += epicChance;
        if (roll < threshold) return "Epic";
        return "Legend";
    }

    /// Allocate Stats from ClassConfig
    function _allocateStats(binderStructs.ClassConfig memory config, bytes32 seed) internal pure returns (binderStructs.StaticStats memory stats) {
        stats = binderStructs.StaticStats({
            stats: [
                config.minStats[0],         // Storage Slot for STR
                config.minStats[1],         // Storage Slot for INT
                config.minStats[2],         // Storage Slot for AGI
                config.minStats[3],         // Storage Slot for DEX
                config.minStats[4],         // Storage Slot for VIT
                config.minStats[5],         // Storage Slot for WIS
                config.minStats[6],         // Storage Slot for SPD
                config.minStats[7]          // Storage Slot for STA
            ]
        });

        uint256 remainingPoints = config.totalPoints;

        bytes memory entropyBytes = abi.encodePacked(seed);
        uint8[8] memory statOrder = _generateAllocationOrder(seed); // shuffle 8 stats
        uint8[32] memory byteOrder = _generateBytesOrder(seed); // shuffle bytes order

        uint8 usedBytes = 0;

        // First pass allocation
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
       
       // Second pass for remaining points, fallback balancing (+1 per Cycle Pity)
       while (remainingPoints > 0) {
           for (uint i = 0; i < 8 && remainingPoints > 0; i++) {
               uint8 statIndex = statOrder[i];
               uint8 current = stats.stats[statIndex];
               uint8 maxAdd = config.maxStats[statIndex] - current;
               
               if (maxAdd == 0) continue;

               uint8 alloc = 1;
               stats.stats[statIndex] = current + alloc;
               remainingPoints -= alloc;
           }
       }
 
        return stats;
    }

    //.. Helper function to generate allocation order [Used on _allocateStats]
    function _generateAllocationOrder(bytes32 seed) private pure returns (uint8[8] memory order) {
        order = [0,1,2,3,4,5,6,7]; // STR,INT,AGI,DEX,VIT,WIS,SPD,STA
        // Fisher-Yates shuffle
        for (uint8 i = 7; i > 0; i--) {
            uint8 selector = uint8(seed[i]);
            uint8 j = selector % (i + 1);
            (order[i], order[j]) = (order[j], order[i]);
        }
    }

    //.. Helper function to generate Bytes order [Used on _allocateStats]
    function _generateBytesOrder(bytes32 seed) private pure returns (uint8[32] memory order) {
        // Array itternation with 0 to 31
        for (uint8 i = 0; i < 32; i++) {
            order[i] = i;
        }

        // Fisher-Yates shuffle using 32 bytes of Seed
        for (uint8 i = 31; i > 0; i--) {
            uint8 j = uint8(seed[i]) % (i + 1);
            (order[i], order[j]) = (order[j], order[i]);
        }
    }

    /// Admin function to update rarity chances
    function setRarityChances(
        uint256 _common,
        uint256 _uncommon,
        uint256 _rare,
        uint256 _epic,
        uint256 _legend
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_common + _uncommon + _rare + _epic + _legend == 10000, "Chances must sum to 10000");

        commonChance = _common;
        uncommonChance = _uncommon;
        rareChance = _rare;
        epicChance = _epic;
        legendChance = _legend;
    }

    /// Admin function to update mint price
    function setMintPrice(uint256 _mintPrice) external onlyRole(DEFAULT_ADMIN_ROLE) {
        mintPrice = _mintPrice;
    }

    /// Withdraw accumulated mint revenue and any directly received native funds.
    function withdraw() external onlyOwner nonReentrant {
        address payable recipient = payable(owner());
        uint256 amount = address(this).balance;
        require(amount > 0, "No funds");

        (bool sent, ) = recipient.call{value: amount}("");
        require(sent, "Withdrawal failed");
        emit NativeFundsWithdrawn(recipient, amount);
    }

    /// Entropy Override
    function getEntropy() internal view override returns (address) {
        return address(entropy);
    }
}
