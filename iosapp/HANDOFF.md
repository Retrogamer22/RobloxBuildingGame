# BuildBlox Admin — iOS App Build Spec / Handoff

This is the bridge doc between the Windows Cowork session (which slimmed the Cloudflare
worker and gathered the design + API details) and the Mac Cowork session (which builds
the actual iOS app in Xcode). Everything the Mac session needs is captured here.

---

## 1. What we're building

The old admin dashboard was a **single Cloudflare Worker** that served a ~4,000-line
embedded HTML/CSS/JS single-page app at `GET /`. We split that in two:

- **Worker = data-only API.** All the JSON endpoints stay; the embedded HTML is gone.
  `CloudFlareWorkerCode.txt` went from 7,105 → 3,064 lines. The original (with the full
  HTML/CSS/JS dashboard) is preserved at `CloudFlareWorkerCode_BACKUP_2026-07-03.txt`
  and in git history — that's the visual reference for the redesign.
- **iOS app = native SwiftUI client.** It calls the worker's JSON endpoints directly and
  renders the dashboard natively (Swift Charts for graphs).

### v1 scope (decided): monitoring + analytics, read-only
Ship a working read-only app first. No destructive actions in v1.

**v1 tabs:** Analytics (live players + charts), Players, Economy, Feedback (view only).
**Phase 2 (later):** Commands (broadcast/kick/ban), Gifts, Feedback replies, Chat moderation.

---

## 2. Backend API reference

- **Base URL:** `https://buildblox.gardinert4.workers.dev`
- **Auth:** every endpoint below requires header `X-Admin-Token: <token>`. A missing/wrong
  token returns `401 {"error":"Unauthorized"}`. Store the token in the **iOS Keychain**;
  never hardcode it in source.
- **Common query params:** `?target=prod` (or `dev`) and `?days=N` where relevant.
- **CORS:** the worker already sends permissive CORS headers, but a native app isn't
  subject to CORS anyway.

### v1 endpoints (GET) with response shapes

| Endpoint | Params | Response shape (top-level keys) |
|---|---|---|
| `/stats/live` | `target` | `{ target, placeId, serverCount, playerCount, players[], servers[] }` |
| `/stats/daily` | `target,days` | `{ target, days, rows[] }` — DAU split new/returning by date |
| `/stats/concurrency` | `target,days` | `{ target, days, rows[] }` |
| `/stats/daily-peak` | `target,days` | `{ target, days, rows[{date, peak, servers}] }` |
| `/stats/retention` | `target,days` | `{ target, days, rows[] }` — day-N retention by cohort |
| `/stats/session-length` | `target,days` | avg completed session length |
| `/stats/active` | `target,days` | `{ target, days, current, rows[] }` — DAU/WAU/MAU |
| `/stats/economy` | `target,days` | coin faucet vs sink `{ target, days, ... }` |
| `/stats/plus` | `target,days` | `{ target, days, taps, uniqueTappers, prospectTaps, purchases, originPurchases, conversionRate, rows[], sources[] }` |
| `/stats/playerbase` | `target,days` | `{ target, days, acquisition[], churn{active1,active7,active14,active30,lapsed_7_14,lapsed_14_30,lapsed_30p,reactivated7}, lifetime{total,avgDays,avgSessions,powerUsers} }` |
| `/stats/heatmap` | `target,days` | `{ target, days, cells[] }` — play-time-of-day heatmap |
| `/stats/milestones` | `target` | `{ target, joined, rows[{milestone, users}] }` |
| `/stats/servers` | `target` | `{ target, servers[{server_id, player_count, uptime_seconds, last_heartbeat}] }` |
| `/blocks/top` | `target` | latest top-block popularity snapshot |
| `/leaderboards` | `target` | `{ target, streak[], likes[], playtime[], ageSeconds }` |
| `/feedback` | `target, filter=inbox` | `{ target, filter, rows[{feedback_id, user_id, username, display_name, text, spam, ...}] }` |
| `/thumbnails` | `userIds=a,b,c` | `{ thumbnails: { "<userId>": "<imageUrl>" } }` — Roblox avatar proxy |

Other read endpoints available (phase 2 / extra charts): `/stats/shop`, `/stats/shop-detail`,
`/stats/coinflow`, `/stats/streaks`, `/stats/plus-quality`, `/stats/block-trends`,
`/stats/engagement-trends`, `/stats/slots-trends`, `/stats/slots`, `/stats/session-split`,
`/stats/onboarding`, `/stats/daily-claims`, `/stats/chat`.

### The `/stats/live` object in detail (the hero screen)
```
{
  "target": "prod",
  "placeId": "88286023804686",   // for a roblox.com deep-link "Join" button
  "serverCount": 3,
  "playerCount": 27,
  "players": [ /* every online player's name across all servers */ ],
  "servers": [ { server_id, player_count, players_json, uptime_seconds, last_heartbeat } ]
}
```
Live data goes stale after ~60s server-side; the web app polled `/stats/live` every 15s.
Mirror that: poll every 15s while the Analytics tab is foregrounded.

> **To get exact field names for each `rows[]` element**, the Mac session should read the
> matching `handleStats*` function in `CloudFlareWorkerCode.txt` (the SQL `SELECT` lists the
> column names, which become the JSON row keys). This spec lists the top-level shape; the
> row-level columns are best read straight from the SQL to avoid drift.

---

## 3. Design system (ported from the dashboard CSS)

Dark, "developer console" aesthetic: near-black background with a faint blue grid, glassy
cards, one blue accent, semantic red/amber/green. Preserve this exactly.

