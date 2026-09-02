// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../supportContract/binderIds.sol";
import "../supportContract/Errors.sol";
import "../supportContract/binderStructs.sol";

/// @notice Pure deterministic evaluator for the bounded structured Art formulas.
/// @dev BattleProxy supplies trusted, locally calculated effective stats; this
/// library never accepts client-provided damage, HP, MP, or result values.
library ArtFormulaLib {
    uint256 internal constant BASIS_POINTS = 10_000;

    /// @notice Resolves flat value plus each configured actor/target stat term.
    /// @dev Division truncates toward zero, matching Solidity signed division.
    function evaluate(
        binderStructs.Formula memory formula,
        uint256[8] memory actorStats,
        uint256[8] memory targetStats
    ) internal pure returns (int256 result) {
        if (formula.termCount > BinderIds.MAX_FORMULA_TERMS) revert InvalidFormulaTermCount(formula.termCount);
        result = int256(formula.flatValue);

        for (uint256 index; index < formula.termCount; ++index) {
            binderStructs.FormulaTerm memory term = formula.terms[index];
            if (term.statId >= BinderIds.STAT_COUNT) revert InvalidFormulaStatId(term.statId);

            uint256 statValue;
            if (term.sourceId == BinderIds.FORMULA_SOURCE_ACTOR) {
                statValue = actorStats[term.statId];
            } else if (term.sourceId == BinderIds.FORMULA_SOURCE_TARGET) {
                statValue = targetStats[term.statId];
            } else {
                revert InvalidFormulaSource(term.sourceId);
            }

            result = _checkedAdd(result, _scaledTerm(statValue, term.coefficientBps));
        }
    }

    /// @notice Converts a signed formula result into damage bounded by current HP.
    function clampDamage(int256 amount, uint16 currentHP) internal pure returns (uint16) {
        if (amount <= 0 || currentHP == 0) return 0;
        if (uint256(amount) >= currentHP) return currentHP;
        return uint16(uint256(amount));
    }

    /// @notice Applies a signed resource delta without exceeding zero or its cap.
    function clampResourceDelta(int256 delta, uint16 currentValue, uint16 maxValue) internal pure returns (uint16) {
        if (currentValue > maxValue) currentValue = maxValue;
        if (delta >= 0) {
            uint256 available = uint256(maxValue) - currentValue;
            if (uint256(delta) >= available) return maxValue;
            return uint16(uint256(currentValue) + uint256(delta));
        }

        // Convert safely even for int256.min.
        uint256 decrease = uint256(-(delta + 1)) + 1;
        if (decrease >= currentValue) return 0;
        return uint16(uint256(currentValue) - decrease);
    }

    /// @notice Returns whether an Art's explicit HP and MP costs are affordable.
    /// @dev Whether an action may spend its last HP is a BattleProxy ruleset
    /// decision; this helper deliberately implements only the stated costs.
    function canPayCosts(uint16 currentHP, uint16 currentMP, uint16 hpCost, uint16 mpCost) internal pure returns (bool) {
        return currentHP >= hpCost && currentMP >= mpCost;
    }

    function _scaledTerm(uint256 statValue, int16 coefficientBps) private pure returns (int256) {
        if (statValue > uint256(type(int256).max)) revert FormulaArithmeticOverflow();

        int256 coefficient = int256(coefficientBps);
        if (coefficient == 0 || statValue == 0) return 0;

        uint256 magnitude = coefficient < 0 ? uint256(-coefficient) : uint256(coefficient);
        if (statValue > uint256(type(int256).max) / magnitude) revert FormulaArithmeticOverflow();
        return (int256(statValue) * coefficient) / int256(BASIS_POINTS);
    }

    function _checkedAdd(int256 left, int256 right) private pure returns (int256) {
        if (right > 0 && left > type(int256).max - right) revert FormulaArithmeticOverflow();
        if (right < 0 && left < type(int256).min - right) revert FormulaArithmeticOverflow();
        return left + right;
    }
}
