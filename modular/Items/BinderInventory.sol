// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-4.8/security/ReentrancyGuard.sol";
import "./ItemStruct.sol";
import "../interfaces/IBinderData.sol";
import "../interfaces/IBook0fItems.sol";
import "../interfaces/IItemStatsView.sol";
import "../interfaces/IERC6551Registry.sol";
import "../interfaces/IEquipment.sol";
import "../interfaces/ITomeAndGrimoires.sol";
import "../interfaces/ISItems.sol";
import "../interfaces/IBinderInventory.sol";
import "../interfaces/ICentralConsole.sol";
import "../interfaces/IBattleFactory.sol";

/// @notice Bounded recognised-item ledger. Assets live in deterministic Binder TBAs, never in this contract.
contract BinderInventory is ReentrancyGuard, IBinderInventory {
    uint8 public constant MAX_INVENTORY_SLOTS = 20;
    bytes32 public constant TBA_SALT = keccak256("BINDERS_ERC6551_V1");

    address public immutable centralConsole;
    IBinderData public immutable binderData;
    IBook0fItems public immutable book;
    IERC6551Registry public immutable registry;
    address public immutable tbaImplementation;
    IItemStatsView public statsView;
    IEquipment public equipment;
    ITomeAndGrimoires public tomes;
    ISItems public sItems;
    address public binderSkills;
    address public itemUseRouter;

    mapping(uint256 => InventorySlot[20]) private _slots;
    mapping(uint256 => uint8) private _occupiedSlotCount;
    mapping(uint256 => uint256) private _pendingTomeBinder;

    event CollectionsConfigured(address indexed equipment, address indexed tomes, address indexed sItems);
    event StatsViewUpdated(address indexed previousView, address indexed newView);
    event BinderSkillsUpdated(address indexed previousSkills, address indexed newSkills);
    event ItemUseRouterUpdated(address indexed previousRouter, address indexed newRouter);
    event BinderAccountCreated(uint256 indexed binderId, address indexed account);
    event InventoryDeposited(
        uint256 indexed binderId, ItemFamily family, uint16 indexed libraryId, uint256 instanceTokenId, uint128 amount
    );
    event InventoryWithdrawn(
        uint256 indexed binderId, ItemFamily family, uint16 indexed libraryId, uint256 instanceTokenId, uint128 amount
    );
    event EquipmentEquipped(uint256 indexed binderId, uint8 indexed inventorySlot, EquipmentSlot indexed equipmentSlot);
    event EquipmentUnequipped(uint256 indexed binderId, uint8 indexed inventorySlot);

    error UnauthorizedConsole(address caller);
    error UnauthorizedCollection(address caller);
    error UnauthorizedBinderSkills(address caller);
    error UnauthorizedItemUseRouter(address caller);
    error InvalidAddress();
    error InvalidSlot(uint8 slot);
    error InventoryFull(uint256 binderId);
    error InvalidInventoryItem();
    error BinderNotController(uint256 binderId, address caller);
    error BinderBusy(uint256 binderId, uint8 activityId);
    error EquipmentAlreadyEquipped(uint256 binderId, EquipmentSlot equipmentSlot);
    error EquipmentRequirementsNotMet(uint256 binderId);
    error TomeLearningPending(uint256 tomeTokenId);
    error InsufficientItemAmount(uint16 sItemId, uint128 requested);
    error UnauthorizedBattleProxy(address caller);

    constructor(
        address centralConsoleAddress,
        address binderDataAddress,
        address bookAddress,
        address registryAddress,
        address tbaImplementationAddress,
        address statsViewAddress
    ) {
        if (
            centralConsoleAddress == address(0) || binderDataAddress.code.length == 0 || bookAddress.code.length == 0
                || registryAddress.code.length == 0 || tbaImplementationAddress.code.length == 0
                || statsViewAddress.code.length == 0
        ) revert InvalidAddress();
        centralConsole = centralConsoleAddress;
        binderData = IBinderData(binderDataAddress);
        book = IBook0fItems(bookAddress);
        registry = IERC6551Registry(registryAddress);
        tbaImplementation = tbaImplementationAddress;
        statsView = IItemStatsView(statsViewAddress);
    }

    modifier onlyConsole() {
        if (msg.sender != centralConsole) revert UnauthorizedConsole(msg.sender);
        _;
    }

    modifier onlyEquipment() {
        if (msg.sender != address(equipment)) revert UnauthorizedCollection(msg.sender);
        _;
    }

    modifier onlyTomes() {
        if (msg.sender != address(tomes)) revert UnauthorizedCollection(msg.sender);
        _;
    }

    modifier onlySItems() {
        if (msg.sender != address(sItems)) revert UnauthorizedCollection(msg.sender);
        _;
    }

    modifier onlyBinderSkills() {
        if (msg.sender != binderSkills) revert UnauthorizedBinderSkills(msg.sender);
        _;
    }

    modifier onlyItemUseRouter() {
        if (msg.sender != itemUseRouter) revert UnauthorizedItemUseRouter(msg.sender);
        _;
    }

    function setCollections(address equipmentAddress, address tomeAddress, address sItemAddress) external onlyConsole {
        if (
            equipmentAddress.code.length == 0 || tomeAddress.code.length == 0 || sItemAddress.code.length == 0
                || address(equipment) != address(0) || address(tomes) != address(0) || address(sItems) != address(0)
        ) revert InvalidAddress();
        equipment = IEquipment(equipmentAddress);
        tomes = ITomeAndGrimoires(tomeAddress);
        sItems = ISItems(sItemAddress);
        emit CollectionsConfigured(equipmentAddress, tomeAddress, sItemAddress);
    }

    function setStatsView(address newStatsView) external onlyConsole {
        if (newStatsView.code.length == 0) revert InvalidAddress();
        emit StatsViewUpdated(address(statsView), newStatsView);
        statsView = IItemStatsView(newStatsView);
    }

    function setBinderSkills(address newBinderSkills) external onlyConsole {
        if (newBinderSkills.code.length == 0) revert InvalidAddress();
        emit BinderSkillsUpdated(binderSkills, newBinderSkills);
        binderSkills = newBinderSkills;
    }

    function setItemUseRouter(address newItemUseRouter) external onlyConsole {
        if (newItemUseRouter.code.length == 0) revert InvalidAddress();
        emit ItemUseRouterUpdated(itemUseRouter, newItemUseRouter);
        itemUseRouter = newItemUseRouter;
    }

    function accountOf(uint256 binderId) public view returns (address) {
        return registry.account(tbaImplementation, TBA_SALT, block.chainid, address(binderData), binderId);
    }

    function isBinderAccount(address account) external view returns (bool) {
        if (account.code.length == 0) return false;
        (bool ok, bytes memory data) = account.staticcall(abi.encodeWithSignature("token()"));
        if (!ok || data.length != 96) return false;
        (uint256 chainId, address tokenContract, uint256 tokenId) = abi.decode(data, (uint256, address, uint256));
        if (chainId != block.chainid || tokenContract != address(binderData)) return false;
        try binderData.ownerOf(tokenId) returns (address) {}
        catch {
            return false;
        }
        return account == accountOf(tokenId);
    }

    function ensureAccount(uint256 binderId) public returns (address account) {
        binderData.ownerOf(binderId);
        account = accountOf(binderId);
        if (account.code.length == 0) {
            account = registry.createAccount(tbaImplementation, TBA_SALT, block.chainid, address(binderData), binderId);
            emit BinderAccountCreated(binderId, account);
        }
    }

    function prepareEquipmentMint(uint256 binderId, uint16 eqId, uint256 tokenId)
        external
        onlyEquipment
        returns (address account)
    {
        if (!book.isEqEnabled(eqId)) revert InvalidInventoryItem();
        account = ensureAccount(binderId);
        _add721(binderId, ItemFamily.EQUIPMENT, eqId, tokenId);
    }

    function prepareTomeMint(uint256 binderId, uint16 tomeId, uint256 tokenId)
        external
        onlyTomes
        returns (address account)
    {
        if (!book.isTomeEnabled(tomeId)) revert InvalidInventoryItem();
        account = ensureAccount(binderId);
        _add721(binderId, ItemFamily.TOME_OR_GRIMOIRE, tomeId, tokenId);
    }

    function prepareSItemMint(uint256 binderId, uint16 sItemId, uint128 amount)
        external
        onlySItems
        returns (address account)
    {
        if (!book.isSItemEnabled(sItemId) || amount == 0) revert InvalidInventoryItem();
        account = ensureAccount(binderId);
        _addSItem(binderId, sItemId, amount);
    }

    function depositEquipment(uint256 binderId, uint256 tokenId) external nonReentrant {
        _requireBinderControllerIdle(binderId);
        if (equipment.ownerOf(tokenId) != msg.sender) revert BinderNotController(binderId, msg.sender);
        uint16 eqId = equipment.eqIdOf(tokenId);
        if (!book.isEqEnabled(eqId)) revert InvalidInventoryItem();
        address account = ensureAccount(binderId);
        _add721(binderId, ItemFamily.EQUIPMENT, eqId, tokenId);
        equipment.protocolTransfer(msg.sender, account, tokenId);
    }

    function depositTome(uint256 binderId, uint256 tokenId) external nonReentrant {
        _requireBinderControllerIdle(binderId);
        if (tomes.ownerOf(tokenId) != msg.sender) revert BinderNotController(binderId, msg.sender);
        uint16 tomeId = tomes.tomeIdOf(tokenId);
        if (!book.isTomeEnabled(tomeId)) revert InvalidInventoryItem();
        address account = ensureAccount(binderId);
        _add721(binderId, ItemFamily.TOME_OR_GRIMOIRE, tomeId, tokenId);
        tomes.protocolTransfer(msg.sender, account, tokenId);
    }

    function depositSItem(uint256 binderId, uint16 sItemId, uint128 amount) external nonReentrant {
        _requireBinderControllerIdle(binderId);
        if (!book.isSItemEnabled(sItemId) || amount == 0) revert InvalidInventoryItem();
        if (sItems.balanceOf(msg.sender, sItemId) < amount) revert InsufficientItemAmount(sItemId, amount);
        address account = ensureAccount(binderId);
        _addSItem(binderId, sItemId, amount);
        sItems.protocolTransfer(msg.sender, account, sItemId, amount, "");
    }

    function withdrawEquipment(uint256 binderId, uint8 slot) external nonReentrant {
        _requireBinderControllerIdle(binderId);
        InventorySlot memory item = _slotStorage(binderId, slot);
        if (item.family != ItemFamily.EQUIPMENT || item.equipped) revert InvalidInventoryItem();
        _clearSlot(binderId, slot);
        equipment.protocolTransfer(accountOf(binderId), msg.sender, item.instanceTokenId);
        emit InventoryWithdrawn(binderId, item.family, item.libraryId, item.instanceTokenId, 1);
    }

    function withdrawTome(uint256 binderId, uint8 slot) external nonReentrant {
        _requireBinderControllerIdle(binderId);
        InventorySlot memory item = _slotStorage(binderId, slot);
        if (item.family != ItemFamily.TOME_OR_GRIMOIRE || _pendingTomeBinder[item.instanceTokenId] != 0) {
            revert InvalidInventoryItem();
        }
        _clearSlot(binderId, slot);
        tomes.protocolTransfer(accountOf(binderId), msg.sender, item.instanceTokenId);
        emit InventoryWithdrawn(binderId, item.family, item.libraryId, item.instanceTokenId, 1);
    }

    function withdrawSItem(uint256 binderId, uint16 sItemId, uint128 amount) external nonReentrant {
        _requireBinderControllerIdle(binderId);
        if (amount == 0) revert InvalidInventoryItem();
        _removeSItem(binderId, sItemId, amount);
        sItems.protocolTransfer(accountOf(binderId), msg.sender, sItemId, amount, "");
        emit InventoryWithdrawn(binderId, ItemFamily.SITEM, sItemId, 0, amount);
    }

    function equip(uint256 binderId, uint8 slot) external {
        _requireBinderControllerIdle(binderId);
        InventorySlot storage item = _slotStorage(binderId, slot);
        if (item.family != ItemFamily.EQUIPMENT || item.equipped || !book.isEqEnabled(item.libraryId)) {
            revert InvalidInventoryItem();
        }
        EqConfig memory cfg = book.getEq(item.libraryId);
        if (!_classAllowed(binderId, cfg.allowedClassIds) || !_statsMeet(binderId, cfg.statsReq)) {
            revert EquipmentRequirementsNotMet(binderId);
        }
        for (uint8 i; i < MAX_INVENTORY_SLOTS; ++i) {
            InventorySlot storage existing = _slots[binderId][i];
            if (existing.occupied && existing.equipped && existing.equippedAs == cfg.slot) {
                revert EquipmentAlreadyEquipped(binderId, cfg.slot);
            }
        }
        item.equipped = true;
        item.equippedAs = cfg.slot;
        emit EquipmentEquipped(binderId, slot, cfg.slot);
    }

    function unequip(uint256 binderId, uint8 slot) external {
        _requireBinderControllerIdle(binderId);
        InventorySlot storage item = _slotStorage(binderId, slot);
        if (item.family != ItemFamily.EQUIPMENT || !item.equipped) revert InvalidInventoryItem();
        item.equipped = false;
        emit EquipmentUnequipped(binderId, slot);
    }

    function consumeTomeForLearning(uint256 binderId, uint256 tomeTokenId) external onlyBinderSkills nonReentrant {
        uint8 slot = _find721Slot(binderId, ItemFamily.TOME_OR_GRIMOIRE, tomeTokenId);
        if (_pendingTomeBinder[tomeTokenId] != 0 && _pendingTomeBinder[tomeTokenId] != binderId) {
            revert TomeLearningPending(tomeTokenId);
        }
        _clearSlot(binderId, slot);
        delete _pendingTomeBinder[tomeTokenId];
        tomes.burnForProtocol(tomeTokenId);
    }

    function lockTomeForLearning(uint256 binderId, uint256 tomeTokenId) external onlyBinderSkills {
        _find721Slot(binderId, ItemFamily.TOME_OR_GRIMOIRE, tomeTokenId);
        if (_pendingTomeBinder[tomeTokenId] != 0) revert TomeLearningPending(tomeTokenId);
        _pendingTomeBinder[tomeTokenId] = binderId;
    }

    function unlockTomeForLearning(uint256 binderId, uint256 tomeTokenId) external onlyBinderSkills {
        if (_pendingTomeBinder[tomeTokenId] != binderId) revert TomeLearningPending(tomeTokenId);
        delete _pendingTomeBinder[tomeTokenId];
    }

    function isTomeInInventory(uint256 binderId, uint256 tomeTokenId) external view returns (bool) {
        for (uint8 i; i < MAX_INVENTORY_SLOTS; ++i) {
            InventorySlot storage item = _slots[binderId][i];
            if (item.occupied && item.family == ItemFamily.TOME_OR_GRIMOIRE && item.instanceTokenId == tomeTokenId) {
                return true;
            }
        }
        return false;
    }

    function tomeIdInInventory(uint256 binderId, uint256 tomeTokenId) external view returns (uint16) {
        uint8 slot = _find721Slot(binderId, ItemFamily.TOME_OR_GRIMOIRE, tomeTokenId);
        return _slots[binderId][slot].libraryId;
    }

    function consumeSItemForWorld(uint256 binderId, uint16 sItemId, uint128 amount)
        external
        onlyItemUseRouter
        nonReentrant
    {
        if (!book.isSItemEnabled(sItemId) || amount == 0) revert InvalidInventoryItem();
        _removeSItem(binderId, sItemId, amount);
        sItems.burnForProtocol(accountOf(binderId), sItemId, amount);
    }

    function consumeSItemForBattle(uint256 binderId, uint8 slot, uint128 amount)
        external
        nonReentrant
        returns (uint16 sItemId)
    {
        address factory = ICentralConsole(centralConsole).battleFactory();
        if (
            factory == address(0) || !IBattleFactory(factory).isBattleProxy(msg.sender)
                || binderData.activeBattleProxy(binderId) != msg.sender
        ) revert UnauthorizedBattleProxy(msg.sender);
        InventorySlot memory item = _slotStorage(binderId, slot);
        if (item.family != ItemFamily.SITEM || item.equipped || amount == 0) revert InvalidInventoryItem();
        sItemId = item.libraryId;
        _removeSItem(binderId, sItemId, amount);
        sItems.burnForProtocol(accountOf(binderId), sItemId, amount);
    }

    function hasInventory(uint256 binderId) external view returns (bool) {
        return _occupiedSlotCount[binderId] != 0;
    }

    function getSlot(uint256 binderId, uint8 slot) external view returns (InventorySlot memory) {
        return _slotStorage(binderId, slot);
    }

    function getSlots(uint256 binderId) external view returns (InventorySlot[20] memory) {
        return _slots[binderId];
    }

    function equipmentModifiers(uint256 binderId) external view returns (int32[8] memory modifiers) {
        for (uint8 slot; slot < MAX_INVENTORY_SLOTS; ++slot) {
            InventorySlot storage item = _slots[binderId][slot];
            if (!item.occupied || !item.equipped) continue;
            EqConfig memory cfg = book.getEq(item.libraryId);
            for (uint256 i; i < 8; ++i) {
                modifiers[i] += int32(uint32(cfg.statsChgInc[i])) - int32(uint32(cfg.statsChgDec[i]));
            }
        }
    }

    function _add721(uint256 binderId, ItemFamily family, uint16 libraryId, uint256 tokenId) private {
        uint8 slot = _emptySlot(binderId);
        _slots[binderId][slot] = InventorySlot({
            family: family,
            libraryId: libraryId,
            instanceTokenId: tokenId,
            amount: 1,
            occupied: true,
            equipped: false,
            equippedAs: EquipmentSlot.HEADGEAR
        });
        ++_occupiedSlotCount[binderId];
        emit InventoryDeposited(binderId, family, libraryId, tokenId, 1);
    }

    function _addSItem(uint256 binderId, uint16 sItemId, uint128 amount) private {
        uint128 maximumStack = book.getSItem(sItemId).maximumStack;
        uint128 remaining = amount;
        for (uint8 i; i < MAX_INVENTORY_SLOTS && remaining != 0; ++i) {
            InventorySlot storage item = _slots[binderId][i];
            if (
                !item.occupied || item.family != ItemFamily.SITEM || item.libraryId != sItemId
                    || item.amount >= maximumStack
            ) continue;
            uint128 added = maximumStack - item.amount;
            if (added > remaining) added = remaining;
            item.amount += added;
            remaining -= added;
        }
        for (uint8 slot; slot < MAX_INVENTORY_SLOTS && remaining != 0; ++slot) {
            if (_slots[binderId][slot].occupied) continue;
            uint128 stacked = remaining > maximumStack ? maximumStack : remaining;
            _slots[binderId][slot] = InventorySlot({
                family: ItemFamily.SITEM,
                libraryId: sItemId,
                instanceTokenId: 0,
                amount: stacked,
                occupied: true,
                equipped: false,
                equippedAs: EquipmentSlot.HEADGEAR
            });
            ++_occupiedSlotCount[binderId];
            remaining -= stacked;
        }
        if (remaining != 0) revert InventoryFull(binderId);
        emit InventoryDeposited(binderId, ItemFamily.SITEM, sItemId, 0, amount);
    }

    function _removeSItem(uint256 binderId, uint16 sItemId, uint128 amount) private {
        uint128 remaining = amount;
        for (uint8 i; i < MAX_INVENTORY_SLOTS && remaining != 0; ++i) {
            InventorySlot storage item = _slots[binderId][i];
            if (!item.occupied || item.family != ItemFamily.SITEM || item.libraryId != sItemId) continue;
            uint128 removed = item.amount > remaining ? remaining : item.amount;
            item.amount -= removed;
            remaining -= removed;
            if (item.amount == 0) _clearSlot(binderId, i);
        }
        if (remaining != 0) revert InsufficientItemAmount(sItemId, amount);
    }

    function _emptySlot(uint256 binderId) private view returns (uint8) {
        if (_occupiedSlotCount[binderId] == MAX_INVENTORY_SLOTS) revert InventoryFull(binderId);
        for (uint8 i; i < MAX_INVENTORY_SLOTS; ++i) {
            if (!_slots[binderId][i].occupied) return i;
        }
        revert InventoryFull(binderId);
    }

    function _find721Slot(uint256 binderId, ItemFamily family, uint256 tokenId) private view returns (uint8) {
        for (uint8 i; i < MAX_INVENTORY_SLOTS; ++i) {
            InventorySlot storage item = _slots[binderId][i];
            if (item.occupied && item.family == family && item.instanceTokenId == tokenId) return i;
        }
        revert InvalidInventoryItem();
    }

    function _slotStorage(uint256 binderId, uint8 slot) private view returns (InventorySlot storage item) {
        if (slot >= MAX_INVENTORY_SLOTS || !_slots[binderId][slot].occupied) revert InvalidSlot(slot);
        return _slots[binderId][slot];
    }

    function _clearSlot(uint256 binderId, uint8 slot) private {
        delete _slots[binderId][slot];
        --_occupiedSlotCount[binderId];
    }

    function _requireBinderControllerIdle(uint256 binderId) private view {
        if (binderData.ownerOf(binderId) != msg.sender) revert BinderNotController(binderId, msg.sender);
        uint8 activityId = binderData.getUnitState(binderId).activity.activityId;
        if (activityId != 0) revert BinderBusy(binderId, activityId);
    }

    function _classAllowed(uint256 binderId, uint256[] memory classes) private view returns (bool) {
        if (classes.length == 0) return true;
        uint256 classId = binderData.getNFTClass(binderId);
        for (uint256 i; i < classes.length; ++i) {
            if (classes[i] == classId) return true;
        }
        return false;
    }

    function _statsMeet(uint256 binderId, uint16[8] memory required) private view returns (bool) {
        uint16[8] memory stats = statsView.statsWithGrowth(binderId);
        for (uint256 i; i < 8; ++i) {
            if (stats[i] < required[i]) return false;
        }
        return true;
    }
}
