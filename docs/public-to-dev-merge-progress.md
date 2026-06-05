# Public → Dev feature-merge progress

Automated hourly task `match-public-features-to-dev-folder`. Repo: `H:\Documents\RobloxBuildingGame`.

**Goal:** find features added in `public/src` scripts and merge them into `dev/src` *appropriately*, without breaking dev-only features. A few files per run; this file records what has been combed so later runs continue.

**Direction:** public → dev. `dev` is the active fork (has Fire / Lava / Nether / TextBlock / DebugTrace systems that `public` lacks). `public` has its own additions to port back. **Edit `dev/` only — never edit `public/`.** Disk writes under sync can be silently reverted, so re-verify with a fresh read.

**Method:** for each common file run `diff dev public`. If public ⊇ dev (only additions + doc-line changes that supersede dev, no real dev-unique logic lost) → safe wholesale copy. Otherwise port additive blocks surgically and preserve dev-unique logic. Match each file's existing line endings (some LF, some CRLF).

---

## Done — combed & merged

**Run 1 (2026-06-04)** — the "reward-set gifting" admin feature, ported as a unit:

- `Server/AdminCommandHandler.server.luau` — added public `giveset` / `givesetall` worker commands + lazy `CoinManager` require. Dev had no unique logic here; now byte-identical to public.
- `Server/Modules/CoinManager.luau` — added public `GrantRewardSet()` and the daily-reset timezone offset (`DAILY_RESET_UTC_OFFSET_HOURS = -6`). Dev-only `GrantMod` / `ownedMods` system left intact.
  - **Deviation from public (intentional):** public's `GrantRewardSet` calls `SavePlayerData` *without* first setting `DataDirty`, but dev's `SavePlayerData` early-returns when the player isn't dirty — so a verbatim port would not persist the grant. Added `DataDirty[userId] = true` before the save, matching dev's existing `GrantMod` convention. This fixes a latent bug rather than copying it.
- `Server/BetaAdminCommands.server.luau` — added public `/listsets`, `/giveset`, `/givesetall` chat commands + lazy `CoinManager` / `RewardSetPicker` require. Dev had no unique logic here; now byte-identical to public. Depends on `CoinManager.GrantRewardSet` (merged above).

All three re-verified on disk after writing.

**Run 2 (2026-06-04)** — cleared three small comment-only files + investigated/corrected two mislabeled queue entries. No functional features were portable this run; the value was avoiding two wrong ports.

- `Client/WorldLoadingScreen.client.luau` — public only expands one comment (clarifies ChunkLoadingScreen handles the chunk-place case so the two screens never stack). No dev-unique logic. Wholesale-copied → byte-identical to public.
- `Server/LikesHandler.server.luau` — sole diff was mojibake in a comment (dev had `ΓÇö` / bytes `ce 93 c3 87 c3 b6` where public has a proper `—` em-dash, `e2 80 94`). No dev-unique logic. Wholesale-copied → byte-identical, mojibake fixed.
- `Shared/RewardBlockPresets.luau` — same mojibake-only diff on two comment lines (57, 372). Wholesale-copied → byte-identical, mojibake fixed.
- **`Shared/Config/CoinConfig.luau` — investigated, deliberately NOT ported.** Only diff is `StreakExpiryDays` (dev=1, public=2). The comment *in both files* states the value was intentionally changed 2→1 ("Previously 2, which gave ~24-48h of slack... that overlap is removed so it behaves like a true daily streak"). Public's `2` contradicts its own comment and is the stale/reverted value; dev's `1` is correct. Porting public here would have re-introduced the old behavior. **Left dev as-is; removed from queue.**
- **`Server/AnalyticsHandler.server.luau` — investigated, nothing to port.** Only diff is a trailing space public added after `require(analyticsModule)`. Dev is cleaner. **Left dev as-is; removed from queue.**

All three copied files re-verified byte-identical on disk after writing (sync had not reverted).

---

## Remaining queue (common files where public differs; `pub-added / dev-only` line counts)

Large — both sides diverged, need careful per-hunk merge:
- `Shared/GlassPlacement.luau` (+320 / -87)
- `Server/Modules/ChunkStreamManager.luau` (+272 / -279)
- `Client/InventoryController.client.luau` (+221 / -74)
- `Client/PlusController.client.luau` (+200 / -83)
- `Shared/BlockPresets.luau` (+195 / -81)
- `Client/VineClimber.client.luau` (+607 / -607) — likely near-total rewrite both sides; inspect closely
- `Shared/RewardSets/CandyBlocks/Manifest.luau` (+177 / -177)
- `Client/BuildingController.client.luau` (+109 / -245)
- `Server/PlotManager.server.luau` (+75 / -363) — mostly dev features

