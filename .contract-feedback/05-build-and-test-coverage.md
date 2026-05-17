# Build And Test Coverage Notes

## Build status

### Core modular contracts

Command used:

```powershell
forge build --skip script
```

Result:

- Success.

Interpretation:

- The reviewed modular contracts are at least syntactically compilable together when deployment scripts are excluded.
- This does not validate runtime compatibility between modules.

### Full foundry package

Command used:

```powershell
forge build
```

Result:

- Failure.

Observed blockers:

1. `script/Deploy.s.sol` has a parser error near line 135.
2. `script/perContract/DeployMockEntropy.s.sol` imports `../../contracts/mocks/MockEntropy.sol`, but the file present in the repo is `contracts/mocks/MockEntropy.ignore`.
3. `script/perContract.backup/DeployMockEntropy.s.sol` has the same missing import problem.
4. `script/Deploy.s.sol` also references missing per-contract script files such as `./perContract/DeployBattleManager.s.sol` and `./perContract/DeploySetupGame.s.sol`.

Interpretation:

- The package cannot currently be treated as build-clean end to end.
- Even if the contracts compile, the deployment path is not in a releasable state.

## Test coverage status

Observed test tree:

- `packages/foundry/test/YourContract.t.sol`

Assessment:

- The only discovered test file is the template test.
- There is no contract-specific coverage for `BinderData`, `BinderLogic`, `Book0fLife`, `FusionMinter`, `ScaleOfBalance`, or `BinderBattleManager`.

This is the largest process risk in the repository.

Without integration tests, the current runtime mismatches were able to survive compilation because:

- interfaces were declared independently from implementations
- role wiring spans multiple contracts
- entropy callbacks defer failures until after earlier state transitions

## Minimum test plan before production use

### Integration tests

1. Mint path:
- deploy `Book0fLife`, `BinderData`, and `BinderLogic`
- configure all required roles
- execute entropy callback end to end
- assert class selection, stat allocation, event emission, and ETH accounting

2. Fusion path:
- deploy `Book0fLife`, `BinderData`, and `FusionMinter`
- configure recipe access and graveyard/fusion permissions
- request fusion, resolve callback, assert custody of both sacrificed NFTs and the fused NFT

3. Upgrade path:
- mint NFTs on version N
- change class config to version N+1 and N+2
- upgrade one token immediately and one token after multiple skipped versions
- assert both receive the intended result

4. Battle path:
- wire `BinderBattleManager` to `BinderData`
- assert damage, heal, death transfer, and unauthorized access reverts

### Unit tests

1. `Book0fLife`
- recipe storage and retrieval with sorted and unsorted inputs
- class removal and recipe removal behavior
- role rotation behavior

2. `ScaleOfBalance`
- `_calculateStats(...)` under positive and negative delta cases
- `_preserveRatio(...)`
- batch upgrade behavior

3. `BinderData`
- owner/role initialization
- event argument order
- setter validation

4. `BinderLogic`
- rarity threshold boundaries
- behavior when there are zero candidates for a rarity
- overpayment handling

## Suggested release gate

Do not treat this contract set as deployment-ready until all of the following are true:

1. Full `forge build` is clean.
2. At least one end-to-end test exists for mint, fusion, upgrade, and battle flows.
3. Cross-contract interface compatibility is verified by tests against the real implementations, not only against local interfaces.
