# Qualflare dashboard pane Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A *Qualflare dashboard* pane in Tern showing the project Overview from `qf <id> overview --days 7|28`: six cards, each with the headline (coloured against the project's target), the change against the previous period and a daily trend line.

**Architecture:** A pure page module `lib/dashboard.luau` (formatting, colours, the view for every state) and a second host block `qualflare.dashboard` in `host.luau` that runs `qf` and keeps state, like the launches pane. A window palette command opens it beside the focused pane; the two panes link to each other through the existing `qualflare-tern:` bridge.

**Tech Stack:** Luau, Tern plugin API (`tern.block`, `tern.ui`, `chart` kind `line`), the `qf` CLI.

**Spec:** the owner-approved design for the overview endpoint, `qf overview` and this pane (kept in the private api-service repo), part 3. `qf <id> overview --days N` prints `{window:{from,to,days}, buckets[], kpis[], warnings[], dataThrough}`; each KPI is `{key, label, unit, latest, previous, percentChange, trend, target, values[]}` with `unit` `percent|seconds|count`, `trend` `up|down|neutral|none`, nulls for missing numbers.

## Global Constraints

- KPI order as the endpoint sends it; keys `successRate`, `flakeRate`, `launchP90`, `automationRate`, `defectsOpened`, `launches`.
- Good direction: `successRate`, `automationRate` up; `flakeRate`, `launchP90`, `defectsOpened` down; `launches` neutral (never green/red).
- Headline colour (website `metric-card`): with a target and a latest value, `success` when it meets the target (`>=` for up-is-good keys, `<=` otherwise), else `error`; no colour without a target.
- Formats: percent with 1 decimal (`automationRate` 0 decimals) and `%`; seconds as `42s`, `4m 12s`, `1h 3m`; counts as `N today`; `null` → `–`.
- Change: `trend == "none"` → `no change` (muted); `percentChange == nil` → no badge; else `▲`/`▼` and the absolute percent with 1 decimal, tone by the good direction (`muted` for `launches`).
- Windows: 7 (default) and 28 days only.
- Every `qf` call is asynchronous through `lib/qf.luau`; a request counter drops stale answers.
- Strict luau-lsp clean; tests with `python3 tests/bundle.py .build/t.luau && luau .build/t.luau`.
- Public repo: commits as `Qualflare Root <root@qualflare.com>`, no AI attribution. `plugin.toml` version `0.4.0`.

## Review Focus

