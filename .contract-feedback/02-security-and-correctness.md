# Security And Correctness Notes

## `BinderBattleManager` role wiring is incomplete and misleading

Evidence:

- Constructor grants `binderData.BATTLE_ROLE()` to `address(this)` inside the battle manager’s own `AccessControl` registry at `packages/foundry/contracts/modular/BattleManager.sol:12-16`.
- User-facing entry points are gated by the local `BATTLE_ROLE` at `packages/foundry/contracts/modular/BattleManager.sol:18-32`.
- State mutation is delegated to `binderData.updateCurrentStats(...)`, which is protected by `BinderData`’s `BATTLE_ROLE` at `packages/foundry/contracts/modular/BinderData.sol:168-180`.

Issue:

- The constructor comment says it “grants self role”, but it only grants a role in the battle manager contract, not in `BinderData`.
- No external account is granted the battle manager’s local `BATTLE_ROLE`.
- For the flow to work, two separate role assignments must happen off-contract:
- callers must receive the battle manager’s `BATTLE_ROLE`
- the battle manager contract address must receive `BinderData.BATTLE_ROLE`

Recommendation:

- Make this explicit in deployment code, or have the deploy/admin flow configure it atomically.
- If `BinderBattleManager` is the intended single battle writer, remove the duplicated local role and let `BinderData` authorize it directly.

## `toggleBattleSystem(bool)` is a no-op

Evidence:

- The function is declared at `packages/foundry/contracts/modular/BattleManager.sol:70-73` and does nothing.

Impact:

- The interface suggests an emergency brake exists, but no operational pause state is enforced.
- Integrators and operators may assume a control exists that does not actually exist.

Recommendation:

- Either implement a real pause mechanism or remove the function to avoid false assurances.

## `Book0fLife` role rotation leaks privileges on first change

Evidence:

- Constructor grants `CONFIG_ROLE` and `FUSION_MINTER` to `msg.sender` at `packages/foundry/contracts/modular/Book0fLife.sol:34-38`.
- `currentConfigAdmin` and `currentFusionMinter` start as zero addresses at `packages/foundry/contracts/modular/Book0fLife.sol:31-32`.
- `changeConfigRole(...)` revokes from `currentConfigAdmin` and then grants the new address at `packages/foundry/contracts/modular/Book0fLife.sol:236-245`.
- `changeFusionMinterRole(...)` does the same with `currentFusionMinter` at `packages/foundry/contracts/modular/Book0fLife.sol:248-257`.

Issue:

- On the first rotation, `revokeRole(...)` is executed against `address(0)`, so the original deployer keeps the role.
- Subsequent role changes create additive privileges instead of clean rotation.

Recommendation:

- Initialize `currentConfigAdmin` and `currentFusionMinter` in the constructor to `msg.sender`, or stop tracking them separately and use `getRoleMember`/explicit role-admin processes.

## `getFusionRecipe(...)` authorization can break protocol flows

Evidence:

- `getFusionRecipe(...)` is restricted to `DEFAULT_ADMIN_ROLE` or `currentFusionMinter` at `packages/foundry/contracts/modular/Book0fLife.sol:163-169`.
- `FusionMinter` depends on this function during callback resolution at `packages/foundry/contracts/modular/FusionMinter.sol:236-239`.

Issue:

- Fusion resolution depends on `currentFusionMinter` being configured exactly right.
- If that address is not updated to the live `FusionMinter` contract, fusion callbacks revert.
- There is no user-facing recovery function to unwind already transferred NFTs.

Recommendation:

- Recipe reads should usually be permissionless if they are protocol state.
- If restricted reads are required, enforce and validate the role wiring during deployment with an integration smoke test.

## `Book0fLife` recipe enumeration can return empty data for valid recipes

Evidence:

- Recipes are stored under sorted keys at `packages/foundry/contracts/modular/Book0fLife.sol:98-127`.
- The tracker pushes the unsorted `(class1, class2)` pair at `packages/foundry/contracts/modular/Book0fLife.sol:137-141`.
- Enumeration later reads `_fusionRecipe[pair.class1][pair.class2]` directly at `packages/foundry/contracts/modular/Book0fLife.sol:201-215`.

Issue:

- If a recipe is added as `(5, 2)`, storage happens under `(2, 5)` but enumeration may read `(5, 2)`.
- `getAllSimpleFusionRecipes()` can therefore return an empty recipe even though the recipe exists.

Recommendation:

- Push the sorted pair into `_allFusionPairs`.
- Re-sort on read as defense in depth.

