// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../interfaces/IBinderData.sol";
import "../interfaces/IBook0fItems.sol";
import "../interfaces/IBinderInventory.sol";
import "../interfaces/IItemUseRouter.sol";
import "./ItemStruct.sol";
import "../supportContract/binderStructs.sol";

/// @notice The intentionally small non-battle item route: only current HP/MP changes on the caller's Idle Binder.
contract ItemUseRouter is IItemUseRouter {
    IBinderData public immutable binderData;
    IBook0fItems public immutable book;
    IBinderInventory public immutable inventory;

    error BinderNotController(uint256 binderId, address caller);
    error BinderBusy(uint256 binderId, uint8 activityId);
    error UnsupportedWorldEffect(uint16 sItemId);
    error InvalidAmount();
    error EffectAmountOverflow();

    constructor(address binderDataAddress, address bookAddress, address inventoryAddress) {
        binderData = IBinderData(binderDataAddress);
        book = IBook0fItems(bookAddress);
        inventory = IBinderInventory(inventoryAddress);
    }

    function useWorldSItem(uint256 binderId, uint16 sItemId, uint128 amount) external {
        if (amount == 0) revert InvalidAmount();
        if (binderData.ownerOf(binderId) != msg.sender) revert BinderNotController(binderId, msg.sender);
        uint8 activityId = binderData.getUnitState(binderId).activity.activityId;
        if (activityId != 0) revert BinderBusy(binderId, activityId);

        SItemConfig memory cfg = book.getSItem(sItemId);
        if (!cfg.exists || !cfg.enabled || cfg.effectCount == 0) revert UnsupportedWorldEffect(sItemId);
        (int32 hpDelta, int32 mpDelta) = _worldDeltas(cfg, amount, sItemId);
        inventory.consumeSItemForWorld(binderId, sItemId, amount);
        binderStructs.NFTMetadata memory details = binderData.getNFTDetails(binderId);
        binderData.adminUpdatePersistentVitals(
            binderId,
            _clamp(details.dynamicStats.currentHP, details.dynamicStats.maxHP, hpDelta),
            _clamp(details.dynamicStats.currentMP, details.dynamicStats.maxMP, mpDelta)
        );
    }

    function _worldDeltas(SItemConfig memory cfg, uint128 amount, uint16 sItemId)
        private
        pure
        returns (int32 hpDelta, int32 mpDelta)
    {
        int256 hp;
        int256 mp;
        for (uint256 i; i < cfg.effectCount; ++i) {
            ItemEffect memory effect = cfg.effects[i];
            if (
                (effect.scope != ItemUseScope.WORLD_ONLY && effect.scope != ItemUseScope.WORLD_OR_BATTLE)
                    || effect.target != ItemTarget.SELF || effect.amount <= 0
            ) revert UnsupportedWorldEffect(sItemId);
            if (effect.kind == ItemEffectKind.MODIFY_CUR_HP) hp += int256(effect.amount) * int256(uint256(amount));
            else if (effect.kind == ItemEffectKind.MODIFY_CUR_MP) mp += int256(effect.amount) * int256(uint256(amount));
            else revert UnsupportedWorldEffect(sItemId);
        }
        if (hp > type(int32).max || hp < type(int32).min || mp > type(int32).max || mp < type(int32).min) {
            revert EffectAmountOverflow();
        }
        return (int32(hp), int32(mp));
    }

    function _clamp(uint16 current, uint16 maximum, int32 delta) private pure returns (uint16) {
        int256 next = int256(uint256(current)) + int256(delta);
        if (next <= 0) return 0;
        if (next >= int256(uint256(maximum))) return maximum;
        return uint16(uint256(next));
    }
}
