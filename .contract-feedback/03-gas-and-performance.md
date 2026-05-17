# Gas And Performance Review

These notes are lower priority than the correctness issues, but they are worth addressing once runtime safety is restored.

## Replace string-heavy state with compact identifiers

Current pattern:

- `BinderData` stores `name` and `rarity` per token in `NFTMetadata` at `packages/foundry/contracts/modular/supportContract/binderStructs.sol:88-97`.
- `Book0fLife` stores `string` names and rarities per class at `packages/foundry/contracts/modular/Book0fLife.sol:10-12`.
- Events also emit strings from mint flows in `packages/foundry/contracts/modular/BinderData.sol:49-53`.

Why it is expensive:

- Strings are dynamic storage.
- Repeating rarity strings like `"Common"` or `"Rare"` per token is especially wasteful.
- Storing `name = className + "#" + tokenId` duplicates derivable data on-chain.

Recommendation:

- Store `classId` and possibly a compact `uint8 rarityId` only.
- Derive display name and human-readable rarity off-chain or in a metadata builder contract.

## Remove duplicated stat allocation logic

Current pattern:

- `BinderLogic._allocateStats(...)` at `packages/foundry/contracts/modular/BinderLogic.sol:151-210`
- `FusionMinter._allocateStats(...)` at `packages/foundry/contracts/modular/FusionMinter.sol:181-217`

Why it matters:

- Two copies increase deployment bytecode size.
- Two copies increase audit surface.
- Two copies are likely to drift over time, which has already happened between mint and upgrade logic.

Recommendation:

- Move stat allocation into a dedicated internal library.
- Reuse the same helper from mint, fusion, and upgrade flows.

## Prefer custom errors over revert strings

Current pattern:

- `Book0fLife`, `BinderLogic`, `FusionMinter`, and `ScaleOfBalance` rely heavily on `require(..., "string")`.

Why it matters:

- Custom errors are materially cheaper at runtime and deployment.
- They standardize failure handling and make tests more precise.

Recommendation:

- Follow the `BinderData` pattern of declaring custom errors and reuse them across the modular contracts.

## Cache repeated storage and external reads

Examples:

- `BinderData.updateNFTStats(...)` reads `classVersion[classId]` twice at `packages/foundry/contracts/modular/BinderData.sol:154` and `162`.
- `ScaleOfBalance.updateClassConfig(...)` calls both `book0fLife.getClassVersion(classId)` and `binderData.classVersion(classId)` at `packages/foundry/contracts/modular/ScaleOfBalance.sol:121-123`, then later calls `book0fLife.getClassName(classId)` again at line 150.
- `FusionMinter.riteFusion(...)` fetches both class IDs after transfer at `packages/foundry/contracts/modular/FusionMinter.sol:96-99`, but the sorted result is not reused beyond entropy request preparation.

Recommendation:

- Cache repeated reads into local variables and reuse them.
- Avoid external calls after you already have the needed value in memory.

## Use `unchecked` increments in bounded loops

Examples:

- Many loops iterate over arrays with clear upper bounds of 8 or 32:
- `BinderLogic.sol:175-208`, `214-235`
- `FusionMinter.sol:190-216`, `252-267`, `278-291`
- `Book0fLife.sol:109-122`, `181-197`, `204-214`
- `ScaleOfBalance.sol:48-58`, `109-116`, `159-166`, `192-230`

Why it matters:

- Solidity 0.8 adds overflow checks by default.
- In short, bounded loops with obvious maxima can often safely use `unchecked { ++i; }`.

Recommendation:

- Apply selectively after the codebase is stabilized and tested.

## Reconsider mutable storage for mostly-static config

Examples:

- `supplyBuffer` and `supplyIncrement` in `BinderData` at `packages/foundry/contracts/modular/BinderData.sol:35-38`
- fixed chance denominator `MAX_CHANCE_VALUE` is already constant in `BinderLogic`

Recommendation:

- Use `constant` or `immutable` for configuration that is not meant to change.
- This reduces storage reads and clarifies intent.

## Split large getters to avoid copying whole structs

Current pattern:

- `getNFTDetails(...)` returns the entire `NFTMetadata` struct, including dynamic strings, at `packages/foundry/contracts/modular/BinderData.sol:234-239`.
- `getFusionRecipe(...)` returns a dynamic array-containing struct at `packages/foundry/contracts/modular/Book0fLife.sol:163-169`.

Why it matters:

- Copying large dynamic structs into memory is expensive for both on-chain callers and off-chain RPC payload size.

Recommendation:

- Keep the full getter for convenience if needed, but also expose narrower getters for hot paths.

## `AccessControl` may be heavier than needed in some modules

Observation:

- Every modular contract uses `AccessControl`, and some also mix `Ownable`.

Why it matters:

- `AccessControl` is justified when multiple independent roles truly exist.
- For single-admin helper contracts, `Ownable` or a small custom authority model can be cheaper and easier to audit.

Recommendation:

- Keep `AccessControl` only where multiple live roles are actively exercised.
- Remove redundant `Ownable` inheritance when all privileged paths already use roles.
