// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../interfaces/IBinderData.sol";
import "../interfaces/IItemStatsView.sol";
import "../supportContract/binderStructs.sol";

/// @notice CP5.1a adapter. It deliberately returns permanent base stats until Growth is wired.
contract ItemStatsView is IItemStatsView {
    IBinderData public immutable binderData;

    constructor(address binderDataAddress) {
        binderData = IBinderData(binderDataAddress);
    }

    function statsWithGrowth(uint256 binderId) external view returns (uint32[8] memory stats) {
        binderStructs.NFTMetadata memory details = binderData.getNFTDetails(binderId);
        for (uint256 i; i < 8; ++i) {
            stats[i] = details.staticStats.stats[i];
        }
    }
}
