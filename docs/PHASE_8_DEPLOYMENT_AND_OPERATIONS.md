# Phase 8 — Integration, Deployment, and Operations

## Canonical bootstrap order

1. Deploy permanent `BinderData` and `CentralConsole`, binding that exact
   BinderData address in the Console constructor.
2. Deploy the locked `BinderSkills` implementation and its ERC-1967 proxy;
   initialize the proxy with the Console's BinderData address, then register
   that proxy through `CentralConsole.setBinderSkills`.
3. Deploy `Book0fLife`, `Book0fArts`, and `Book0fRealms`; configure and
   validate their initial records before publishing their addresses through
   CentralConsole.
4. Deploy `BinderMetadata` from `supportContract/binderMetadata.sol` using the
   canonical BinderData/Skills pair and the chosen Life/Arts Books. Register
   it with CentralConsole, then set it on BinderData with
   `BinderData.setBinderMetadata`.
5. Deploy a fixed `BattleProxy` implementation and a `BattleFactory` that
   references the Console. Register the Factory with a strictly newer Console
   battle-factory version.
6. On `BinderData`, set `ACTIVITY_BATTLE`'s controller to that Factory and call
   `setAuthorizedBattleFactory(factory, true)`. Do not grant `BATTLE_ROLE` to
   BattleProxy clones: their checkpoint/settlement path is provenance-bound.
7. Grant BinderSkills only `METADATA_REFRESH_ROLE` on BinderData. Configure
   ordinary minter/fusion/scale roles on their target contracts as required by
   the existing runtime bootstrap.

The Factory derives all runtime BinderData, Skills, Arts, and Realms addresses
from CentralConsole. A create request supplies only match-local IDs, selected
Arts, and spawn positions; it cannot choose canonical module addresses.

## Battle replacement and settlement

- A new Battle implementation requires a new Factory. Existing clones retain
  their original implementation and snapshotted Books/map/selected Art
  versions.
- CentralConsole prevents an obsolete Factory from creating new matches.
- BinderData keeps the outgoing Factory authorized until all of its registered
  proxy escrows exit. Revocation while live escrows exist reverts.
- Pulses write only dirty vitals and use a strictly advancing nonce per token.
  Final settlement writes all final vitals; zero-HP units move to the configured
  graveyard, while survivors are cleared and returned through the Factory.

## Compatibility and intentionally deferred production work

- `BinderUriBldr` has been removed. BinderData calls BinderMetadata directly
  through `setBinderMetadata`; there is no legacy renderer ABI path.
- `BinderBattleManager` has been removed. Its former broad per-hit persistence
  role is replaced by BattleFactory's activity gateway plus BattleProxy's local
  referee, provenance-bound pulse, and final-settlement path. The historical
  broad `BinderData.BATTLE_ROLE` remains only for non-Battle compatibility
  integrations and is not granted to BattleProxy clones.
- The Phase 6 BattleProxy draft implements selected single/self Damage and Heal
  Arts. Matchmaking economics, full movement/path witnesses, area/line/cone
  patterns, temporary effect duration handling, Guard/ACT/turn policy, and
  timeout/forfeit rules require their separate battle-rule specification before
  a production launch.
- Final ERC721C transfer-hook integration remains a production migration task.
  Existing Activity transfer checks must be retained when it is performed.
- Existing BinderLogic/FusionMinter/Scale instances retain their directly wired
  Life Book addresses until their pending asynchronous work is drained and a
  deliberate per-instance rewire/migration is performed. CentralConsole Book
  cutover and Battle snapshots do not silently mutate those in-flight flows.

## PRD security-search disposition

- Learned Skill arrays occur only in `BinderSkills`; BinderData has none.
- Ailment bitmap shifts/masks occur only in `AilmentBitmapLib`; unrelated
  Base64 and acquisition-flag bit operations are not ailment state.
- No `setEffectiveStats` surface exists.
- Checkpoint/settlement writes occur only through BinderData's registered
  proxy path. Test-only direct calls use Forge caller impersonation to prove
  replay/cap failures.
- No closed numeric upper-bound shortcut is used for Art patterns; the draft
  explicitly supports named `SINGLE` and `SELF` patterns and rejects the rest.

## Validation

The final Phase 8 gate ran:

```text
forge clean
forge build --force
forge test -vvv
```

Result: compilation succeeded and all 40 tests passed.
