# Architecture

A short map of where things live, what owns what, and which rules are enforced by
machine rather than by memory. Keep it current when a boundary moves.

## The ladder stack

```
src/shared/AuraLadder.luau        DATA      the 12 declarations + tier bands. No functions.
src/shared/AuraRegistry.luau      INDEX     derived registry, tier policy, integrity guard, public API
src/shared/AuraMaterializer.luau  ADAPTER   declarative config -> Roblox datatypes
```

One direction only: `AuraLadder -> AuraRegistry -> AuraMaterializer`, and
`AuraRegistry` is what every consumer imports.

**Add or change an aura by editing `AuraLadder.luau` only.** It is pure data: no
branching, no Roblox access, and `tier`/`tierColor` are deliberately absent from
`AuraDeclaration` so a rung's label cannot be authored out of sync with its odds.

**Renderers target `AuraMaterializer`'s `MaterializedAura` contract**, not the
registry's internals. That is the seam a second renderer can implement against.

## Single sources of truth

| Fact | Owner |
|---|---|
| Aura odds, palettes, VFX numbers | `AuraLadder.Auras` |
| Tier names and colours | `AuraLadder.TierBands` |
| Derived `config.tier` / `config.tierColor` | `AuraRegistry.tierBandFor` |
| Pity window, soft-pity ramp, Rare+ floor | `RollMath.CONSTANTS` |
| Session streak curve (+5% luck per level, 15 levels) | `StreakMath.Constants` |
| Time in this server | `PlayerState.sessionStartClock`, set at join |
| A player's total luck | `RNGService.getLuckMultiplier` — perks x streak, one place |
| What a rendered aura looks like | `AuraMaterializer.MaterializedAura` |
| Registry index, `ORDER`, count | `AuraRegistry` (built once at load) |
| Materialized instances | `AuraMaterializer` cache, keyed by aura id |
| Owned inventory / equipped aura | `RNGService` server state; client mirrors it read-only |

The client never rolls and never derives odds: it renders what the server sends.

## Invariants that are checked, not assumed

`lune run test_rollmath` (78 checks) enforces, among others:

- every consumer's `config.<field>` reads exist on all 12 auras, extracted live
  from the consumer sources — the "frozen renderer keeps working" guarantee;
- every field `MaterializedAura` promises is actually assigned, so no `nil`
  reaches a renderer;
- the adapter is **executed** for all 12 auras against stubbed datatypes, so a
  declared-but-unmapped value (an unknown `shardShape`, say) fails the run
  instead of reaching a renderer as `nil`;
- tier metadata equals `TierOf(rarity)` for every rung, and all 12 tiers differ;
- 21 power metrics escalate monotonically along the ladder (transparency metrics
  must *not* rise), so a rarer rung can never look weaker than a cheaper one;
- no rung relies on being clipped by a VFX clamp or an engine cap.

`AuraRegistry` additionally guards at load time: duplicate rarity, or two rungs
deriving the same tier, raises immediately with both ids named.

`lune run test_perks` (145 checks) enforces the monetization and progression
side, including the trap that matters most there: **a placeholder id must never
resolve to a real perk.** Every id is `0` until published, so `FindProductById(0)` and
`FindPassById(0)` return `nil` - without that guard a stray receipt for id 0
would grant the first product in the list. It also pins that one potion pays for
exactly one roll across a sequence, that a malformed entry degrades to "no
bonus" rather than zero luck, that `RNGService` asks `PerkService` for all five
perk decisions, that only `ShopService` names `MarketplaceService`, and that no
client file requires a server module. Those source checks match calls *with*
their arguments: a negative control showed a plain name match happily accepted
`PerkService.HasFastRollDisabled`. Its reachability check collects references
from `require` / `WaitForChild` / `loadSibling` arguments rather than raw text,
because raw text let a module mentioned only in a comment count as reached. And
every semantic source check reads comment-stripped source, for the same reason: a
control deleting the streak from the luck product stayed green until the check
stopped being satisfiable by the words "streak dropped" in a comment.

On the progression side it executes the streak curve (monotonic and strictly
rising at every level boundary, identical shape on the live and Studio clocks,
total for NaN/negative/infinite durations, capped rather than unbounded) and pins
the pity copy to the mechanic: the primary line's milestone really is x2 at
`SoftPityInterval()`, the guarantee really is at `HardPityRolls()`, and the two
are asserted to be different rolls.

## Deliberate non-couplings

Do not "fix" these without reading why:

