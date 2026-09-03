# Phase 0 — Baseline Reconciliation

**Authoritative architecture:** `.idea/.latest-prd/Binders-FINAL-End-to-End-Architecture-PRD.md`  
**Migration baseline inspected:** `modular/` on Git branch `work-migration1` at `03887f4`  
**Foundry project root:** repository root (`src = "modular"`, `test = "test"`)

## Verified preserved baseline

The current contracts implement the NFT State / URI baseline described by the
historical implementation record:

- `BinderData` owns compact `ActivityState`, derived `UnitStateView`, activity
  controller gating, transfer locks, version freshness, graveyard integration,
  and ERC-4906 signaling.
- The historical `BinderUriBldr` was a read-only Base64 JSON renderer and typed
  aggregate view. Its responsibility now belongs entirely to `BinderMetadata`.
- The historical `BinderBattleManager` was a transitional persistent-vitals
  stat manager. Its final architecture is split between `BattleFactory` and
  per-match `BattleProxy` clones.
- `Book0fLife`, `BinderLogic`, `FusionMinter`, `ScaleOfBalance`, and
  `AllegianceRegistry` retain the current class, nation, rarity, mint, fusion,
  and upgrade baseline.

## Historical-document reconciliation

- `NFT-state-and-URI/IMPLEMENTATION_AND_VERIFICATION.md` matches the currently
  implemented activity, metadata, role-wiring, and ERC-4906 behavior.
- `revised-prd/IMPLEMENTATION_AND_VERIFICATION.md` is an older nation/rarity
  migration record. Its statement that no URI builder exists was stale at the
  baseline checkpoint; the final implementation uses BinderMetadata.
- Repository `.contract-feedback/` references an older `packages/foundry`
  layout and pre-dates the current branch. It is retained as historical review
  material, not used as an authority over the current source or master PRD.

## Master-PRD deltas intentionally deferred to their assigned phases

- The baseline uses OZ 4.8 ERC721/ERC721Pausable; the planned final ERC721C
  migration has not occurred.
- `supportContract/CentralConsole`, `supportContract/binderIds`, shared
  `supportContract/Errors`, the narrow `interfaces/`
  layer, `BinderSkills`, `Book0fArts`, `Book0fRealms`, battle libraries,
  `BattleFactory`, and `BattleProxy` do not yet exist.
- The baseline URI renderer is replaced by `supportContract/binderMetadata.sol`
  in Phase 4; it is not retained after final migration.
- `Book0fLife` has current configuration functionality but does not yet provide
  the complete bounded migration/export surface required in Phase 3.
- Current `BinderData` activity controllers are one address per activity. The
  multi-instance Battle activity gateway is a Phase 6 refactor.
- Current `BinderData.BATTLE_ROLE` remains a broad transitional vitals writer;
  canonical BattleProxy provenance and checkpoint nonce checks belong to
  Phases 6 and 7.

## Validation run

```text
forge clean
forge build --force
forge test -vvv
```

Result: compilation succeeded; all 13 tests passed (8 NFT state/URI tests and
5 nation/rarity migration tests).

No Solidity behavior was changed during Phase 0.
