# Contract Review Summary

Review scope:

- Reviewed `packages/foundry/contracts`, excluding:
- `packages/foundry/contracts/YourContract.sol`
- `packages/foundry/contracts/YourContract.template.sol`

Primary files reviewed:

- `packages/foundry/contracts/modular/BattleManager.sol`
- `packages/foundry/contracts/modular/BinderData.sol`
- `packages/foundry/contracts/modular/BinderLogic.sol`
- `packages/foundry/contracts/modular/Book0fLife.sol`
- `packages/foundry/contracts/modular/FusionMinter.sol`
- `packages/foundry/contracts/modular/ScaleOfBalance.sol`
- `packages/foundry/contracts/modular/supportContract/binderStructs.sol`
- `packages/foundry/contracts/modular/scripts/InitializeGameData.sol`

Build notes:

- `forge build --skip script` succeeds.
- Full `forge build` fails because the script tree is broken, independent of the core modular contracts.

Highest-risk findings:

1. `BinderLogic` depends on `Book0fLife.getClassesByRarity(...)`, but `Book0fLife` does not implement that function. Random minting will revert at runtime.
2. `FusionMinter` calls `binderData._autoTransferToGraveyard(...)` as an external function, but `BinderData` only defines it as `internal`. Fusion callback resolution will revert at runtime.
3. `ScaleOfBalance.batchUpgradeNFTs(...)` calls `this.upgradeNFT(...)`, which changes `msg.sender` to the contract itself, so batch upgrades fail their ownership check.
4. `ScaleOfBalance` upgrades use the latest historic config instead of the token's actual config version. Tokens that lag by more than one version will be rescaled against the wrong baseline.
5. `ScaleOfBalance._calculateStats(...)` treats `newConfig.totalPoints` as the full stat sum, even though minting treats it as extra allocatable points on top of `minStats`. Upgrade math is inconsistent with mint math.
6. `BinderData` mixes `Ownable` with `initialOwner`, but the constructor never transfers ownership. `onlyOwner` functions are controlled by the deployer, not necessarily `initialOwner`.
7. `BinderLogic` accepts mint payments but has no withdrawal path and does not refund excess payment. Mint revenue and overpayments can become trapped.

Report files:

- `01-critical-findings.md`
- `02-security-and-correctness.md`
- `03-gas-and-performance.md`
- `04-architecture-and-maintainability.md`
- `05-build-and-test-coverage.md`

Recommended order of remediation:

1. Fix the interface/runtime mismatches first.
2. Fix the upgrade math and batch-upgrade flow.
3. Normalize ownership and role wiring across contracts.
4. Add coverage for mint, fusion, upgrade, and cross-contract role configuration.
