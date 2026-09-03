# Fix 1 developer notes

## ERC721C remains deferred

`BinderData` remains a permanent, non-upgradeable OpenZeppelin ERC-721 in Fix 1.
No proxy was introduced around it. A future ERC721C migration must revalidate the
transfer authorization and hook behavior for minting, ordinary transfers,
activity locks, Battle escrow and settlement, Fusion custody, Graveyard entry,
resurrection, and permanent burning.

## Deferred Battle work

Fix 1 keeps the on-chain referee deliberately narrow: explicit two-player
consent, loadout validation, single/self Damage and Heal resolution, checkpoint
provenance, and controller-based settlement. Movement/path witnesses, terrain,
turns/rounds, Guard, items, ailments, buffs, area patterns, AFK/forfeit rules,
and nation/castle result consumers remain future work. The frontend may preview
these features but cannot supply trusted canonical HP, ownership, winner, or
damage values.
