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
| What one delete removes (and when it refuses) | `InventoryMath.RemoveOne` |
| Whether a pull is kept, dropped or deleted | `AuraFilter.Decide`, called only from `RNGService.resolveRoll` |
| The filter's selectable rungs | `AuraFilter.Rungs(AuraRegistry)` — the ladder itself |
| The events, their duration, their multiplier, their themed rung ids | `BiomeConfig` (data only) |
| Which event is running, and how long is left | `BiomeMath.At(elapsed)` — pure, one call site in `RNGService` |
| The themed rungs an event favours, resolved against the ladder | `BiomeMath.Boosts(AuraRegistry)`, once at load |
| The 3x itself | the biome factor in `RollMath.buildPool`, reached through the one `SelectAura` |
| The moment the cycle started | `BIOME_EPOCH_CLOCK`, set once at load |
| Where the Luck Shrine is, its shape, and what standing in it is worth | `ShrineConfig` (data only) |
| Whether a point is inside it; what that does to a cooldown | `ShrineMath.Contains` / `ShrineMath.ComposeCooldown` — pure, one call site in `RNGService` |
| Whether a PLAYER is inside it | `RNGService.shrineSampleFor` — a server read of that player's own character |
| Any roll cooldown, ever | `ShrineMath.ComposeCooldown`, reached only through `RNGService.cooldownFor` |
| The Top Rollers score: how both numbers fit in one integer | `LeaderboardMath.Encode` / `Decode` |
| Board order, tie-breaks and size | `LeaderboardMath.Rank` / `Merge` |
| The stored board, and which store it is on | `SaveBackend.GetOrdered` — OrderedDataStore, or memory without one |
| Whether the board has actually been read | `RNGService.leaderboardReady`, set only in `refreshLeaderboard` |

The client never rolls and never derives odds: it renders what the server sends.

## Invariants that are checked, not assumed

`lune run test_rollmath` (118 checks) enforces, among others:

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
- no rung relies on being clipped by a VFX clamp or an engine cap;
- the biome cycle, walked second by second over three full periods against a
  schedule written out independently: the event changes exactly on its boundary
  and nowhere else, every early or hostile clock still yields a finite,
  in-range countdown, and two callers asking about the same instant agree;
- the biome factor, measured from `RollMath`'s own table: every themed rung is
  exactly 3x its unthemed neighbours (under luck, under soft pity, under hard
  pity), every unthemed rung moved by the same single factor, the distribution
  still sums to 1, the pool's floor rung is boosted too, and 40,000 executed
  draws match the boosted table rung by rung;
- the themed sets partition the ladder: all 12 rungs themed, none by two events,
  each rung resolved to the ladder's own label and odds.

`AuraRegistry` additionally guards at load time: duplicate rarity, or two rungs
deriving the same tier, raises immediately with both ids named.

`lune run test_perks` (364 checks) enforces the monetization, progression,
biome, shrine and board side, including the trap that matters most there: **a placeholder id must never
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

## The auto-filter and the inventory drawer

```
src/server/AuraFilter.luau      POLICY  modes, ladder rungs, keep/skip/delete (pure Luau)
src/server/InventoryMath.luau   RULE    "delete one copy" and its refusals (pure Luau)
src/server/RNGService.server.luau STATE  filterMode/filterRarity, the delete + filter remotes, the roll path
src/client/InventoryUI.luau    VIEW    the drawer: collection grid, equip/delete, the filter control
```

Two things a player can use: the drawer lists every rung (owned or not) and lets
them equip or delete one copy of what they own, and "Auto-Skip / Auto-Delete
below [Rarity]" keeps an AFK session from filling up with junk.

**The options ARE the ladder.** `AuraFilter.Rungs(AuraRegistry)` turns
`AuraRegistry.ORDER` into one option per rung, and the server sends that list in
the state payload. The panel renders those options and has no tier list of its
own; a threshold that is not a rung is refused by the server, so 499 cannot sit
between two rungs. `test_perks` asserts that no server or client file spells a
tier name as a literal, which is what would be needed to hardcode a second list.

**"Below" is strictly below.** A pull at exactly the chosen rung is KEPT (both
modes), and the panel's copy says so. `off` keeps everything and is the default.

**Where the filter sits in `resolveRoll` is the whole design:** after the draw,
the rarity tally, the pity bookkeeping and the potion spend, and before anything
touches the inventory. So a suppressed pull advances pity and telemetry exactly
like a kept one (the filter cannot make the guarantee cheaper), and it never
enters the inventory. A filtered pull is also NOT a reward: it skips the reveal
and the cutscene, cannot become `rarestAura` or the equipped aura, and is
announced instead of vanishing - every manual pull via the HUD toast, an
auto-rolling session every 25th via the same toast plus the drawer's live tally.

