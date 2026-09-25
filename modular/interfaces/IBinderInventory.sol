// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../Items/ItemStruct.sol";
import "./IBook0fItems.sol";
import "./IEquipment.sol";
import "./ITomeAndGrimoires.sol";
import "./ISItems.sol";
import {IItemStatsView} from "./IItemStatsView.sol";

interface IBinderInventory {
    function statsView() external view returns (IItemStatsView);
    function centralConsole() external view returns (address);
    function book() external view returns (IBook0fItems);
    function equipment() external view returns (IEquipment);
    function tomes() external view returns (ITomeAndGrimoires);
    function sItems() external view returns (ISItems);
    function setCollections(address equipmentAddress, address tomeAddress, address sItemAddress) external;
    function setStatsView(address newStatsView) external;
    function setBinderSkills(address newBinderSkills) external;
    function setItemUseRouter(address newItemUseRouter) external;
    function accountOf(uint256 binderId) external view returns (address);
    function isBinderAccount(address account) external view returns (bool);
    function prepareEquipmentMint(uint256 binderId, uint16 eqId, uint256 tokenId) external returns (address);
    function prepareTomeMint(uint256 binderId, uint16 tomeId, uint256 tokenId) external returns (address);
    function prepareSItemMint(uint256 binderId, uint16 sItemId, uint128 amount) external returns (address);
    function consumeTomeForLearning(uint256 binderId, uint256 tomeTokenId) external;
    function lockTomeForLearning(uint256 binderId, uint256 tomeTokenId) external;
    function unlockTomeForLearning(uint256 binderId, uint256 tomeTokenId) external;
    function isTomeInInventory(uint256 binderId, uint256 tomeTokenId) external view returns (bool);
    function tomeIdInInventory(uint256 binderId, uint256 tomeTokenId) external view returns (uint16);
    function consumeSItemForWorld(uint256 binderId, uint16 sItemId, uint128 amount) external;
    function consumeSItemForBattle(uint256 binderId, uint8 slot, uint128 amount) external returns (uint16 sItemId);
    function hasInventory(uint256 binderId) external view returns (bool);
    function getSlot(uint256 binderId, uint8 slot) external view returns (InventorySlot memory);
    function getSlots(uint256 binderId) external view returns (InventorySlot[20] memory);
    function equipmentModifiers(uint256 binderId) external view returns (int32[8] memory);
    function reconcileEquipment(uint256 binderId) external;
}
