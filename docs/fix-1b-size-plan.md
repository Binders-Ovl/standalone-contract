# Fix-1b BinderData size plan

`BinderData` is deliberately still plain ERC-721 in Fix-1b. The test suite prints
its optimized runtime size and EIP-170 headroom at every release gate, with an
early warning at 24,100 bytes and a hard deployment cap of 24,576 bytes.

The current repository does not contain an ERC721C implementation or a selected
transfer-validator dependency. Therefore an "exact ERC721C" proof-of-concept
cannot be compiled honestly from this checkout. Do not add ERC721C to BinderData
until the selected Creator Token/ERC721C release and validator integration are
vendored or pinned, then:

1. compile an isolated BinderData subclass using those exact sources;
2. record its optimized runtime-byte delta under the production compiler settings;
3. retain a material margin below EIP-170 before integrating it into BinderData;
4. compare mint, transfer, Battle escrow, Fusion custody, Graveyard, and
   resurrection behavior and gas against this Fix-1b baseline.

The deliberate authority cleanup in Fix-1b removes the legacy mint/Fusion role
fallback branches, which is a measured size reduction candidate already applied
without moving permanent NFT invariants out of BinderData.
