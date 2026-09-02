// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../supportContract/binderIds.sol";
import "../supportContract/Errors.sol";

/// @notice Sole bit-manipulation boundary for battle-local ailment flags.
/// @dev Add and remove are deliberately idempotent: adding an existing flag or
/// removing an absent one returns the original bitmap. Detailed duration and
/// stacking information remains separate BattleProxy state.
library AilmentBitmapLib {
    function has(uint256 bitmap, uint8 ailmentId) internal pure returns (bool) {
        return (bitmap & _mask(ailmentId)) != 0;
    }

    function add(uint256 bitmap, uint8 ailmentId) internal pure returns (uint256) {
        return bitmap | _mask(ailmentId);
    }

    function remove(uint256 bitmap, uint8 ailmentId) internal pure returns (uint256) {
        return bitmap & ~_mask(ailmentId);
    }

    function _mask(uint8 ailmentId) private pure returns (uint256) {
        if (ailmentId < BinderIds.MIN_AILMENT_ID) revert InvalidAilmentId(ailmentId);
        return uint256(1) << uint256(ailmentId - BinderIds.MIN_AILMENT_ID);
    }
}