### Color tokens (hex from the original `:root`)
```
bg            #07090F   app background (near-black)
bgElevated    #0D111C   elevated surfaces / nav bar
bgCard        #111624 @ 53% alpha (0x88)   glassy card fill
bgCardSolid   #111624   solid card
bgInput       #161C2E   inputs
bgInputFocus  #1A2238
border        #1F2740
borderBright  #2A3550
text          #E8ECF5   primary text
textDim       #7A83A0   secondary
textFaint     #4A5170   tertiary / axis labels
accent        #5BB0FF   blue — links, active tab, primary series
danger        #FF6464   red
warning       #FFC266   amber
success       #5FC97A   green
gridLine      rgba(91,176,255,0.04)   faint chart/background grid
```

### Typography (pick the closest system fonts, or bundle the originals)
- **Display / headings:** Bricolage Grotesque (600–800). Fallback: SF Pro Rounded / bold system.
- **Body:** Manrope (400–700). Fallback: SF Pro Text.
- **Mono / numbers:** JetBrains Mono. Fallback: SF Mono. Use mono for all metric values
  (player counts, revenue, etc.) — it's a big part of the console feel.

### Shape
- Card radius **10px**, large radius **14px**. Cards have a 1px `border` stroke and a subtle
  inner glow on the accent color for active/hover states.

### Layout notes from the original
- Top row: a segmented **target switch** (prod/dev) styled like a pill; prod is neutral,
  switching to dev tints the chrome (a visible "you're looking at dev" cue).
- A **live pulse** indicator (dot + "live" text) that animates while polling, pauses on demand.
- Cards are arranged in a responsive grid; on a phone that's a single vertical column.
- Charts were hand-drawn SVG line/area charts with a hover guide line + tooltip. In SwiftUI
  use **Swift Charts** (`LineMark`/`AreaMark`/`BarMark`) — don't reimplement SVG.

---

## 4. Screen map (SwiftUI)

Root: `TabView` with 4 tabs for v1.

1. **Analytics** (`AnalyticsView`) — hero live-players card (poll `/stats/live` every 15s),
   then chart cards: Peak Live Players/Day (`/stats/daily-peak`), DAU new vs returning
   (`/stats/daily`), Active DAU/WAU/MAU (`/stats/active`), Concurrency (`/stats/concurrency`),
   Retention cohorts (`/stats/retention`), Block popularity (`/blocks/top` + `/stats/block-trends`).
2. **Players** (`PlayersView`) — `/stats/playerbase` (acquisition, churn buckets, lifetime),
   `/stats/milestones`, `/leaderboards` (streak/likes/playtime top lists with avatars via `/thumbnails`).
3. **Economy** (`EconomyView`) — `/stats/economy` (faucet vs sink), `/stats/plus` funnel
   (taps → purchases → conversion), `/stats/shop` / `/stats/shop-detail`.
4. **Feedback** (`FeedbackView`) — list from `/feedback?filter=inbox`, each row shows avatar,
   username, text, spam flag. Read-only in v1 (reply is phase 2 via `POST /feedback/reply`).

A shared **`AppState`** holds the current `target` (prod/dev) and the admin token; a global
target switch in the toolbar re-fetches the visible screen.

---

## 5. Suggested Xcode project structure

```
BuildBloxAdmin/                 (iOS app target, SwiftUI lifecycle, min iOS 16)
  BuildBloxAdminApp.swift       @main, injects AppState
  AppState.swift                target + token (Keychain), observable
  Theme.swift                   colors, fonts, card modifier  ← starter provided
  APIClient.swift               async URLSession + X-Admin-Token  ← starter provided
  Models.swift                  Codable structs per endpoint    ← starter provided
  KeychainStore.swift           save/load the admin token
  Views/
    RootTabView.swift
    AnalyticsView.swift
    PlayersView.swift
    EconomyView.swift
    FeedbackView.swift
    Components/                 MetricCard, ChartCard, LivePulse, TargetSwitch, AvatarView
```

Starter files for `Theme.swift`, `APIClient.swift`, and `Models.swift` are in
`iosapp/BuildBloxAdmin/`. They compile stand-alone and lock in the palette + networking +
the token-header auth so the Mac session can start from a known-good base.

---

## 6. Mac setup steps (Cowork + repo)

1. Install the **Claude desktop app** on the Mac and sign in; enable **Cowork mode**.
2. Clone the repo on the Mac:
   `git clone https://github.com/Retrogamer22/RobloxBuildingGame.git`
3. In Cowork, connect that cloned folder as a working folder.
4. Point Cowork at `iosapp/` and this `HANDOFF.md`. Ask it to create a new Xcode project
   named **BuildBloxAdmin** (SwiftUI, iOS 16+) and pull in the starter files.
5. Set your **Apple ID / signing team** in Xcode (Signing & Capabilities) so it runs on a
   device/simulator. Enter the admin token once at runtime (stored in Keychain).

> The worker never needs the Mac — deploy it by pasting `CloudFlareWorkerCode.txt` into the
> Cloudflare dashboard Workers editor. The `X-Admin-Token` the app sends must equal the
> worker's `ADMIN_TOKEN` secret binding.

---

## 7. Where the original design lives
- `CloudFlareWorkerCode_BACKUP_2026-07-03.txt` — the full pre-slim worker incl. the entire
  HTML/CSS/JS dashboard. Open it to see exact markup, class styles, chart drawing, and
  interaction details for anything this spec summarizes.
- Git history of `CloudFlareWorkerCode.txt` also contains it.
