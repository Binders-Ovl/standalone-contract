// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./IBinderData.sol";

/// @notice Proof shared by the two fixed-code growth controllers, never a generic gameplay writer.
interface IGrowthActivity {
    /// @dev Kind: Drill=1, xDrill=2, Errantry=3, Quest=4.
    /// Phase: started=1, requested=2, seeded=3, settled=4, claimed=5, rescued=6.
    function activityProof(bytes32 activityId)
        external
        view
        returns (uint256 binderId, address beneficiary, uint8 kind, uint8 phase);
    function growthResult(bytes32 activityId) external view returns (int32[8] memory);
    function skillReward(bytes32 activityId, bool pattern)
        external
        view
        returns (address book, uint32 artId, uint16 version);
}

interface IQuestReward is IGrowthActivity {
    function binderData() external view returns (IBinderData);
    function itemReward(bytes32 activityId)
        external
        view
        returns (address collection, address beneficiary, uint16 libraryId, uint128 amount);
}
