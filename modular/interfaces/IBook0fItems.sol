// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../Items/ItemStruct.sol";
import "./IBook0fArts.sol";

interface IBook0fItems {
    function ITEMS_CONFIG_ROLE() external view returns (bytes32);
    function book0fArts() external view returns (IBook0fArts);
    function setItemsConfigAuthority(address previousAuthority, address newAuthority) external;
    function addEq(EqConfig calldata cfg) external returns (uint16);
    function updateEq(uint16 id, EqConfig calldata cfg) external;
    function deactivateEq(uint16 id) external;
    function addTome(TomeConfig calldata cfg) external returns (uint16);
    function updateTome(uint16 id, TomeConfig calldata cfg) external;
    function deactivateTome(uint16 id) external;
    function addSItem(SItemConfig calldata cfg) external returns (uint16);
    function updateSItem(uint16 id, SItemConfig calldata cfg) external;
    function deactivateSItem(uint16 id) external;
    function getEq(uint16 eqId) external view returns (EqConfig memory);
    function getTome(uint16 tomeId) external view returns (TomeConfig memory);
    function getSItem(uint16 sItemId) external view returns (SItemConfig memory);
    function isEqEnabled(uint16 eqId) external view returns (bool);
    function isTomeEnabled(uint16 tomeId) external view returns (bool);
    function isSItemEnabled(uint16 sItemId) external view returns (bool);
}