- **`RollMath.hardPityMinRarity` (50) is not read from `TierBands`.** The pity
  guarantee is gameplay policy and the band is presentation policy; coupling them
  would let a cosmetic tier rename silently change pity behaviour. The UI
  *label* is composed from both instead (`MainUI` renders
  `TierOf(HardPityMinRarity())`), so the one user-visible string cannot go stale.
- **`trailLifetime` is not in the monotonic metric set.** Tail length is a theme
  (Ember's long comet vs Frostbite's slow drift), not a power dial; the guard
  covers the metrics a player reads as strength.
- **`cutsceneIntensity` saturates at 1.0.** Mythic, Ascendant and Sovereign share
  the maximum, so the top three are separated by shards, particles and light
  rather than by cutscene punch.

## Runtime seams

Dual-runtime sibling requires (Roblox by instance, Lune by relative path) live in
`AuraRegistry` and `AuraMaterializer`. Cross-module *types* are pulled with a
type-only `typeof(require(...))` annotation, which is erased before execution —
verified, not assumed: the call count stays 0.

## The monetization layer

```
src/server/MonetizationConfig.luau  DATA      pass/product ids, every perk number, Test Mode policy
src/server/PerkMath.luau            POLICY    how perks combine; how a potion is spent (pure Luau)
src/server/PerkService.luau         STATE     owned perks, Test Mode, server boost, VIP nametag
src/server/ShopService.server.luau  MARKET    display catalog, ownership polling, ProcessReceipt   [Script]
src/server/SaveBackend.luau         PERSIST   DataStore-or-memory policy + receipt claims
src/server/ServerRemotes.luau       PLUMBING  create-or-reuse remotes in ReplicatedStorage.Remotes
src/client/ShopUI.luau              VIEW      the shop panel: renders and asks, never decides
```

One direction only: `MonetizationConfig -> PerkMath -> PerkService -> RNGService`,
with `ShopService -> PerkService` for grants and `ShopUI -> (ShopService,
PerkService)` by remote. **`PerkService` never requires `RNGService`**, which is
what keeps the roll path the only reader and the perk layer the only decider.

**`ShopService` is a `Script`, not a `ModuleScript`.** It sets
`ProcessReceipt`, publishes its remotes and starts the ownership poll at load -
none of which happens to a module nothing requires. The first version of this
layer was a `ShopService.luau` module that *nothing required*: it would have been
silently dormant, the shop's remotes would never have existed, and `ShopUI` would
have failed on `WaitForChild`. Nothing in the toolchain can see that (Rojo copies
text, the compiler compiles it, the module is valid), so `test_perks` now asserts
that every remaining `ModuleScript` under `src/` is named by a `require`,
`WaitForChild` or `loadSibling` in some other file.

| Fact | Owner |
|---|---|
| Pass / product ids, prices-of-record, Test Mode policy | `MonetizationConfig` |
| How multipliers combine, and that a potion pays for exactly one roll | `PerkMath` |
| Luck multiplier | `PerkService.GetLuckMultiplier` (passes x potion x server boost) |
| Cooldown multiplier | `MonetizationConfig.passes.FastRoll` (0.6), served by `PerkService` |
| Auto-roll unlock | `PerkService.HasAutoRoll` |
| Potion charges | `PerkService`; spent only by `PerkMath.RollPotion`, called once per roll |
| Server-wide boost | `PerkService` (one clock, broadcast to everyone) |
| Pass ownership as Roblox reports it | `MarketplaceService`, asked only by `ShopService` |
| One-grant-per-purchase | `SaveBackend.ClaimReceipt` |
| What the shop shows | `ShopService` catalog (display) + `PerkState` (truth) |

`RNGService` holds `state.fastEnabled` as a *preference* and `PerkService` holds
the entitlement: the toggle can only engage a discount the server agrees exists.

## The session streak

```
src/server/StreakMath.luau   CURVE   levels, luck per level, the session clock policy (pure Luau)
src/server/RNGService.luau   STATE   sessionStartClock per player, folded into getLuckMultiplier
src/client/MainUI.client.luau VIEW   the streak line + bar, rendered from the server payload
```

A player earns passive luck for TIME SERVED in this server: one level per two
minutes (cap 15 levels = 30 minutes), +5% luck per level, so 1.00x at join and
1.75x at the cap. It is a staircase rather than a ramp on purpose — the counter
can visibly step, the bar can visibly fill, and the harness has exact boundaries
to assert.

Rules that are load-bearing:

- **Derived from the server's clock, never from a client claim.** The client
  never sends a streak value (`test_perks` asserts that no client file passes
  "streak" to a `FireServer`); it only reads `payload.streak`.