1. Every KPI null (a fresh project): six cards with `–`, no change badge, an empty or gap-only line, no error.
2. A `qf` without `overview` (help printed, exit 0 → `qf.read` gives `ok=false, status=0`): "Update qf to use the dashboard" with the install commands, not a generic error.
3. Switching 7 ↔ 28 while a request is in flight: the older answer never overwrites the newer window.
4. The pane closed: its 60 s timer stops (the launches pane's `running()` check).
5. A bridge link asking to open a pane, sent from anything other than a Qualflare pane, or with a malformed identifier: ignored.

---

### Task 1: The page (`lib/dashboard.luau`)

**Files:**
- Create: `lib/dashboard.luau`
- Modify: `lib/views.luau` (`M.overview_url(identifier: string): string` → `https://app.qualflare.com/project/<slug>`), `tests/run.luau`, `tests/bundle.py` only if it lists modules explicitly

**Interfaces:**
- Produces:
  - `export type DashState = { identifier: string?, projects: {string}, days: number, data: any?, error: string?, status: number?, outdated: boolean, loading: boolean, now: number, refreshed: number?, menu_open: boolean, menu_active: string? }`
  - `M.headline(kpi: any): string`, `M.change(kpi: any): { text: string, tone: string }?`, `M.meets(kpi: any): boolean?`, `M.view(s: DashState): BlockView`
  - Node keys the host relies on: head `select` key `project` (as the launches pane), buttons with actions `days7`, `days28`, `refresh`, `retry`, `open`, `launches`.

- [ ] **Step 1: Write the failing tests** in `tests/run.luau` (section "Qualflare dashboard"):
  - `dashboard.headline`: `{unit="percent", key="successRate", latest=94.25}` → `94.3%`; `automationRate` 63.4 → `63%`; seconds 42 → `42s`, 252 → `4m 12s`, 3780 → `1h 3m`; count 5 → `5 today`; `latest=nil` → `–`.
  - `dashboard.change`: `trend="none"` → `{text="no change", tone="muted"}`; `percentChange=nil` → nil; successRate up 3.5 → `▲ 3.5%` `success`; flakeRate up 2 → `error`; launchP90 down 8 → `success`; launches up 25 → `muted`; `percentChange=-3.26`, `trend="down"` → `▼ 3.3%`.
  - `dashboard.meets`: successRate 94 vs target 95 → false; flakeRate 1 vs 2 → true; no target → nil; latest nil → nil.
  - `view` states: no project → "No Qualflare project here"; error status 3 → "Not logged in" + `qf login <id>` + Retry; loading with no data → skeleton; `outdated` → "Update qf to use the dashboard" and `brew install qualflare/tap/qf`; `data.dataThrough == nil` → "No metrics yet"; dataThrough 45 min before `now` → a warning containing "haven't updated"; full data → six cards (find six nodes keyed by KPI key), a `chart` node per card with `kind == "line"`, head text containing `data from` and both `7 days` and `28 days` buttons, the active one `variant == "primary"`.
  - null KPI (all nil, values `{nil…}` represented as JSON nulls): card shows `–`, no badge text, chart series entries are tables (gaps), no error.

- [ ] **Step 2: Run to verify they fail**

Run: `python3 tests/bundle.py .build/t.luau && luau .build/t.luau`
Expected: FAIL (module `dashboard` missing).

- [ ] **Step 3: Implement** `lib/dashboard.luau`. Layout: head row (title `Qualflare`, project `select`, muted `Dashboard · data from <ago>`; right: `7 days` / `28 days` buttons, `Launches` button, `Refresh`), optional stale/warnings line, then a wrapping row (`wrap = true`) of six `ui.card(label, …)` with `basis = 0.3`, `grow = 1`, `min = {w = "26ch"}`, each holding the headline text (tone from `meets`), the change badge and `ui.node("chart", {kind = "line", size = "sm", series = …, labels = <buckets as "MM-DD">, last = false})`; dock legend `W window · R refresh · L launches · P project · ⏎ open on website`. JSON nulls (`tern.json.null`) count as missing everywhere.

- [ ] **Step 4: Run to verify they pass; luau-lsp clean**

Run: `python3 tests/bundle.py .build/t.luau && luau .build/t.luau` and `luau-lsp analyze --platform=standard --definitions=@tern=tern.d.luau host.luau window.luau lib/*.luau`
Expected: all pass; no diagnostics.

- [ ] **Step 5: Commit** `feat: dashboard page view`

### Task 2: The block, the command and the links

**Files:**
- Modify: `host.luau` (new block section), `window.luau` (command + bridge actions), `plugin.toml` (`[[blocks]] id = "dashboard"`, title `Qualflare dashboard`, version `0.4.0`), `lib/tab.luau` (a `Dashboard` button in the launches head, action `dashboard`), `README.md`, `tests/run.luau`

**Interfaces:**
- Consumes: Task 1's `dashboard.view`, `DashState`, action names.
- Produces: block kind `qualflare.dashboard` (`args[1]` identifier); bridge actions `dashboard` and `launches` (`qualflare-tern:dashboard?id=<id>`), accepted only from panes whose block is `qualflare.launches` or `qualflare.dashboard`, with `id` matching the identifier pattern; window command `dashboard` titled `Qualflare: Show dashboard`.

- [ ] **Step 1: Write the failing tests:**
  - init with `{ "demo-app" }` runs `qf demo-app overview --days 7`, stores `data`; title `Qualflare dashboard · demo-app`.
  - action `days28` re-runs with `--days 28`; with answers held back (stub `S.defer`), answering the 7-day request after the 28-day one leaves `days == 28` data.
  - `qf` answering non-JSON with exit 0 → `outdated == true`; exit 3 → `status == 3`.
  - timer: after the pane is gone from `tern.pane.list()`, firing the timer runs no `qf`.
  - `save`/restore keeps `identifier`, `days`, `data`.
  - action `open` opens `views.own(views.overview_url(id))`; action `launches` opens the bridge `qualflare-tern:launches?id=demo-app`; the launches pane's `dashboard` action opens `qualflare-tern:dashboard?id=…`.
  - window: command `dashboard` opens `qualflare.dashboard` with the focused project, `"beside"`; route: bridge `dashboard` from a `qualflare.launches` pane opens the block beside with `{id}`; from a terminal pane, or with `id="../x"`, it is swallowed (`handled = true`) and opens nothing.

- [ ] **Step 2: Run to verify they fail** (same command). Expected: FAIL.

- [ ] **Step 3: Implement** the block (state as `DashState` plus `cwd`, `timer`, `req`; refresh every 60 s with the launches pane's `schedule`/`running` pattern; project list via `qf projects` and `is_identifier`; keys `w` toggles 7/28, `r`, `l`, `p`, `enter`, menu keys as the launches pane), the window command and bridge actions, the launches pane button, the manifest entry and version. README: a "Qualflare dashboard" paragraph and the command row.

- [ ] **Step 4: Run to verify they pass; luau-lsp clean; `tern plugin reload` exits 0**

- [ ] **Step 5: Commit** `feat: Qualflare dashboard pane`

### Task 3: Owner's look and hand-off

- [ ] The owner opens *Qualflare: Show dashboard* in `landing-fe` (needs a `qf` with `overview`: build from `qualflare-cli` `feature/overview` until it's released, pointed at production only once the endpoint is live there).
- [ ] After review, fast-forward `main` and push on the owner's go-ahead.