**Delete removes exactly one copy and refuses everything else.** The id is
checked against the ladder, ownership is re-read from server state, and the
arithmetic is `InventoryMath.RemoveOne` (whose edges - nothing owned, one copy
left, a fractional or non-numeric count - are executed by the harness). Deleting
the last copy of the equipped aura clears the equip; `rarestAura` deliberately
survives, because it records the rarest thing ever FOUND rather than what is
currently in the inventory.

**The filter persists like the rest of the state**: it rides `toSavedData` into
the same `SaveBackend` (DataStore, or the in-memory fallback when Studio has no
API access), is re-validated against the ladder on load so a save written before
a ladder change cannot restore a rung that no longer exists, and a change is
written after an 8s debounce - a stepper fires one request per click, and Roblox
refuses writes to the same key inside ~6s. `PlayerRemoving` saves immediately,
so a player who changes it and leaves at once still keeps it.

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

## Time-gated biome events

```
src/server/BiomeConfig.luau        DATA    the three events: duration, multiplier, accent, themed rung ids
src/server/BiomeMath.luau          RULES   the schedule (pure, given an elapsed time) + rung resolution
src/shared/RollMath.luau           WEIGHT  the boost as one more factor in the single weight vector
src/server/RNGService.server.luau  STATE   the epoch, the per-roll snapshot, the payload, the telemetry
src/client/MainUI.client.luau      VIEW    the strip: event, countdown, themed rungs, reveal badge
```

Every 300 seconds the server moves to the next event, in a fixed order, off the
clock it set once at load. Starfall (1 in 1,500 -> 1 in 1,000,000), Blood Moon
(the floor through the violet dark to coral ascension) and Void Eclipse (1 in 8
-> 1 in 500) each triple the WEIGHT of their own rungs. Four rules make it a
system rather than a decoration:

- **Server-owned, one clock.** `biomeNow()` is `BiomeMath.At(os.clock() -
  BIOME_EPOCH_CLOCK)`, and it is the only schedule read in the game. A player
  joining mid-event joins the event already running; two players asking at the
  same instant are told the same event. Nothing about the schedule comes from a
  client, and no remote carries a biome in either direction.
- **One selection path.** The event is an argument to `RollMath.SelectAura` -
  the single place a pull is decided - and enters as one more factor in the same
  weight vector luck and pity already flow through. No second selector exists,
  and no aura is named anywhere outside `AuraLadder` and `BiomeConfig`; both are
  asserted against the real source. It is read ONCE per roll, before the
  expectation and the draw, so a roll that lands on a switch is resolved entirely
  under one of the two events.
- **Weight, not probability.** Themed weights are multiplied and the pool
  re-normalises, so a themed rung is exactly 3x an unthemed one at the same
  starting weight whatever else is stacked on it. The harness checks that ratio
  to 1e-9 at four luck/pity points, checks that every unthemed rung moved by the
  SAME single factor (which is what "no others are boosted" means numerically),
  that the distribution still sums to 1, and re-checks it under hard pity where
  the pool is restricted to 8 rungs.
- **A boost is never a nerf.** A multiplier below 1, a non-number, a NaN or an
  absent one degrades to "no event"; an absurd one is clamped. The pool's FLOOR
  rung is exempt from luck but not from the event: Ember (1 in 2) is Blood
  Moon's, and the harness checks its 3x at luck 1 through 1e6.
- **The HUD is told, not asked.** The strip renders the payload, prints the
  server's own multiplier (never a literal), and interpolates the countdown
  between the 2-second pushes inside the tick loop that already exists. When the
  local countdown runs out it says `switching...` and waits for the server
  rather than naming the next event, because a client that guessed could name one
  the server is not running. An unknown or absent event blanks the strip instead
  of leaving the last one standing.

**What the world/atmosphere workstream is handed.** The state payload carries
`biome = { id, displayName, blurb, accent, multiplier, cycleSeconds,
secondsRemaining, progress, boosted }`, where `boosted` is the themed rungs
resolved from the ladder (`{ rarity, tier, auraId, displayName }`, ascending, and
an empty list rather than `nil` when a config gap leaves no rungs). That table is
the whole interface: whoever owns atmosphere drives Lighting from those fields
and needs nothing else. This codebase writes **no** world service - no file in
`src/` touches `Lighting`, `Atmosphere`, `Workspace` or `Camera` except the
pre-existing `ProceduralVFX` engine, and `test_perks` fails if another one starts.