## `removeClass(...)` and `removeFusionRecipe(...)` leave stale indexes behind

Evidence:

- `removeClass(...)` deletes mappings only at `packages/foundry/contracts/modular/Book0fLife.sol:77-82`.
- `removeFusionRecipe(...)` deletes the recipe mapping only at `packages/foundry/contracts/modular/Book0fLife.sol:144-147`.
- Enumeration depends on `_allClassIds`, `_classExists`, `_allFusionPairs`, and `_fusionPairExists`.

Issue:

- Removed data still appears in the tracking arrays.
- Re-adding a class behaves differently because `_classExists[classId]` is never reset.
- Off-chain indexers and admin dashboards can receive stale results.

Recommendation:

- Either support full deletion with swap-and-pop index maintenance or explicitly make these records immutable and replace “remove” with a disabled flag.

## `BinderData` emits swapped fields for fusion mint events

Evidence:

- Event is declared as `NFTFusionMinted(address indexed owner, uint256 tokenId, string rarity, string className)` at `packages/foundry/contracts/modular/BinderData.sol:49-53`.
- Emission uses `(recipient, tokenId, className, rarity)` at `packages/foundry/contracts/modular/BinderData.sol:131-135`.

Impact:

- Off-chain consumers receive inverted `rarity` and `className` values.
- This corrupts analytics, metadata sync, or downstream automation that trusts the event schema.

Recommendation:

- Emit the fields in declared order and add a test that decodes event arguments.

## `BinderData.updateNFTStats(...)` does not validate dynamic stat invariants

Evidence:

- The function assigns `dynamicStats` directly at `packages/foundry/contracts/modular/BinderData.sol:160-162`.

Issue:

- A `CONFIG_ROLE` caller can write inconsistent data such as `currentHP > maxHP` or `currentMP > maxMP`.
- `ScaleOfBalance` currently computes sane values, but the base contract does not defend its own invariants.

Recommendation:

- Enforce `currentHP <= maxHP` and `currentMP <= maxMP` inside `BinderData`.
- Prefer base-contract validation even when an upstream config contract is expected to behave.

## `BinderData` admin setters allow unsafe zero-address configuration

Evidence:

- `setBinderUriBldr(...)` at `packages/foundry/contracts/modular/BinderData.sol:245-247`
- `setFusionOperator(...)` at `packages/foundry/contracts/modular/BinderData.sol:257-260`
- `setGraveyard(...)` at `packages/foundry/contracts/modular/BinderData.sol:263-265`

Issue:

- Setting zero addresses can disable key flows or cause downstream reverts.
- Example: graveyard transfer to the zero address will revert through ERC721 transfer rules.

Recommendation:

- Reject zero addresses unless a deliberate “unset” mode is part of the design, and emit events for every setter.

## `BinderLogic` randomness composition couples one user’s mint to the previous user

Evidence:

- `previousRandomNumber` is stored at `packages/foundry/contracts/modular/BinderLogic.sol:31`.
- The next mint’s stat seed is built from `previousRandomNumber` and the current seed at `packages/foundry/contracts/modular/BinderLogic.sol:111-116`.

Risk:

- The previous user’s randomness becomes a shared public input into the next user’s stat generation.
- This is not obviously exploitable by itself, but it increases audit complexity and creates cross-user coupling without a clear security gain.

Recommendation:

- Prefer deriving all properties from the current callback entropy plus domain-separated salts.

## `FusionMinter` uses `transfer` for refunds and withdrawals

Evidence:

- Refund in `riteFusion(...)` at `packages/foundry/contracts/modular/FusionMinter.sol:105-107`
- Admin withdraw at `packages/foundry/contracts/modular/FusionMinter.sol:408-410`

Risk:

- `transfer` hardcodes a 2300 gas stipend.
- It can fail against smart-contract recipients or become brittle across EVM gas changes.

Recommendation:

- Use low-level `call` and check the return value.

## `FusionMinter` accepts fusion requests before validating recipe availability

Evidence:

- NFTs are transferred in at `packages/foundry/contracts/modular/FusionMinter.sol:93-94`.
- Recipe resolution does not happen until callback at `packages/foundry/contracts/modular/FusionMinter.sol:135-160`.

Risk:

- A configuration error or missing permission on `getFusionRecipe(...)` is discovered only after custody has already moved.

Recommendation:

- Validate that the pair resolves to an accessible recipe before taking custody, or provide an admin/user rescue path for unresolved requests.