- **The server pushes it.** A 2-second loop re-publishes the state rather than
  letting the client count, because a client-side counter would be the client
  asserting its own luck.
- **One luck formula.** `Snapshot()` delegates to `LuckMultiplier()`; the streak
  is multiplied in only inside `getLuckMultiplier`, so the roll path stays the
  only reader and no second luck code path exists.
- **Not persisted.** Like auto-roll, the streak deliberately does not survive a
  rejoin: it measures presence in THIS server, not account age.
- **Studio runs the same curve 12x faster** (10s per level instead of 120s),
  purely so a playtest can watch it move. Same shape, same reward per level.

## The pity panel: what the copy means, and what it does not

The panel shows two countdowns because two different mechanics exist:

| Line | Mechanic | Numbers |
|---|---|---|
| Primary: "Rolls until Guaranteed 2x Luck: X/50" | soft pity — a deterministic x2 luck multiplier once the streak of non-Rare+ rolls reaches the interval, then a further step every interval | `RollMath.SoftPityInterval()` (50), ramp capped at `maxSoftPityStacks` |
| Second: "Rolls until Guaranteed Rare: X/100" | hard pity — the 100th consecutive roll draws only from rarity >= `HardPityMinRarity()` | `RollMath.HardPityRolls()` (100) |

**Deliberate reading of the vision line "Rolls until Guaranteed 2x Luck / Rare+:
X/50".** That phrasing describes two mechanics in one breath. The 50 is the
soft-pity 2x point and is literally a guarantee (the multiplier is a function of
the counter, not a dice roll); the Rare+ guarantee is the 100-roll window. **No
threshold or odds value was changed**: `RollMath`'s 50 and 100 are untouched, and
`test_perks` asserts that the two numbers differ, that the guarantee is real at
100 and not at 50, and that the primary line's milestone really is x2. If a later
pass decides the vision meant a hard guarantee at 50, that is a balance change to
`RollMath.CONSTANTS` — not a relabel of this panel — and the harness will fail
until the copy is updated with it.

Both numbers are read from `RollMath` in the UI (per site, not by counting
occurrences), so moving the window cannot leave a stale "50" on screen.

## Going live (replacing the placeholders)

Every `id` in `MonetizationConfig` is `0`, meaning unpublished. Create the passes
and products on the Roblox site, paste the ids, republish. No other file changes,
and until then the shop says `NO ID YET` instead of prompting id 0.

## What only Studio can prove

`lune run test_perks` (160 checks) executes the pure policy - including the whole
streak curve and the pity counter's two panel states - and scans the wiring, but
there is no Roblox runtime here. Still to be seen in Studio Play mode:

Build the place from the game-source-only project first: `rojo build
playtest.project.json -o build/RNGIdleAuraPlaytest.rbxlx`. `build/` still holds a
pre-streak build (it shows the old single pity line), and `default.project.json`
would additionally embed the `Visuals/` workstream mid-edit, so playtest from the
`playtest` build.

- a real purchase prompt and a real `ProcessReceipt` delivery (idempotency across
  redelivery is proven only for the claim guard, not for Roblox's delivery);
- `UserOwnsGamePassAsync` answering at all (it fails silently in an API-disabled
  session by design - ownership simply stays as it was);
- the VIP nametag replicating to a second player;
- the boost countdown as every player sees it;
- fast-roll / auto-roll being *refused* for a player who owns neither pass;
- the streak counter visibly stepping, its bar filling and resetting on a level
  up, and the `Luck: X.XXx` stat stepping with it at the boundary;
- the pity panel across a real roll: the primary line's counter advancing and
  flipping to "2x Luck ACTIVE", the guarantee line counting to 100, the notch and
  the bar agreeing, and the counter resetting on a Rare+ pull.

## Out of scope / owned elsewhere

`Visuals/` is a separate workstream (mapped to `ReplicatedStorage.Visuals`). It is
excluded from `syntax_check` and from the contract scan precisely because it may
be mid-edit. **Open risk:** if one of its modules also renders `EquippedAura`,
two renderers draw the same aura. Keep ladder work additive so it behaves
correctly under either, and check for a second owner before adding VFX.

**Second open risk, same layer:** `Visuals/HUD.luau` builds a top bar whose pity
label is a hardcoded `"Rolls until Guaranteed Rare: 0 / 100"` that nothing
updates. It is dormant today - only `Visuals/init.luau` re-exports it and no
client script mounts it - but mounting it would put a second, frozen pity panel
beside the live one in `MainUI`. Whoever mounts it should either read
`payload.hardPityRolls` from the same server payload or delete the label.