**Balance is data.** A re-theming that keeps the sets disjoint and total is not
an error and no check fires; what IS checked is that every themed id exists on
the ladder, that the sets do not overlap, and that the three events favour
different bands (their cheapest rungs are 1 in 2, 1 in 8 and 1 in 1,500).

## The Luck Shrine and the Top Rollers board

```
src/server/ShrineConfig.luau        DATA    where the zone is, its shape, what it is worth, how often it is sampled
src/server/ShrineMath.luau          RULES   the zone test + THE cooldown composition (pure, no clock of its own)
src/server/LeaderboardMath.luau     RULES   the stored score, the order, the ties, the bound (pure, no store)
src/server/SaveBackend.luau         PERSIST one policy: OrderedDataStore when it works, memory when it does not
src/server/RNGService.server.luau   STATE   the server's read of a character, the cooldowns, the payload, the cadence
src/client/MainUI.client.luau       VIEW    the shrine row and the board panel, rendered from the payload only
```

### The shrine: +15% roll speed, and one place that decides a cooldown

The zone is a 30-stud disc at `(-46, 0, 46)` on the plaza floor, 26 studs tall,
with the rim **included**. Standing inside makes a player roll **1.15x as often**,
so a cooldown is DIVIDED by 1.15 (1.2s -> 1.043s). That reading is deliberate: the
vision says "+15% Roll Speed", which is a rate; a cooldown of "minus 15%" would
be a different, larger bonus (+17.6% speed) wearing the same word. Both forms come
from one config number; the payload carries the RATE, and a reader that wants the
cooldown form divides by it.

- **The zone test is an argument, never a claim.** `ShrineMath.Contains(region,
  position)` takes a position; `RNGService.shrineSampleFor` reads it from THIS
  player's own `HumanoidRootPart`, on the server. No remote carries a position, a
  zone or an "inside" flag in either direction, and no client file names
  `ShrineMath` or `ShrineConfig`, so a client cannot run the test at all - let
  alone assert its result. A player with no character (not spawned, mid-respawn,
  dead) samples as OUTSIDE: the bonus fails closed.
- **One cooldown point, three composed factors.** The old inline
  `BASE * (fastRoll and perk or 1)` is now `ShrineMath.ComposeCooldown({ base,
  passMultiplier, inShrine, minimum })` - base times the pass entitlement, over
  the zone's rate, clamped to a floor. `RNGService.cooldownFor` is the only
  caller on the roll path, and `test_perks` fails any file outside `ShrineMath`
  that starts doing cooldown arithmetic of its own.
- **The zone state a roll uses is read at that moment.** `cooldownFor` re-reads
  the character, so a player who teleports in is paid on the very next roll - the
  0.5s sampler drives the HUD and the attributes, never the mechanic.
- **It cannot stack.** `inShrine` is a boolean and there is exactly one
  division: ten players in the zone, or one player standing there for an hour,
  compose the same cooldown. Time is not an input to the arithmetic at all.
- **It cannot become a free roll.** The floor is 0.15s - the same `INVOKE_RATE_LIMIT`
  the client already lives under - so even a hypothetical stack that multiplies
  the cooldown to 0.01 lands on a real, server-accepted roll rather than on a
  claim the server would refuse.

**What the Visuals workstream is handed (the geometry contract).** The state
payload carries `shrine = { region, displayName, blurb, bonusPercent, accent,
inside, playersInside, speedMultiplier, secondsInside }`, and
`region` is `ShrineConfig.Region` verbatim: `{ name = "LuckShrine", shape =
"cylinder", origin = { x = -46, y = 0, z = 46 }, size = { x = 30, y = 26, z = 30
}, boundaryInclusive = true }`. The convention, so a pedestal can be built to the
numbers without measuring anything:

| `shape` | reads `size` as | sits on |
|---|---|---|
| `cylinder` | `x`/`z` = diameter (the wider is the radius), `y` = height | centre at `origin`, spanning `origin.y .. origin.y + size.y` |
| `box` | `x`/`z` = full extents centred on `origin.x`/`origin.z`, `y` = height | same |
| `sphere` | `x` = diameter | centre at `origin + (0, size.y / 2, 0)` |
| anything else | falls back to the cylinder test rather than throwing | same |

This codebase creates **no geometry for it**: no part, no model, no light, and no
`Lighting`/`Workspace` write (the same `test_perks` check that covers the biome
covers this). The zone is data and the numbers above are the whole interface.

### The Top Rollers board