Smaller:
- `Client/BlockInteractionController.client.luau` (+15 / -2)
- `Client/ChunkLoadingScreen.client.luau` (+9 / -21)
- `Client/CameraController.client.luau` (+3 / -69)
- `Client/SaveLoadUI.client.luau` (+13 / -94)
- `Server/Modules/ChunkTerrainManager.luau` (+26 / -27)
- `Server/Modules/GrassSpreadManager.luau` (+6 / -103) — mostly dev
- `Server/Modules/SnowyGrassManager.luau` (+3 / -5)
- `Server/SaplingHandler.server.luau` (+19 / -19)
- `Server/ToolHandler.server.luau` (+1 / -357) — mostly dev
- `Shared/Config/BiomeConfig.luau` (+3 / -3)
- `Shared/Config/ChangelogConfig.luau` (+5 / -14)
- `Shared/WaterSystem.luau` (+4 / -6)

Cleared in Run 2 (done above): `Client/WorldLoadingScreen.client.luau`, `Server/LikesHandler.server.luau`, `Shared/RewardBlockPresets.luau` (copied), `Shared/Config/CoinConfig.luau`, `Server/AnalyticsHandler.server.luau` (no-port, dev correct).

Nothing to port (public adds nothing dev lacks; dev only grew):
- `Server/Modules/TerrainGenerator.luau` (+0 / -863)
- `Shared/BlockCollision.luau` (+0 / -2)
- `Shared/BlockSpatialIndex.luau` (+0 / -10)
- `Shared/PlotSerializer.luau` (+4 / -180) — re-check the +4

---

## Special cases

- **Whole "Paint" feature exists only in public** (dev lacks it): `Client/PaintMixerUI.client.luau`, `Server/PaintHandler.server.luau`, `Shared/PaintCanVisual.luau`. Candidate to add to dev wholesale — but first confirm dev wants it and that supporting deps (remotes, presets) exist. **Not yet done.** Several other files' public additions are *blocked on this decision* — see next item.
- **CORRECTION (Run 2): `BlockHandler.server.luau`, `SaveManager.server.luau`, `MegaPlotSaveManager.server.luau` are NOT newline-only — they have substantial real public additions.** The prior "0 real line changes" note was wrong. Their public-only additions cluster into three dependency-blocked groups, so none were ported this run:
  1. **Paint Mod** — `local PaintCanVisual = require(...PaintCanVisual...)` plus paint-can placement and painted-block save/load restore. Depends on the public-only `Shared/PaintCanVisual.luau` module and `BlockPresets.IsPaintCan`. **Blocked on the Paint-feature decision above** — porting the require alone would `require(nil)` in dev (module absent) and break block placement/saving. Do Paint as one unit or not at all.
  2. **Glass placement/culling** — `GlassPlacement.IsAnyGlass / IsColoredGlass / NormalizeGlassMaterial / StyleColoredGlass / RefreshGlassFaces / CullAllGlass / IsCullableLeaf` calls throughout place + save + load. **Blocked on `Shared/GlassPlacement.luau` (large-queue item, +320/-87) being merged first** — these handlers can only adopt the calls once dev's GlassPlacement exposes those functions.
  3. **Leaf-tint-before-parent** (BlockHandler) — `BiomeConfig.GetRandomizedTintedLeafColor` / `TintLeaves` applied pre-parent. Depends on `BiomeConfig` (queue, +3/-3); minor.
  - SaveManager/MegaPlotSaveManager also contain a **self-contained DataStore backup+recovery system** (`getSlotBackupKey`, backup write on save, backup read on load when primary looks wiped) that has NO missing-module dependency and could be ported independently — but it's interleaved with the glass/paint load hooks above, so port it as a careful surgical hunk, not a wholesale copy. Worth doing in a future run.
  - Recommended order: (1) merge `GlassPlacement.luau`, (2) decide Paint feature, then (3) revisit these three handlers.
- Files only in `dev` (Fire / Lava / Nether / TextBlock / DebugTrace, etc.) are dev features — leave alone.
