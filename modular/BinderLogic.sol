// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-4.8/access/Ownable.sol";
import "@openzeppelin/contracts-4.8/access/AccessControl.sol";
import "@openzeppelin/contracts-4.8/security/ReentrancyGuard.sol";
import "@pythnetwork/entropy-sdk-solidity/IEntropyConsumer.sol";
import "@pythnetwork/entropy-sdk-solidity/IEntropyV2.sol";
import "./supportContract/binderStructs.sol";
import "./interfaces/IBinderData.sol";
import "./interfaces/IBook0fLife.sol";
import "./interfaces/IAllegianceRegistry.sol";

/// @notice Entropy-backed normal mint orchestration.
/// @dev Nation state is only a per-request snapshot. AllegianceRegistry remains authoritative.
contract BinderLogic is Ownable, AccessControl, ReentrancyGuard, IEntropyConsumer {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant CONFIG_ROLE = keccak256("CONFIG_ROLE");
    uint16 public constant MAX_CHANCE_VALUE = 10_000;

    struct MintRequest {
        address recipient;
        uint8 nationId;
    }

    IEntropyV2 public entropy;
    address public provider;
    IBinderData public binderData;
    IBook0fLife public book0fLife;
    IAllegianceRegistry public allegianceRegistry;

    uint256 public mintPrice = 0.0125 ether;
    bytes32 public previousRandomNumber;
    mapping(uint64 => MintRequest) private _mintRequests;

    uint8[] private _activeRarityIds;
    mapping(uint8 => uint16) private _rarityChanceBps;

    event RandomRequest(address indexed user, uint64 indexed sequenceNumber, uint8 nationId);
    event RandomMintCompleted(address indexed user, uint64 indexed sequenceNumber, uint8 rarityId, uint256 classId);
    event RarityDistributionChanged(uint8[] rarityIds, uint16[] chancesBps);
    event AllegianceRegistryUpdated(address indexed registry);
    event Book0fLifeUpdated(address indexed book);
    event NativeFundsWithdrawn(address indexed recipient, uint256 amount);

    error InvalidMintRequest(uint64 sequenceNumber);
    error InvalidRarityDistribution();
    error NoEligibleClass(uint8 rarityId, uint8 nationId);

    constructor(
        address entropyAddress,
        address providerAddress,
        address binderDataAddress,
        address book0fLifeAddress,
        address allegianceRegistryAddress,
        address initialOwner
    ) {
        require(
            entropyAddress != address(0) && providerAddress != address(0) && binderDataAddress != address(0)
                && book0fLifeAddress != address(0) && allegianceRegistryAddress != address(0) && initialOwner != address(0),
            "Invalid address"
        );
        entropy = IEntropyV2(entropyAddress);
        provider = providerAddress;
        binderData = IBinderData(binderDataAddress);
        book0fLife = IBook0fLife(book0fLifeAddress);
        allegianceRegistry = IAllegianceRegistry(allegianceRegistryAddress);
        transferOwnership(initialOwner);
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
        _grantRole(CONFIG_ROLE, initialOwner);

        // Default migration distribution: Common 75%, Uncommon 15%, Rare 10%.
        _activeRarityIds.push(1);
        _activeRarityIds.push(2);
        _activeRarityIds.push(3);
        _rarityChanceBps[1] = 7_500;
        _rarityChanceBps[2] = 1_500;
        _rarityChanceBps[3] = 1_000;
    }

    function requestMint(bytes32 userSeed) external payable nonReentrant {
        uint256 fee = entropy.getFeeV2(provider, 0);
        require(msg.value >= fee + mintPrice, "Not enough gold MyLord");

        // Snapshot before the external Entropy request. The callback must never
        // consult live allegiance, including if a provider implementation evolves.
        uint8 nationId = allegianceRegistry.getPlayerNation(msg.sender);
        uint64 sequenceNumber = entropy.requestV2{value: fee}(provider, userSeed, 0);
        _mintRequests[sequenceNumber] = MintRequest({recipient: msg.sender, nationId: nationId});
        emit RandomRequest(msg.sender, sequenceNumber, nationId);
    }

    function entropyCallback(uint64 sequenceNumber, address providerAddress, bytes32 randomNumber) internal override {
        require(providerAddress == provider, "Invalid entropy provider");
        MintRequest memory request = _mintRequests[sequenceNumber];
        if (request.recipient == address(0)) revert InvalidMintRequest(sequenceNumber);

        (
            uint8 rarityId,
            uint256 classId,
            binderStructs.StaticStats memory stats,
            binderStructs.DynamicStats memory dynamicStats
        ) = _generateProperties(randomNumber, request.nationId);

        binderData._mintRandomNFT(
            request.recipient,
            classId,
            book0fLife.getClassName(classId),
            rarityId,
            book0fLife.getRarityName(rarityId),
            stats,
            dynamicStats
        );

        previousRandomNumber = randomNumber;
        delete _mintRequests[sequenceNumber];
        emit RandomMintCompleted(request.recipient, sequenceNumber, rarityId, classId);
    }

    function setRarityDistribution(uint8[] calldata rarityIds, uint16[] calldata chancesBps)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (rarityIds.length == 0 || rarityIds.length != chancesBps.length) revert InvalidRarityDistribution();

        uint256 totalChance;
        uint8 previousId;
        for (uint256 i = 0; i < rarityIds.length; ++i) {
            uint8 rarityId = rarityIds[i];
            if (
                rarityId == 0 || (i != 0 && rarityId <= previousId) || chancesBps[i] == 0
                    || !book0fLife.isRarityRegistered(rarityId)
            ) revert InvalidRarityDistribution();
            totalChance += chancesBps[i];
            previousId = rarityId;
        }
        if (totalChance != MAX_CHANCE_VALUE) revert InvalidRarityDistribution();

        for (uint256 i = 0; i < _activeRarityIds.length; ++i) {
            delete _rarityChanceBps[_activeRarityIds[i]];
        }
        delete _activeRarityIds;
        for (uint256 i = 0; i < rarityIds.length; ++i) {
            _activeRarityIds.push(rarityIds[i]);
            _rarityChanceBps[rarityIds[i]] = chancesBps[i];
        }
        emit RarityDistributionChanged(rarityIds, chancesBps);
    }

    function setAllegianceRegistry(address registry) external onlyRole(CONFIG_ROLE) {
        require(registry != address(0), "Invalid registry");
        allegianceRegistry = IAllegianceRegistry(registry);
        emit AllegianceRegistryUpdated(registry);
    }

    function setBook0fLife(address book) external onlyRole(CONFIG_ROLE) {
        require(book != address(0) && book.code.length != 0, "Invalid book");
        book0fLife = IBook0fLife(book);
        emit Book0fLifeUpdated(book);
    }

    function setMintPrice(uint256 newMintPrice) external onlyRole(DEFAULT_ADMIN_ROLE) {
        mintPrice = newMintPrice;
    }

    function getMintRequest(uint64 sequenceNumber) external view returns (address recipient, uint8 nationId) {
        MintRequest memory request = _mintRequests[sequenceNumber];
        return (request.recipient, request.nationId);
    }

    function getActiveRarityDistribution()
        external
        view
        returns (uint8[] memory rarityIds, uint16[] memory chancesBps)
    {
        rarityIds = _activeRarityIds;
        chancesBps = new uint16[](rarityIds.length);
        for (uint256 i = 0; i < rarityIds.length; ++i) {
            chancesBps[i] = _rarityChanceBps[rarityIds[i]];
        }
    }

    function getRarityChanceBps(uint8 rarityId) external view returns (uint16) {
        return _rarityChanceBps[rarityId];
    }

    function withdraw() external onlyOwner nonReentrant {
        address payable recipient = payable(owner());
        uint256 amount = address(this).balance;
        require(amount > 0, "No funds");
        (bool sent,) = recipient.call{value: amount}("");
        require(sent, "Withdrawal failed");
        emit NativeFundsWithdrawn(recipient, amount);
    }

    function getEntropy() internal view override returns (address) {
        return address(entropy);
    }

    function _generateProperties(bytes32 entropySeed, uint8 nationId)
        internal
        view
        returns (
            uint8 rarityId,
            uint256 classId,
            binderStructs.StaticStats memory stats,
            binderStructs.DynamicStats memory dynamicStats
        )
    {
        rarityId = _determineRarity(uint256(keccak256(abi.encodePacked("BINDERS_RARITY", entropySeed))));
        classId =
            _selectEligibleClass(rarityId, nationId, uint256(keccak256(abi.encodePacked("BINDERS_CLASS", entropySeed))));

        binderStructs.ClassConfig memory config = book0fLife.getClassConfig(classId);
        bytes32 statSeed = keccak256(abi.encodePacked("BINDERS_STATS", previousRandomNumber, entropySeed));
        stats = _allocateStats(config, statSeed);
        dynamicStats = binderStructs.DynamicStats({
            maxHP: uint16(stats.stats[4]) * config.hpPerVit,
            maxMP: uint16(stats.stats[5]) * config.mpPerWis,
            currentHP: uint16(stats.stats[4]) * config.hpPerVit,
            currentMP: uint16(stats.stats[5]) * config.mpPerWis
        });
    }

    function _determineRarity(uint256 randomness) internal view returns (uint8) {
        uint256 roll = randomness % MAX_CHANCE_VALUE;
        uint256 cumulative;
        for (uint256 i = 0; i < _activeRarityIds.length; ++i) {
            uint8 rarityId = _activeRarityIds[i];
            cumulative += _rarityChanceBps[rarityId];
            if (roll < cumulative) return rarityId;
        }
        revert InvalidRarityDistribution();
    }

    function _selectEligibleClass(uint8 rarityId, uint8 nationId, uint256 randomness) internal view returns (uint256) {
        uint256[] memory generalClasses = book0fLife.getClassesByNationRarity(0, rarityId);
        uint256 eligibleCount = _countEligibleClasses(generalClasses, nationId);
        uint256[] memory nationClasses;
        if (nationId != 0) {
            nationClasses = book0fLife.getClassesByNationRarity(nationId, rarityId);
            eligibleCount += _countEligibleClasses(nationClasses, nationId);
        }
        if (eligibleCount == 0) revert NoEligibleClass(rarityId, nationId);

        uint256 selectedIndex = randomness % eligibleCount;
        uint256 generalEligibleCount = _countEligibleClasses(generalClasses, nationId);
        if (selectedIndex < generalEligibleCount) {
            return _getEligibleClassAt(generalClasses, nationId, selectedIndex);
        }
        return _getEligibleClassAt(nationClasses, nationId, selectedIndex - generalEligibleCount);
    }

    function _countEligibleClasses(uint256[] memory candidates, uint8 nationId) internal view returns (uint256 count) {
        for (uint256 i = 0; i < candidates.length; ++i) {
            if (book0fLife.isClassMintEligible(candidates[i], nationId)) ++count;
        }
    }

    function _getEligibleClassAt(uint256[] memory candidates, uint8 nationId, uint256 selectedIndex)
        internal
        view
        returns (uint256)
    {
        for (uint256 i = 0; i < candidates.length; ++i) {
            if (!book0fLife.isClassMintEligible(candidates[i], nationId)) continue;
            if (selectedIndex == 0) return candidates[i];
            --selectedIndex;
        }
        revert("Eligible class index out of range");
    }

    function _allocateStats(binderStructs.ClassConfig memory config, bytes32 seed)
        internal
        pure
        returns (binderStructs.StaticStats memory stats)
    {
        stats = binderStructs.StaticStats({stats: config.minStats});
        uint16 remainingPoints = config.totalPoints;
        bytes memory entropyBytes = abi.encodePacked(seed);
        uint8[8] memory statOrder = _generateAllocationOrder(seed);
        uint8[32] memory byteOrder = _generateBytesOrder(seed);
        uint8 usedBytes;

        while (remainingPoints > 0 && usedBytes < 32) {
            for (uint8 i = 0; i < 8 && remainingPoints > 0; ++i) {
                if (usedBytes >= 32) break;
                uint8 statIndex = statOrder[i];
                uint8 current = stats.stats[statIndex];
                uint8 maxAdd = config.maxStats[statIndex] - current;
                uint8 randByte = uint8(entropyBytes[byteOrder[usedBytes++]]);
                if (maxAdd == 0) continue;
                uint16 allocation = randByte % (uint16(maxAdd) + 1);
                if (allocation > remainingPoints) allocation = remainingPoints;
                stats.stats[statIndex] = current + uint8(allocation);
                remainingPoints -= allocation;
            }
        }

        while (remainingPoints > 0) {
            for (uint8 i = 0; i < 8 && remainingPoints > 0; ++i) {
                uint8 statIndex = statOrder[i];
                if (stats.stats[statIndex] >= config.maxStats[statIndex]) continue;
                ++stats.stats[statIndex];
                --remainingPoints;
            }
        }
    }

    function _generateAllocationOrder(bytes32 seed) private pure returns (uint8[8] memory order) {
        order = [0, 1, 2, 3, 4, 5, 6, 7];
        for (uint8 i = 7; i > 0; --i) {
            uint8 j = uint8(seed[i]) % (i + 1);
            (order[i], order[j]) = (order[j], order[i]);
        }
    }

    function _generateBytesOrder(bytes32 seed) private pure returns (uint8[32] memory order) {
        for (uint8 i = 0; i < 32; ++i) {
            order[i] = i;
        }
        for (uint8 i = 31; i > 0; --i) {
            uint8 j = uint8(seed[i]) % (i + 1);
            (order[i], order[j]) = (order[j], order[i]);
        }
    }
}