Two numbers a player cares about, in ONE ordered integer:
`score = rolls * (maxRarity + 1) + rarestRarity`, so the board ranks by what you
DID and breaks a rolls-tie by what you FOUND. Worst case `1e9 * (1e6 + 1)` is
comfortably inside the `2^53` range an OrderedDataStore carries exactly - the
round trip is executed in the harness, not assumed.

- **Written on a cadence, never per roll.** An ordered store is write-rate
  limited; a per-roll write would be one per second per player. A score is
  submitted every 30s when it has moved, plus on a leave and at shutdown, and a
  REFUSED write does not update the session's copy - so it is retried rather
  than silently forgotten.
- **Read once at load, then every 20s**, so a session does not sit on
  `connecting...` for half a minute. The HUD is repainted by the streak loop that
  already pushes a full payload every two seconds; the board adds no second
  publisher.
- **The live half is merged, not cached.** The board a player sees is the stored
  one with this server's players folded in, so the numbers move while you play.
  One entry per user, the better score wins, and a live entry only breaks an
  EXACT tie (it carries the current name).
- **Nothing that has done nothing is on the board.** The live half is built from
  every connected player, so a joiner would otherwise hold a row reading
  `0 rolls` - and on a fresh server that row IS the whole board. A score of zero
  (or a damaged one: NaN, infinite, a string) cannot join `Merge` at all, which is
  also the only reason the panel's "no rolls yet" state is reachable. A NaN is
  not a cosmetic case: it makes the sort's comparator answer false both ways for
  one pair, and the engine raises on an inconsistent order function.
- **A leave or a shutdown only writes SETTLED state.** A joiner is put into
  `playerStates` immediately with an empty state, because they must be rollable
  before a DataStore read returns. A player who leaves inside that window would
  otherwise be saved as empty AND force-submitted as score 0 over their real
  board row, so both the leave path and `BindToClose` act only on state the load
  task has marked settled. (The same guard fixes a pre-existing bug: the leave
  path used to write that empty placeholder over the player's real save.)
- **A failed read is not an empty board.** `SaveBackend`'s ordered read answers
  `nil` - not `{}` - when the store cannot be read, and the reader then keeps the
  last board it had and does not claim readiness. Answering an empty table there
  would replace a good board with nothing during an outage and call it read.
- **Same persistence policy as the saves.** `SaveBackend.GetOrdered` returns an
  OrderedDataStore when one can be opened and an in-memory board when it cannot
  (Studio without API access, offline), so the whole no-DataStore path is
  executed by the harness - ordering, ties, the bound, the demotion guard and the
  end-to-end pipeline are all tested there.
- **NO FAKE ZEROS.** `leaderboardReady` is false until a read has actually
  happened, and the panel prints `connecting...` with every row hidden until it
  turns true. An unread board and an empty one are otherwise the same picture,
  and one of them is a lie about the whole server. A board on the memory fallback
  also says `session only`, so it cannot be mistaken for a global one.

**Decisions the vision left open** (also listed in the change report): the score
pairs total rolls with the rarest find and ranks rolls first; the bound is 10
entries, refreshed every 20s and written every 30s; a player who has not rolled
holds no row at all rather than a row of zeroes; a player with no rare find yet
shows `no rare find yet`; and the board is per-experience, not per-place.

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

`lune run test_perks` (364 checks) executes the pure policy - the streak curve,
the pity counter's two panel states, the whole filter matrix over the real
ladder, every delete edge, the shrine's zone test and cooldown arithmetic, and
the board's ordering/ties/bound on the no-DataStore fallback - and scans the
wiring, but there is no Roblox runtime here. Still to be seen in Studio Play mode:

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
  the bar agreeing, and the counter resetting on a Rare+ pull;
- the drawer: the card grid scrolling to all 12 rungs, the X appearing only on
  owned auras, a delete taking exactly one copy and the count updating from the
  sync, deleting the last copy of the equipped aura clearing EQUIPPED, and a
  stale grid (two clients, or a roll landing between click and sync) deleting
  nothing;
- the filter control: the stepper walking the 12 rungs, the mode buttons
  following the SERVER's answer rather than the click (a refused request must
  leave the panel unchanged), and a rejoin restoring the saved setting;
- an actual filtered auto-roll: junk never appearing in the grid, the tally
  climbing, the every-25th summary toast, pity still advancing, and the
  telemetry line's `filtered` count matching what the panel reported;
