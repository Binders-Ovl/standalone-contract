// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-4.8/access/AccessControl.sol";
import "./BinderData.sol";
import "./supportContract/binderStructs.sol";

contract BinderBattleManager is AccessControl {
    BinderData public immutable binderData;
    bytes32 public constant BATTLE_ROLE = keccak256("BATTLE_ROLE");

    constructor(address _binderData) {
        binderData = BinderData(_binderData);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(binderData.BATTLE_ROLE(), address(this)); // Grants self role
    }

    /// @notice Applies damage to NFT and triggers state updates
    function applyDamage( uint256 tokenId, uint16 hpDamage, uint16 mpDamage
    ) external onlyRole(BATTLE_ROLE) {
        binderStructs.NFTMetadata memory meta = binderData.getNFTDetails(tokenId);
        
        uint16 newHP = _safeSub(meta.dynamicStats.currentHP, hpDamage);
        uint16 newMP = _safeSub(meta.dynamicStats.currentMP, mpDamage);

        // BinderData handles state update and potential transfer
        binderData.updateCurrentStats(tokenId, newHP, newMP);
    }

    /// @notice Applies heal and damage to NFT and triggers state updates
    function applySkill( uint256 tokenId, uint16 hpHeal, uint16 mpHeal, uint16 hpDamage, uint16 mpDamage
    ) external onlyRole(BATTLE_ROLE) {
        binderStructs.NFTMetadata memory meta = binderData.getNFTDetails(tokenId);

        uint16 newHP = _calculateStatChange(
            meta.dynamicStats.currentHP,
            hpHeal,
            hpDamage,
            meta.dynamicStats.maxHP
        );

        uint16 newMP = _calculateStatChange(
            meta.dynamicStats.currentMP,
            mpHeal,
            mpDamage,
            meta.dynamicStats.maxMP
        );

        // BinderData handles state update
        binderData.updateCurrentStats(tokenId, newHP, newMP);
    }

    /// @dev Satats modifier for simplified calculations
    /// @notice To be used while doing simple damage if it higher thn current hp return 0 (no negative), 
    /// else return current - damage
    function _safeSub( uint16 current, uint16 sub) internal pure returns (uint16) {
        return sub > current ? 0 : current - sub;
    }

    /// @dev Stats modifier for complex calculations
    /// @notice To be used while doing complex calculations that basically invovle skills modifier
    /// like healing, berserk, manaBurn, manaRegen, etc.
    function _calculateStatChange( uint16 currentDynStat, uint16 heal, uint16 damage, uint16 maxDynStat
    ) internal pure returns (uint16) {
        uint256 healed = uint256(currentDynStat) + heal;
        uint256 healedCapped = healed > maxDynStat ? maxDynStat : healed;
        return _safeSub(uint16(healedCapped), damage);
    }

    /// @notice Emergency stop for battle system
    function toggleBattleSystem(bool active) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // Implementation depends on BinderData's access control setup
    }
}
