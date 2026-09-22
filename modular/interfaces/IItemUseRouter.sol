// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./IBinderData.sol";
import "./IBook0fItems.sol";
import "./IBinderInventory.sol";

interface IItemUseRouter {
    function binderData() external view returns (IBinderData);
    function book() external view returns (IBook0fItems);
    function inventory() external view returns (IBinderInventory);
    function useWorldSItem(uint256 binderId, uint16 sItemId, uint128 amount) external;
}