- the biome strip: the event name, the live countdown ticking down once per
  second, the themed rungs listed, the accent colour from the payload, the
  countdown crossing a real switch (the strip should read `switching...` for at
  most one sync interval and then show the next event on its own), a rejoin
  mid-event showing the same event as everyone else, and a roll on a themed rung
  badging its reveal while an unthemed one does not;
- the biome's effect on real pulls over five minutes: the themed rungs visibly
  more frequent, `biomeRolls`/`themed pulls` in the telemetry line matching what
  the session actually did, and `EquippedAura`/inventory behaviour unchanged by an
  event (the boost touches weights only);
- the biome text fitting the panel at 720p (the strip and the shrine row are the
  last 5 rows of a 196px panel, so a longer event name, rung list or player count
  must truncate rather than overlap the pull banner below it);
- the shrine row live: `connecting...` until the first sync, `+15% ROLL SPEED
  WHILE INSIDE` while outside, and `INSIDE` with a real countdown of seconds and
  the composed cooldown (`1.04s`) while standing in the zone - and the `N IN
  ZONE` figure agreeing with the number of characters actually there;
- the +15% as a MEASUREMENT, not a readout: stand in the zone and auto-roll, and
  the telemetry line's `cooldown Xs outside, Ys inside` plus the rolls/sec those
  imply should show exactly 1.15x. Then teleport in and roll IMMEDIATELY, without
  waiting for a sample - the first roll after the teleport must already be fast;
- two players in the zone at once: each gets their own 15% (and the `N IN ZONE`
  reads 2), while a player standing outside is unaffected - the zone must not
  behave like a server-wide boost;
- stepping just over the rim: the row must flip to outside at the boundary, and
  the cooldown must go back to the full value, with no stuck state;
- the board with a real OrderedDataStore: two sessions, two players on different
  servers, both appearing with the right rolls and rarest find, a tie between two
  players breaking the same way in both sessions, a rejoin not lowering a
  previous session's row, and the in-memory `session only` board being replaced
  by the stored one once API access is on;
- the two ways the board must stay silent: a player who joins and leaves before
  their save has loaded must not appear as a zero row or wipe their own, and a
  store read that fails (pull the API access mid-session) must leave the last
  board up rather than emptying it;
- the board panel's first frames: it must read `connecting...` with NO rows until
  the server says it has read one, then show the real rows - never a list of
  zeroes;
- the `Visuals` layer building the pedestal and the zone to the published region
  and the shove-out check agreeing with the server: a character standing inside
  the built zone is `inside` in the payload, and one standing outside it is not.

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

**The biome's half of this boundary is now explicit.** `BiomeConfig`/`BiomeMath`/
`RNGService` own the schedule, the boost and the payload; the HUD owns the strip;
and the world layer is handed `payload.biome` and nothing else. If the ruling
gives the world layer a different source for the weather, `payload.biome` is the
one table to keep in step, and `test_perks` will fail anyone who starts writing
Lighting from the biome code instead.

**The shrine's half of the same boundary is now explicit too**, and it is the
second worked example of the pattern: `ShrineConfig` owns the region as data,
`RNGService` publishes it on the payload and decides the per-player zone state
from a server read, `MainUI` renders it, and the world layer builds the geometry
to those numbers. The shrine sits on the plaza's south-west quadrant
(`(-46, 0, 46)`) - the one with no structure in it - and that was MEASURED, not
assumed: scanning every `Vector3.new` and `CFrame.new` literal in
`Visuals/World/Builder.luau` for the 15-stud disc around that point finds exactly
one hit, `Lawn_SW` (a flat 58x58 slab centred `(-48, 0.3, 48)`), and no CFrame at
all. The lawn's walkable top is y = 0.6, inside the zone's 0 .. 26 span. The
other quadrants hold the Stargazer's Spire deck `(48, -66)`, the Astral Waterfall
`(46, 46)`, the Mystic Grotto `(-54, -54)` and the spawn pavilion `(0, 68)`, so
nothing has to move for a pedestal to be built here.

**STILL NEEDS A RULING (any further HUD work).** The game now has two
candidate HUD owners (`src/client/MainUI.client.luau`, which owns the pity/streak
panel, the reveal and the bottom bar, and `Visuals/HUD.luau`, a second top bar)
and a world layer (`Visuals/World/*`, plus `Visuals/Server/WorldBootstrap`) that
this codebase never touches. Until someone decides which layer owns the HUD and
which owns the world, "where does the next panel go?" and "who is allowed to
write Workspace?" have two answers, and shrine work would pick one by accident.
The biome bullet is the worked example of doing it the other way: state goes on
the payload, and the layer that owns the world reads it. See the handoff note in
the change report.
