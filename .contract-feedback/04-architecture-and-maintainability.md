# Architecture And Maintainability Review

## 1. The cross-contract interface layer is not authoritative

Symptoms:

- `BinderLogic` expects `Book0fLife.getClassesByRarity(...)`, but the real contract does not implement it.
- `FusionMinter` expects `BinderData._autoTransferToGraveyard(...)` as an external callable function, but the real contract only defines it internally.

Implication:

- The interfaces are treated as wish-lists rather than audited compatibility contracts.
- The system can compile while still being unable to execute core flows.

Recommendation:

- Extract shared interfaces into dedicated files.
- Make implementation contracts explicitly inherit those interfaces.
- Add a deployment-time or test-time compatibility suite that instantiates the real contracts together.

## 2. Ownership and role models are inconsistent across modules

Examples:

- `BinderData` mixes `Ownable` and `AccessControl`.
- `BinderLogic` inherits `Ownable` and `AccessControl` but only uses role gating.
- `FusionMinter` uses `AccessControl` only.
- `Book0fLife` tracks “current” admin addresses separately from role membership.

Implication:

- It is difficult to reason about who actually controls the system after deployment.
- Authority can drift between deployer, `initialOwner`, role members, and tracked address variables.

Recommendation:

- Pick one control model per module.
- If the system needs multiple live operators, standardize on `AccessControl`.
- If a module only needs one operator, simplify to `Ownable`.

## 3. Protocol configuration depends on fragile manual sequencing

Current operational requirements inferred from the code:

- `BinderLogic` needs `BinderData.MINTER_ROLE`.
- `FusionMinter` needs `BinderData.FUSION_ROLE`.
- `BinderBattleManager` needs `BinderData.BATTLE_ROLE`.
- `ScaleOfBalance` needs `BinderData.CONFIG_ROLE` and `Book0fLife.CONFIG_ROLE`.
- `FusionMinter` must also be recognized by `Book0fLife.getFusionRecipe(...)`.

Implication:

- A single missed role grant can break live user flows after funds or NFTs move.
- The contracts do not self-check that critical dependencies are correctly wired.

Recommendation:

- Add a post-deploy sanity checker or constructor/init-time assertions where possible.
- Consider a central deployment configurator that grants all required roles atomically and verifies them.

## 4. Mint, fusion, and upgrade logic are drift-prone because business rules are duplicated

Examples:

- Mint stat allocation exists in `BinderLogic`.
- Fusion stat allocation exists again in `FusionMinter`.
- Upgrade stat scaling exists separately in `ScaleOfBalance`.

Implication:

- Any balancing rule change requires synchronized edits in multiple contracts.
- Divergence is already visible between the “allocate points” interpretation and the upgrade “totalPoints” interpretation.

Recommendation:

- Centralize the game-rule math in one library.
- Treat contract modules as orchestration and state boundaries, not separate sources of truth for stat math.

## 5. `Book0fLife` should probably be the authoritative content registry, but it does not enforce its own invariants

Examples:

- `ScaleOfBalance` validates min/max stat ranges and `totalPoints`.
- `Book0fLife.addNewClass(...)` and `upgradeClassConfig(...)` accept config directly without equivalent invariant checks.

Implication:

- Any address with direct `CONFIG_ROLE` on `Book0fLife` can write inconsistent class data and bypass the safety rules implemented in `ScaleOfBalance`.

Recommendation:

- Push invariant checks into `Book0fLife` itself.
- Let `ScaleOfBalance` remain a convenience/orchestration layer, not the only defensive layer.

## 6. NFT lifecycle is encoded indirectly through custody changes

Current design:

- Death and fusion cleanup are represented by transferring NFTs to `binderGraveyard`.

Concerns:

- Lifecycle state becomes dependent on external address configuration and transfer success.
- Rescue, analytics, and game logic become harder to reason about than with an explicit lifecycle flag or enum.

Recommendation:

- Consider separating “state = dead/fused/retired” from “custody destination”.
- A transfer to graveyard can remain part of the UX, but it should not be the sole state machine.

## 7. Entropy integration is version-split across modules

Evidence:

- `BinderLogic` uses `IEntropyV2` at `packages/foundry/contracts/modular/BinderLogic.sol:8-9,25,62-66`.
- `FusionMinter` uses `IEntropy` v1-style APIs at `packages/foundry/contracts/modular/FusionMinter.sol:10-11,49,84,317-322`.

Implication:

- The system currently maintains two randomness integration styles.
- This increases deployment complexity and makes future provider upgrades harder.

Recommendation:

- Normalize the protocol onto one entropy version unless there is a very deliberate reason not to.

## 8. Repository hygiene around the contracts area needs cleanup

Evidence:

- Contract-adjacent backup files exist under `packages/foundry/contracts/modular/.ignore.backup`.
- `contracts/mocks/MockEntropy.ignore` exists, while scripts import `contracts/mocks/MockEntropy.sol`.
- `InitializeGameData.sol` lives under `contracts/modular/scripts`, which blurs the line between deploy helpers and runtime contracts.

Implication:

- Tooling and reviewers cannot rely on directory structure to infer what is production code.
- Missing or renamed files already cause build failures in the script tree.

Recommendation:

- Move runtime contracts, mocks, scripts, and backups into clearly separated directories.
- Delete or relocate stale backups from the compile path.
