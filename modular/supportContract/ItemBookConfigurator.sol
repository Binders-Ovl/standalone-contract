// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../interfaces/IBook0fItems.sol";

/// @notice Shared typed Book edits; each control plane enforces its existing role in the resolver.
abstract contract ItemBookConfigurator {
    function _itemBookForConfig() internal view virtual returns (IBook0fItems);

    function addEq(EqConfig calldata cfg) external returns (uint16) {
        return _itemBookForConfig().addEq(cfg);
    }

    function updateEq(uint16 id, EqConfig calldata cfg) external {
        _itemBookForConfig().updateEq(id, cfg);
    }

    function deactivateEq(uint16 id) external {
        _itemBookForConfig().deactivateEq(id);
    }

    function addTome(TomeConfig calldata cfg) external returns (uint16) {
        return _itemBookForConfig().addTome(cfg);
    }

    function updateTome(uint16 id, TomeConfig calldata cfg) external {
        _itemBookForConfig().updateTome(id, cfg);
    }

    function deactivateTome(uint16 id) external {
        _itemBookForConfig().deactivateTome(id);
    }

    function addSItem(SItemConfig calldata cfg) external returns (uint16) {
        return _itemBookForConfig().addSItem(cfg);
    }

    function updateSItem(uint16 id, SItemConfig calldata cfg) external {
        _itemBookForConfig().updateSItem(id, cfg);
    }

    function deactivateSItem(uint16 id) external {
        _itemBookForConfig().deactivateSItem(id);
    }
}
