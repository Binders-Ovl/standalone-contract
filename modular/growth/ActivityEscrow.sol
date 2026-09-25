// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-4.8/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts-4.8/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-4.8/token/ERC721/IERC721Receiver.sol";
import "@pythnetwork/entropy-sdk-solidity/IEntropyConsumer.sol";
import "@pythnetwork/entropy-sdk-solidity/IEntropyV2.sol";
import "../interfaces/ICentralConsole.sol";
import "../interfaces/IBinderSkills.sol";
import "../interfaces/IBook0fArts.sol";
import "../interfaces/IGrowthActivity.sol";
import "../interfaces/IBook0fGrowth.sol";
import "../interfaces/IBinderGrowth.sol";
import "../supportContract/binderIds.sol";
import "./GrowthRollLib.sol";

/// @notice Shared custody/payment/entropy mechanics; Training and Quest retain separate deployed state.
abstract contract ActivityEscrow is ReentrancyGuard, IERC721Receiver, IEntropyConsumer, IGrowthActivity {
    using SafeERC20 for IERC20;

    struct Dependencies {
        address console;
        address data;
        address book;
        address growth;
        address skills;
        address arts;
        address entropy;
        address provider;
        address treasury;
    }

    struct Activity {
        uint256 binderId;
        address beneficiary;
        uint8 kind;
        uint8 phase;
        uint8 selectedStat;
        bool success;
        bool dead;
        uint32 ruleId;
        uint16 ruleVersion;
        uint48 startedAt;
        uint48 maturesAt;
        uint48 requestedAt;
        uint32 rescueDelay;
        bool refundOnRescue;
        address goldAsset;
        uint128 price;
        uint64 sequence;
        bytes32 seed;
    }

    struct Candidate {
        uint32 artId;
        uint16 version;
    }

    ICentralConsole public immutable centralConsole;
    IBinderData public immutable binderData;
    IBook0fGrowth public immutable book;
    IBinderGrowth public immutable growth;
    IBinderSkills public immutable skills;
    IBook0fArts public immutable arts;
    IEntropyV2 public immutable entropy;
    address public immutable entropyProvider;
    address public immutable treasury;
    uint8 public immutable activityKind;
    uint256 public pendingActivityCount;
    mapping(uint256 => uint256) public binderNonce;
    mapping(bytes32 => Activity) internal _activities;
    mapping(uint64 => bytes32) private _requestActivity;
    mapping(bytes32 => int32[8]) internal _results;
    mapping(bytes32 => Candidate[]) private _artCandidates;
    mapping(bytes32 => Candidate[]) private _patternCandidates;
    mapping(bytes32 => Candidate) private _selectedArt;
    mapping(bytes32 => Candidate) private _selectedPattern;
    mapping(address => mapping(address => uint256)) public credits;

    error InvalidActivity();
    error InvalidPayment();
    error ActivityNotMature();
    error RetiredController();
    error RescueNotReady();

    event ActivityStarted(
        bytes32 indexed activityId,
        uint256 indexed binderId,
        address indexed beneficiary,
        uint8 kind,
        uint32 ruleId,
        uint16 version,
        uint48 maturity,
        address asset,
        uint128 price
    );
    event ResolutionRequested(bytes32 indexed activityId, uint64 indexed sequence);
    event SeedReceived(bytes32 indexed activityId, bytes32 seed);
    event ActivitySettled(bytes32 indexed activityId, bool success, bool dead);
    event BinderClaimed(bytes32 indexed activityId);
    event ActivityRescued(bytes32 indexed activityId, bool refunded);
    event ArtRewardSelected(bytes32 indexed activityId, uint32 indexed artId, bool pattern, bool granted);
    event CreditWithdrawn(address indexed asset, address indexed beneficiary, uint256 amount);

    constructor(Dependencies memory deps, uint8 kind) {
        if (
            deps.console.code.length == 0 || deps.data.code.length == 0 || deps.book.code.length == 0
                || deps.growth.code.length == 0 || deps.skills.code.length == 0 || deps.arts.code.length == 0
                || deps.entropy.code.length == 0 || deps.provider == address(0) || deps.treasury == address(0)
        ) {
            revert InvalidActivity();
        }
        centralConsole = ICentralConsole(deps.console);
        binderData = IBinderData(deps.data);
        book = IBook0fGrowth(deps.book);
        growth = IBinderGrowth(deps.growth);
        skills = IBinderSkills(deps.skills);
        arts = IBook0fArts(deps.arts);
        entropy = IEntropyV2(deps.entropy);
        entropyProvider = deps.provider;
        treasury = deps.treasury;
        activityKind = kind;
    }

    function getActivity(bytes32 activityId) external view returns (Activity memory) {
        return _activities[activityId];
    }

    function activityProof(bytes32 activityId)
        external
        view
        returns (uint256 binderId, address beneficiary, uint8 kind, uint8 phase)
    {
        Activity storage record = _activities[activityId];
        return (record.binderId, record.beneficiary, record.kind, record.phase);
    }

    function growthResult(bytes32 activityId) external view returns (int32[8] memory) {
        return _results[activityId];
    }

    function skillReward(bytes32 activityId, bool pattern) external view returns (address, uint32, uint16) {
        Candidate memory candidate = pattern ? _selectedPattern[activityId] : _selectedArt[activityId];
        return (address(arts), candidate.artId, candidate.version);
    }

    function withdrawCredit(address asset) external nonReentrant {
        uint256 amount = credits[asset][msg.sender];
        if (amount == 0) revert InvalidPayment();
        delete credits[asset][msg.sender];
        if (asset == address(0)) {
            (bool ok,) = payable(msg.sender).call{value: amount}("");
            if (!ok) revert InvalidPayment();
        } else {
            IERC20(asset).safeTransfer(msg.sender, amount);
        }
        emit CreditWithdrawn(asset, msg.sender, amount);
    }

    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata)
        external
        view
        returns (bytes4)
    {
        bytes32 id = binderData.activeGrowthActivity(tokenId);
        Activity storage record = _activities[id];
        if (
            msg.sender != address(binderData) || operator != address(this) || record.binderId != tokenId
                || record.beneficiary != from || record.phase != 1
        ) revert InvalidActivity();
        return IERC721Receiver.onERC721Received.selector;
    }

    function _begin(uint256 binderId, uint8 kind, uint32 ruleId, binderStructs.GrowthTerms memory terms)
        internal
        returns (bytes32 id)
    {
        _requireCurrent();
        if (!centralConsole.isGrowthWired() || !terms.enabled || binderData.ownerOf(binderId) != msg.sender) {
            revert InvalidActivity();
        }
        binderStructs.UnitStateView memory state = binderData.getUnitState(binderId);
        if (
            !state.idle || !state.readyToArm || skills.pendingTomeCount(binderId) != 0
                || binderData.getNFTDetails(binderId).dynamicStats.currentHP == 0
                || msg.sender == binderData.binderGraveyard()
        ) revert InvalidActivity();
        id = keccak256(abi.encode(address(this), binderId, ++binderNonce[binderId]));
        Activity storage record = _activities[id];
        record.binderId = binderId;
        record.beneficiary = msg.sender;
        record.kind = kind;
        record.phase = 1;
        record.ruleId = ruleId;
        record.ruleVersion = terms.version;
        record.startedAt = uint48(block.timestamp);
        record.maturesAt = uint48(block.timestamp) + terms.duration;
        record.rescueDelay = terms.entropyRescueDelay;
        record.refundOnRescue = terms.refundOnRescue;
        record.goldAsset = centralConsole.goldAsset();
        record.price = terms.price;
        ++pendingActivityCount;
    }

    function _escrowAndPay(bytes32 id) internal {
        Activity storage record = _activities[id];
        binderData.escrowGrowthActivity(record.binderId, record.beneficiary, activityKind, id, record.maturesAt);
        _receivePayment(record.goldAsset, record.price);
        emit ActivityStarted(
            id,
            record.binderId,
            record.beneficiary,
            record.kind,
            record.ruleId,
            record.ruleVersion,
            record.maturesAt,
            record.goldAsset,
            record.price
        );
    }

    function _receivePayment(address asset, uint256 amount) internal {
        if (asset == address(0)) {
            if (msg.value != amount) revert InvalidPayment();
        } else {
            if (msg.value != 0) revert InvalidPayment();
            if (amount != 0) {
                uint256 beforeBalance = IERC20(asset).balanceOf(address(this));
                IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
                if (IERC20(asset).balanceOf(address(this)) != beforeBalance + amount) revert InvalidPayment();
            }
        }
    }

    function _request(bytes32 id) internal {
        _requireCurrent();
        Activity storage record = _activities[id];
        if (record.phase != 1) revert InvalidActivity();
        if (block.timestamp < record.maturesAt) revert ActivityNotMature();
        uint256 fee = entropy.getFeeV2(entropyProvider, 0);
        if (msg.value != fee) revert InvalidPayment();
        record.phase = 2;
        record.requestedAt = uint48(block.timestamp);
        uint64 sequence = entropy.requestV2{value: fee}(entropyProvider, id, 0);
        if (_requestActivity[sequence] != bytes32(0)) revert InvalidActivity();
        record.sequence = sequence;
        _requestActivity[sequence] = id;
        emit ResolutionRequested(id, sequence);
    }

    function entropyCallback(uint64 sequence, address provider, bytes32 randomNumber) internal override {
        bytes32 id = _requestActivity[sequence];
        Activity storage record = _activities[id];
        if (provider != entropyProvider || record.phase != 2 || record.sequence != sequence) revert InvalidActivity();
        record.seed = randomNumber;
        record.phase = 3;
        emit SeedReceived(id, randomNumber);
    }

    function getEntropy() internal view override returns (address) {
        return address(entropy);
    }

    function _markSettled(bytes32 id) internal returns (Activity storage record) {
        record = _activities[id];
        if (record.phase != 3) revert InvalidActivity();
        record.phase = 4;
        credits[record.goldAsset][treasury] += record.price;
    }

    function _claim(bytes32 id) internal {
        Activity storage record = _activities[id];
        if (record.phase != 4 || record.dead || msg.sender != record.beneficiary) revert InvalidActivity();
        record.phase = 5;
        --pendingActivityCount;
        binderData.releaseGrowthActivity(record.binderId, id);
        emit BinderClaimed(id);
    }

    function _rescue(bytes32 id) internal {
        Activity storage record = _activities[id];
        if ((record.phase != 1 && record.phase != 2) || msg.sender != record.beneficiary) revert InvalidActivity();
        // An active controller must first request a response. A retired controller
        // cannot request new entropy, so its unrequested records may time out too.
        if (record.phase == 1 && binderData.getActivityController(activityKind) == address(this)) {
            revert RescueNotReady();
        }
        uint48 since = record.phase == 1 ? record.maturesAt : record.requestedAt;
        if (block.timestamp < uint256(since) + record.rescueDelay) revert RescueNotReady();
        record.phase = 6;
        --pendingActivityCount;
        credits[record.goldAsset][record.refundOnRescue ? record.beneficiary : treasury] += record.price;
        _onRescue(id);
        binderData.releaseGrowthActivity(record.binderId, id);
        emit ActivityRescued(id, record.refundOnRescue);
    }

    function _onRescue(bytes32) internal virtual {}

    function _requireCurrent() internal view {
        if (binderData.getActivityController(activityKind) != address(this)) revert RetiredController();
    }

    function _snapshotArts(bytes32 id, uint32 artPool, uint32 patternPool) internal {
        if (artPool != 0) _snapshotPool(id, artPool, false);
        if (patternPool != 0) _snapshotPool(id, patternPool, true);
    }

    function _snapshotPool(bytes32 id, uint32 poolId, bool pattern) private {
        uint32[] memory pool = arts.getRewardPool(poolId);
        if (pool.length > 16) revert InvalidActivity();
        Candidate[] storage candidates = pattern ? _patternCandidates[id] : _artCandidates[id];
        for (uint256 i; i < pool.length; ++i) {
            (uint16 version, uint8 artType) = skills.eligibleActivityArt(_activities[id].binderId, pool[i]);
            if (version != 0 && pattern == (artType == 1)) candidates.push(Candidate(pool[i], version));
        }
    }

    function _settleArts(bytes32 id, uint16 artBps, uint16 patternBps) internal {
        _settleArt(id, artBps, false);
        _settleArt(id, patternBps, true);
    }

    function _settleArt(bytes32 id, uint16 bps, bool pattern) private {
        Candidate[] storage candidates = pattern ? _patternCandidates[id] : _artCandidates[id];
        if (candidates.length == 0 || bps == 0) return;
        bytes32 domain;
        if (_activities[id].kind == 3) domain = pattern ? bytes32("ERRANTRY_PATTERN") : bytes32("ERRANTRY_ART");
        else domain = pattern ? bytes32("QUEST_PATTERN") : bytes32("QUEST_ART");
        bytes32 seed = _activities[id].seed;
        if (!GrowthRollLib.chance(GrowthRollLib.expand(seed, id, domain, 0), bps)) return;
        // Select from the original snapshot BEFORE checking the live emergency switch.
        Candidate memory selected = candidates[GrowthRollLib.expand(seed, id, domain, 1) % candidates.length];
        if (pattern) _selectedPattern[id] = selected;
        else _selectedArt[id] = selected;
        bool granted = skills.grantActivityArt(id, pattern);
        emit ArtRewardSelected(id, selected.artId, pattern, granted);
    }
}
