# Qualflare Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the plugin's `qualflare.launches` block into a full-page Qualflare tab about the latest launches. It has a project menu, a stats strip, a launches table, a detail card with the AI summary, and website links that open it.

**Architecture:** The page is a pure view function of the block's state, in a new `lib/tab.luau`, so it can be tested without Tern. `host.luau` keeps the block's state, `qf` calls, timer, keys and events. Actions a host block can't do itself, starting an omp agent or typing into a terminal pane, go to the window half through a link with a private scheme, `qualflare-tern:<action>?…`, which the window's `tern.route.link` handler claims. The same handler claims `app.qualflare.com` launch links clicked in terminal panes and opens the tab.

**Tech Stack:** Luau (strict), the Tern plugin API (`tern.d.luau`, generated), the `qf` CLI 0.4.x. Tests use the Luau CLI through `tests/bundle.py` with the stand-in `tern` in `tests/stub.luau`.

**Spec:** `docs/superpowers/specs/2026-11-16-qualflare-tab-design.md`

## Global Constraints

- The plugin never reads or stores tokens. Every server read goes through `qf` (`lib/qf.luau`).
- Every host handler fits Tern's 2 s budget. `qf` runs through the asynchronous `tern.process.run` only. Window route handlers have 50 ms and run no processes.
- The block draws with `font = "sans"` and follows Tern's design guide (https://docs.stencil.so/tern/guides/design.md): a head row, a stats strip, the view, and a key legend in the dock. Colour comes from tones only, with no CSS.
- One primary button on screen: *Open on website* in the detail card.
- "Failed" means `failedCount + errorCount + timeoutCount` everywhere.
- Refresh every 60 000 ms while the block is open, plus `R`. Refreshes never toast or move focus.
- Setting keys in `tern.kv`: existing `auto_prompt`, `qf_path`, `report_dirs`, `slugs`; new `route_links` (default on; only `false` turns it off).
- Commits are authored and committed as `Qualflare Root <root@qualflare.com>` (`git -c user.name="Qualflare Root" -c user.email=root@qualflare.com commit …`), with no AI attribution trailers.
- **This folder is `tern plugin link`ed into the owner's running Tern; saving a file reloads the plugin there.** Keep `luau-lsp` clean before saving host or window files, and never leave a half-edited file on disk between steps.
- Verification commands, run from the repo root:
  - Types: `luau-lsp analyze --platform=standard --definitions=@tern=tern.d.luau host.luau window.luau lib/*.luau`. Expect no output beyond the summary, and 0 errors.
  - Tests: `python3 tests/bundle.py .build/t.luau && luau .build/t.luau`. Expect `N passed, 0 failed`.
  - Install Luau 0.744 and luau-lsp 1.70.1 from their GitHub releases, and put `luau` and `luau-lsp` on `PATH`.

## Review Focus

1. **A project with no launches yet**, such as a fresh `qf login`. Expect the empty state with *Upload*, not an error, and no stats strip. Test: `tab: empty launches shows the empty state` (Task 3).
2. **A launch whose `aiSummary` is null, still pending, or not valid JSON.** Expect the card without the summary section, without failing. Test: `views.summary tolerates null, pending and bad JSON` (Task 2).
3. **A launch link for a project the user isn't logged into.** Expect the route to pass the link on, so it opens in the browser as before, and not to open an empty tab. Test: `route passes links for unknown slugs` (Task 5).
4. **Selection after refresh**, when the selected launch is gone or the list changed. Expect the selection kept by launch number when it still exists, else the newest launch. Test: `block keeps the selected launch across refresh` (Task 4).
5. **The block's own *Open on website*.** It must not be claimed by our route and loop back into the tab: links from a pane whose `kind ~= "terminal"` pass. Test: `route ignores links from non-terminal panes` (Task 5).

---

### Task 1: Live spike: host-to-window bridge, browser placement, wall clock

The answers decide two fallbacks later tasks use. **Ask the owner before starting**: it creates a temporary Tern session in their running Tern (`tern new session …`, removed afterwards with `tern kill session`).

**Files:**
- Create (temporary, deleted at the end of the task): `spike.luau` contents are pasted into `host.luau`/`window.luau` behind a `-- SPIKE` marker and removed before the commit.
- Modify: this plan, the "Spike results" block at the end of the task.

- [ ] **Step 1:** In `window.luau`, register a `tern.route.link` handler that toasts `link.url`, `link.pane`, and the `kind` from `cx.session:pane(link.pane)`, and returns `{ handled = true }` for URLs starting with `qualflare-tern:`, else `nil`. In the launches block's `event`, on act `refresh`, also call `cx:open("qualflare-tern:ping?id=x")`. In `host.luau` at load, log `tern.log.info(tostring(os and os.time and os.time()))`.
- [ ] **Step 2:** Open the block in a temp session, then click *Refresh*. Expected: a toast with the `qualflare-tern:ping…` URL and `kind = plugin`. Then click an `https://app.qualflare.com/...` link printed in a terminal pane (`echo`). Expected: a toast with `kind = terminal`.
- [ ] **Step 3:** In the window, call `cx:open("https://app.qualflare.com/", "tab")` from a temporary palette command. Note whether it opens Tern's browser block or the system browser.
- [ ] **Step 4:** Read the plugin log (`STENCIL_LOG=tern::plugin=debug`, or `tern plugin list` errors) for the `os.time` line. A number means a wall clock is available.
- [ ] **Step 5:** Remove every `-- SPIKE` line, run the type check and tests (both clean, same counts as before), and kill the temp session.
- [ ] **Step 6:** Fill in "Spike results" below and commit only the plan change: `docs: spike results for the Qualflare tab`.

**Spike results** (2026-11-16, temp session `qfspike`, killed afterwards):
- Bridge: **yes**. `cx:open("qualflare-tern:ping?id=x")` from the block's `init` reached the window's `tern.route.link` with `link.pane` = the block's pane and `kind = "plugin"`; `{ handled = true }` stopped it there. *Fix with omp* and *Upload* stay in the card and the head row.
- `cx:open("https://…", "tab")` from the window opened **no Tern browser pane** (`tern browser {"op":"blocks"}` empty; no new tab): it goes to Tern's normal link handling (the system browser by default). Tern's browser is reachable only through `cx.browser:call{op="open"}` automation, a driven picture-in-picture that may not carry the user's website login. Decision: *Open on website* is a plain `cx:open(url)` from the host, which goes through the link route (passed on because the pane kind is `plugin`) and then Tern's own link handling, following the user's Tern setting. No `open` bridge action.
- `os.time()` in the host: **yes** (`1794855487`). `state.now = os.time()` at render and refresh time.
- Not exercised: a click on a link in a terminal pane (needs a person to click). The `kind == "terminal"` check rests on the `LinkRequest`/`PaneInfo` types and is covered by unit tests; Task 6's live check clicks one.

---

### Task 2: Data helpers: relative time, AI summary, links, `qf` lines

**Files:**
- Modify: `lib/views.luau` (add `ago`, `epoch`, `summary`, `failed`)
- Create: `lib/links.luau`
- Modify: `lib/qf.luau` (add `lines`; share the spawn code with `read`)
- Test: `tests/run.luau`

**Interfaces:**
- Produces:
  - `views.epoch(ts: any): number?`: an ISO-8601 UTC timestamp (`2026-10-28T12:24:11.911391Z`, with or without fraction) as Unix seconds; nil when it doesn't parse.
  - `views.ago(ts: any, now: number): string`: `"just now"` (under 60 s), `"5 min ago"`, `"3 h ago"`, `"2 d ago"`, then `views.when(ts)` from 7 days on. `""` when `ts` doesn't parse.
  - `views.failed(l: any): number`: `failedCount + errorCount + timeoutCount`.
  - `views.summary(l: any): Summary?`, where `type Summary = { text: string, risk: string?, why: string?, areas: { string }, recommendations: { string } }`. Decodes `l.aiSummary`, a JSON string with `executiveSummary`, `riskLevel`, `riskJustification`, `failingAreas`, `recommendations`. Nil when the field is missing, null or not JSON, or when `executiveSummary` is empty. `failingAreas` items may be strings or tables with `area`/`name` plus `description`; render each as one string.
  - `links.launch_from_url(url: string): { slug: string, seq: number }?`: matches `https://app.qualflare.com/project/<slug>/launches?…p.seq=<n>…` (any order of query params) and `/project/<slug>/launches` (seq nil → returns nil; only launch links are claimed).
  - `links.identifier_for(slug: string, known: { string }): string?`: the identifier whose `views.slug(id) == slug`, among `known`.
  - `links.bridge(action: string, params: { [string]: string }): string`: builds `qualflare-tern:<action>?k=v&…`, with keys sorted and values percent-encoded.
  - `links.parse_bridge(url: string): (string?, { [string]: string })`: the reverse; nil action for other URLs.
  - `qf.lines(args: { string }, cwd: string?, cb: ({ ok: boolean, lines: { string }, status: number, err: string? }) -> ())`: runs `qf`, splits stdout into its non-empty trimmed lines. Used for `qf projects`.

- [ ] **Step 1: Write the failing tests** in `tests/run.luau`:

```lua
test("views.ago buckets relative times", function()
	local t = views.epoch("2026-11-16T12:00:00Z") :: number
	eq(views.epoch("2026-11-16T12:00:00.123456Z"), t)
	eq(views.ago("2026-11-16T12:00:00Z", t + 30), "just now")
	eq(views.ago("2026-11-16T12:00:00Z", t + 300), "5 min ago")
	eq(views.ago("2026-11-16T12:00:00Z", t + 3 * 3600), "3 h ago")
	eq(views.ago("2026-11-16T12:00:00Z", t + 2 * 86400), "2 d ago")
	eq(views.ago("2026-11-16T12:00:00Z", t + 8 * 86400), "2026-11-16 12:00")
	eq(views.ago(nil, t), "")
	eq(views.epoch("2000-03-01T00:00:00Z"), 951868800) -- leap-year arithmetic
end)

test("views.summary tolerates null, pending and bad JSON", function()
	eq(views.summary({}), nil)
	eq(views.summary({ aiSummary = tern.json.null }), nil)
	eq(views.summary({ aiSummary = "not json" }), nil)
	local s = views.summary({ aiSummary = '{"executiveSummary":"Checkout broke.","riskLevel":"medium","riskJustification":"Payments fail.","failingAreas":[{"area":"checkout","description":"card form"}, "login"],"recommendations":["Fix the form."]}' }) :: any
	eq(s.text, "Checkout broke.")
	eq(s.risk, "medium")
	eq(#s.areas, 2)
	has(s.areas[1], "checkout")
	eq(s.areas[2], "login")
	eq(s.recommendations[1], "Fix the form.")
end)

test("links parse launch URLs and the bridge", function()
	local l = links.launch_from_url("https://app.qualflare.com/project/acme-web/launches?p=launch&p.seq=128") :: any
	eq(l.slug, "acme-web"); eq(l.seq, 128)
	eq(links.launch_from_url("https://app.qualflare.com/project/acme-web/launches"), nil)
	eq(links.launch_from_url("https://example.com/project/x/launches?p.seq=1"), nil)
	S.kv.slugs = { web = "acme-web" }
	eq(links.identifier_for("acme-web", { "api", "web" }), "web")
	eq(links.identifier_for("api", { "api", "web" }), "api")
	eq(links.identifier_for("nope", { "api", "web" }), nil)
	S.kv.slugs = nil
	local u = links.bridge("fix", { id = "web", root = "/w/my repo" })
	eq(u, "qualflare-tern:fix?id=web&root=%2Fw%2Fmy%20repo")
	local action, params = links.parse_bridge(u)
	eq(action, "fix"); eq(params.root, "/w/my repo")
	eq((links.parse_bridge("https://x")), nil)
end)

test("qf.lines returns trimmed non-empty lines", function()
	S.kv.qf_path = "/bin/qf"; qf.reset()
	S.process["/bin/qf projects"] = { status = 0, stdout = "app-landing\n stage\n\nstarter\n", stderr = "", timed_out = false }
	local got
	qf.lines({ "projects" }, nil, function(r) got = r end)
	eq(got.ok, true); eq(#got.lines, 3); eq(got.lines[2], "stage")
end)
```

Add `local links = require("../lib/links")` and `local views = require("../lib/views")` next to the other requires at the top of `tests/run.luau`.

- [ ] **Step 2: Run the tests and watch them fail.** Expected: the 4 new tests fail (`epoch`/`links` missing); the old ones pass.
- [ ] **Step 3: Implement** the Interfaces above. `epoch` uses the days-from-civil algorithm, so it doesn't depend on `os.time`. Decode with `pcall(tern.json.decode, s)`. `qf.lines` and `qf.read` share one local `spawn(args, cwd, cb(res))` that keeps the existing pcall and the "Can't run qf" message.
- [ ] **Step 4: Run the type check and tests.** Expected: 0 errors; all pass.
- [ ] **Step 5: Commit** `feat: helpers for the Qualflare tab`.

---

### Task 3: The page view (`lib/tab.luau`)

**Files:**
- Create: `lib/tab.luau`
- Modify: `lib/views.luau` (`launches_table`: drop the trailing `open` button column, add an `age` column from `views.ago`, take `now`)
- Modify: `tests/stub.luau` (add `ui.node(k, p, c)`, returning `node(k, p, c)`, if missing)
- Test: `tests/run.luau`

**Interfaces:**
- Consumes: `views.ago`, `views.failed`, `views.summary`, `views.badge`, `views.when`, `views.launches_table`.
- Produces:
  - `export type TabState = { identifier: string?, projects: { string }, launches: { any }?, more: boolean, error: string?, status: number?, loading: boolean, selected: number?, now: number, refreshed: number?, menu_open: boolean }`. `more` means another page of launches exists. `selected` is a launch `seq`. `refreshed` is Unix seconds.
  - `tab.view(s: TabState): BlockView` returns `{ main, dock }`.
  - Node keys and acts later tasks depend on:
    - project select `key = "project"` (sends `change` with `value`);
    - buttons `act = "upload"`, `"refresh"`, `"open"`, `"fix"`, `"retry"`, `"more"`;
    - table rows `id = "launch=<seq>"` (from `launches_table`).
  - `tab.selected_launch(s: TabState): any?`: the launch whose `seq == s.selected`, else `launches[1]`, else nil.

Layout (`main` is `ui.node("col", { gap = "lg" }, …)`):
1. **Head row** (`key = "head"`, `justify = "between"`, `align = "center"`). Left: a `text` with `Qualflare` in the `title` token, then the project `select` (`variant = "quiet"`, `options = s.projects`, `value = s.identifier`, `open = s.menu_open`), then a muted `· updated <ago(refreshed)>`. Right: *Upload* (`icon = "push"`, `keys = {"u"}`) and *Refresh* (`icon = "repeat"`, `keys = {"r"}`, `busy = s.loading`).
2. **Stats strip** (only when there are launches), from `launches[1]`:
   - `Pass rate` = `passedCount/totalCount` as a whole percent;
   - `Failed` = `views.failed`, `error` tone when > 0;
   - `Flaky` = `flakyCount`, `warning` tone when > 0;
   - `Last run` = `views.ago(createdAt, now)`.
3. **View** (`key = "launches"`): a `row` (`gap = "lg"`, `align = "start"`) holding `launches_table(launches, { selected = "launch=<seq>", now = s.now, max = 50 })` with `grow = 1`, and under it a quiet *Show more* button (`act = "more"`) when `s.more`; then the **detail card** (`min = { w = "36ch" }`, `max = { w = "48ch" }`):
   - head: `#<seq> · <branch or "no branch"> · <environmentName>`, with the status badge;
   - body:
     - `ui.test_summary(passed, failed, skipped, nil)`;
     - a `kv` of Framework, OS, Browser, Commit (first 8 chars), Milestone, Created (`views.when`), skipping null or empty values;
     - when `views.summary` gives one: the `text`, a `Risk` badge (`low` muted, `medium` warning, `high`/`critical` error) with `why` muted, a "Failing areas" list and a "Recommendations" list;
   - buttons:
     - *Open on website* (`variant = "primary"`, `act = "open"`, `keys = {"enter"}`);
     - *Fix with omp* (`act = "fix"`), only when `views.failed(l) > 0` and the spike kept it.
4. **Dock:** a key legend text: `↑↓ select · ⏎ open on website · R refresh · U upload · P project`.

The four states replace item 3 and, apart from loading with stale data, the stats strip:
- **Loading, no data yet:** `ui.node("skeleton", { shape = "card", tiles = 4 })`, then `{ shape = "rows", rows = 6 }`.
- **Loading with saved data:** draw the saved page; only *Refresh* shows busy.
- **No project:** `empty` with icon `folder`, title `No Qualflare project here`, text `Run /qf-init in Claude Code or omp, or pick a project above.`
- **Error:** `empty` with `tone = "error"`, title from `qf.explain(status)`'s label, the `error` text, and a *Retry* button (`act = "retry"`). For status 3 the text is `Run qf login <identifier> in a terminal.`
- **Empty:** `empty` with icon `inbox`, title `No launches yet`, text `Upload results with qf <id> collect, or press U.`, and an *Upload* button (`act = "upload"`).

- [ ] **Step 1: Write the failing tests:**

```lua
local function st(over: any): any
	local s = { identifier = "demo-app", projects = { "demo-app", "web" }, launches = nil, loading = false, now = 1763294400, menu_open = false, selected = nil }
	for k, v in over do s[k] = v end
	return s
end

test("tab: launches page has head, stats, table and the selected card", function()
	local launches = (tern.json.decode(LAUNCHES) :: any).items
	local v = tab.view(st({ launches = launches, selected = launches[2].seq, refreshed = 1763294400 - 60 }))
	local t = S.text(v.main)
	has(t, "Qualflare"); has(t, "Pass rate"); has(t, "Failed"); has(t, "Flaky"); has(t, "Last run")
	has(t, "#" .. tostring(launches[2].seq))
	has(t, "Open on website")
	has(S.text(v.dock), "R refresh")
end)

test("tab: Fix with omp shows only on failed launches", function()
	local launches = (tern.json.decode(LAUNCHES) :: any).items -- fixture: [1] failed, [2] passed
	has(S.text(tab.view(st({ launches = launches, selected = launches[1].seq })).main), "Fix with omp")
	assert(not string.find(S.text(tab.view(st({ launches = launches, selected = launches[2].seq })).main), "Fix with omp", 1, true))
end)

test("tab: empty launches shows the empty state", function()
	local t = S.text(tab.view(st({ launches = {} })).main)
	has(t, "No launches yet")
	assert(not string.find(t, "Pass rate", 1, true), "no stats strip when empty")
end)

test("tab: loading, error and no-project states", function()
	has(S.kind_list(tab.view(st({ loading = true })).main), "skeleton")
	local e = S.text(tab.view(st({ error = "no token loaded", status = 3 })).main)
	has(e, "Not logged in"); has(e, "qf login demo-app"); has(e, "Retry")
	has(S.text(tab.view(st({ identifier = nil })).main), "No Qualflare project here")
end)
```

If `LAUNCHES` lacks one failed and one passed launch in positions 1 and 2, extend it. If `S.kind_list(node): string` (every node `k` joined by spaces) doesn't exist, add it to `tests/stub.luau` beside `S.text`. Add `local tab = require("../lib/tab")`.

- [ ] **Step 2: Run the tests and watch them fail** (`tab` missing).
- [ ] **Step 3: Implement** `lib/tab.luau` and the `launches_table` change. Update the existing list-lens and block tests that clicked the removed `open` button to use `{ ev = "activate", item = "launch=42" }` instead. `item_url` in `host.luau` already handles activate.
- [ ] **Step 4: Run the type check and tests.** Expected: all pass.
- [ ] **Step 5: Commit** `feat: Qualflare tab page view`.

---

### Task 4: The block (`host.luau`)

**Files:**
- Modify: `host.luau`, the `-- Block: Qualflare launches` section (≈ lines 273–412), rewritten
- Modify: `plugin.toml`: block `title = "Qualflare"`; plugin `version = "0.2.0"`
- Test: `tests/run.luau`: replace the three old block tests

**Interfaces:**
- Consumes:
  - `tab.view`, `tab.selected_launch`, `TabState` (Task 3);
  - `qf.read`, `qf.lines`;
  - `links.bridge`;
  - `views.launch_url`, `views.project_url`;
  - `project.find`.
- Produces: block `qualflare.launches` with `args = { identifier?, seq? }`. The kind stays `launches` so existing panes and commands keep working.

Behaviour:
- **`init(cx, args, saved)`** restores `identifier`, `launches`, `selected` and `refreshed` from `saved`. Then the identifier is `args[1]` if given, else the saved one, else the focused cwd's project, else the first of `projects` once that list loads. If `args[2]` parses as a number, it becomes `selected`. It starts `qf projects` (`qf.lines`) and a refresh, and schedules the 60 s timer. When `cx.cwd` lies inside a project whose identifier isn't in `projects`, that identifier is added anyway, so a project folder works before `qf projects` returns.
- **`refresh(s, cx)`** runs `qf <id> launches list` only (clusters are gone). On success it sets `launches`, sets `more = paging.page < paging.pages` and remembers `paging.page`, clears `error` and `status`, and sets `refreshed = now`. It keeps `selected` if a launch with that `seq` is still in the list, else sets it to nil, so the newest launch shows. On failure it sets `error`/`status` and keeps the old `launches`. It calls `cx:render()` once at the end. Wall-clock `now` comes from the spike's choice.
- **Events:**
  - `change` on `project` sets the identifier, clears `launches`, `selected` and `error`, refreshes, and `cx:save()`s;
  - `toggle` on `project` mirrors `menu_open`;
  - `select` on a `launch=<seq>` row sets `selected`;
  - `activate` on a row, or `action` `open`, opens `views.launch_url(id, seq)` of the selected launch, as the spike decided;
  - `action` `refresh` or `retry` refreshes (back to page 1);
  - `action` `more` runs `qf <id> launches list --page <page+1>`, appends its items and updates `more`;
  - `action` `upload` opens `links.bridge("upload", { id = identifier, root = <project root or cwd> })`;
  - `action` `fix` opens `links.bridge("fix", { id, root })`.
- **Keys** (no modifiers):
  - `r` refreshes;
  - `u` uploads;
  - `p` opens the project menu (`menu_open = true`);
  - `up`/`down` and `k`/`j` move `selected` through `launches`;
  - `enter` opens the selected launch.
  
  Return `false` for anything else.
- **`title`:** `Qualflare · <identifier>`, or `Qualflare`.
- **`save`:** `{ identifier, launches, selected, refreshed }`.

- [ ] **Step 1: Write the failing tests** (replacing `launches block loads launches and clusters through qf`, `launches block shows qf's error` and `launches block without a project explains /qf-init`):

```lua
test("block loads projects and launches through qf", function()
	S.kv.qf_path = "/bin/qf"; qf.reset()
	S.process["/bin/qf projects"] = { status = 0, stdout = "demo-app\nweb\n", stderr = "", timed_out = false }
	S.process["/bin/qf demo-app launches list"] = { status = 0, stdout = LAUNCHES, stderr = "", timed_out = false }
	local B = S.blocks.launches
	local cx = S.block_cx(5, "/w/repo")
	local s = B.init(cx, { "demo-app" }, nil)
	eq(B.title(s), "Qualflare · demo-app")
	eq(#s.projects, 2)
	has(S.text(B.view(s, cx).main), "Pass rate")
	B.event(s, { ev = "activate", item = "launch=42" }, cx)
	eq(S.opened[#S.opened], "https://app.qualflare.com/project/demo-app/launches?p=launch&p.seq=42")
	eq(B.save(s).identifier, "demo-app")
end)

test("block opens on a launch from args and switches project", function()
	S.process["/bin/qf web launches list"] = { status = 0, stdout = LAUNCHES, stderr = "", timed_out = false }
	local B = S.blocks.launches
	local cx = S.block_cx(8, nil)
	local s = B.init(cx, { "demo-app", "41" }, nil)
	eq(s.selected, 41)
	B.event(s, { ev = "change", id = "main.head.project", value = "web" }, cx)
	eq(s.identifier, "web"); eq(s.selected, nil)
end)

test("block keeps the selected launch across refresh", function()
	local B = S.blocks.launches
	local cx = S.block_cx(9, nil)
	local s = B.init(cx, { "demo-app" }, nil)
	B.event(s, { ev = "select", item = "launch=41" }, cx)
	B.key(s, { name = "r" }, cx)
	eq(s.selected, 41)
	s.selected = 9999
	B.key(s, { name = "r" }, cx)
	eq(s.selected, nil)
end)

test("block pages with Show more", function()
	S.process["/bin/qf paged launches list"] = { status = 0, stdout = '{"items":[{"seq":3,"status":"passed"}],"paging":{"page":1,"pages":2}}', stderr = "", timed_out = false }
	S.process["/bin/qf paged launches list --page 2"] = { status = 0, stdout = '{"items":[{"seq":2,"status":"passed"}],"paging":{"page":2,"pages":2}}', stderr = "", timed_out = false }
	local B = S.blocks.launches
	local cx = S.block_cx(11, nil)
	local s = B.init(cx, { "paged" }, nil)
	eq(s.more, true)
	B.event(s, { ev = "action", act = "more" }, cx)
	eq(#s.launches, 2); eq(s.more, false)
end)

test("block shows qf's error and the login hint", function()
	S.process["/bin/qf nologin launches list"] = { status = 3, stdout = "", stderr = "Error: no token loaded; run 'qf login'\n", timed_out = false }
	local B = S.blocks.launches
	local cx = S.block_cx(6, nil)
	local s = B.init(cx, { "nologin" }, nil)
	has(S.text(B.view(s, cx).main), "qf login nologin")
end)

test("block buttons hand upload and fix to the window", function()
	local B = S.blocks.launches
	local cx = S.block_cx(10, "/w/repo")
	local s = B.init(cx, { "demo-app" }, nil)
	B.event(s, { ev = "action", act = "upload" }, cx)
	has(S.opened[#S.opened], "qualflare-tern:upload?id=demo-app")
	B.event(s, { ev = "action", act = "fix" }, cx)
	has(S.opened[#S.opened], "qualflare-tern:fix?id=demo-app")
end)
```

Match the `change` event's `id` to the key path the stub reports. The handler should compare only the last segment (`project`).

- [ ] **Step 2: Run the tests and watch them fail.**
- [ ] **Step 3: Implement** the section rewrite and the manifest changes. Delete the now-unused `latest_stats` and `clusters` reads from the block. `views.clusters_table` stays; the list lens uses it.
- [ ] **Step 4: Run the type check and tests.** Expected: all pass. Then run `tern plugin list`. Expected: `qualflare 0.2.0 … ready`.
- [ ] **Step 5: Commit** `feat: Qualflare tab block`.

---

### Task 5: Window: link route, bridge actions, commands

**Files:**
- Modify: `window.luau`
- Modify: `tests/stub.luau`: capture `tern.route.link` handlers in `S.routes`, give `window_cx` a `layout` no-op, and let `S.panes` entries carry `kind`
- Test: `tests/run.luau`

**Interfaces:**
- Consumes:
  - `links.launch_from_url`, `links.identifier_for`, `links.parse_bridge` (Task 2);
  - `project.find_cached`;
  - `detect.report_dirs`, `detect.relative`;
  - `qf.quote`.
- Produces:
  - `local function upload_into(cx: WindowCx, identifier: string, root: string, pane: number?)`: the existing upload logic, factored out. Target pane: `pane` if given, else the focused pane if it is a terminal at a prompt under `root`. Otherwise the first pane in `cx.session` that is a terminal at a prompt under `root`. Otherwise a toast: `Open a terminal in <root> to upload`.
  - The `tern.route.link` handler.

Route handler, in order:
1. `links.parse_bridge(link.url)` gives an action:
   - `upload`: `upload_into(cx, params.id, params.root)`;
   - `fix`: `cx.agents:start({ prompt = "/skill:qf-fix", cwd = params.root, how = "split" })`;
   - `open`: `cx:open(params.url, "tab")`, if the spike chose Tern's browser.
   
   Return `{ handled = true }`.
2. Return nil (pass) when `tern.kv.get("route_links") == false`, or when the pane at `link.pane` isn't `kind == "terminal"`.
3. `links.launch_from_url(link.url)` gives `{ slug, seq }`. Then `links.identifier_for(slug, known)`, where `known` is the identifiers of open Qualflare projects: the focused pane's project, plus `tern.kv.get("known_identifiers")`, which the host writes from `qf projects` on each block init. Window handlers can't run processes. On a match, return `{ block = "qualflare.launches", args = { identifier, tostring(seq) } }`. Otherwise return nil.

Commands:
- *Qualflare: Show launches* opens with `how = "tab"`.
- *Upload* and *Fix* call the shared functions.
- New command `toggle_links`, titled *Qualflare: Toggle opening Qualflare links in Tern*, flips `route_links` and toasts the new state.

The host side of `known_identifiers`: in Task 4's `qf projects` callback, `tern.kv.set("known_identifiers", lines)`. Add that line there, with a one-line test assertion in `block loads projects and launches through qf`: `eq(S.kv.known_identifiers[2], "web")`.

- [ ] **Step 1: Write the failing tests:**

```lua
test("route opens launch links from terminals in the tab", function()
	S.kv.known_identifiers = { "demo-app" }
	S.panes = { { pane = 1, kind = "terminal", cwd = "/w/repo" } }
	local d = S.routes[1]({ url = "https://app.qualflare.com/project/demo-app/launches?p=launch&p.seq=42", pane = 1, mods = {} }, S.window_cx(1))
	eq(d.block, "qualflare.launches"); eq(d.args[1], "demo-app"); eq(d.args[2], "42")
end)

test("route ignores links from non-terminal panes", function()
	S.panes = { { pane = 2, kind = "plugin", cwd = "" } }
	eq(S.routes[1]({ url = "https://app.qualflare.com/project/demo-app/launches?p=launch&p.seq=42", pane = 2, mods = {} }, S.window_cx(2)), nil)
end)

test("route passes links for unknown slugs", function()
	S.panes = { { pane = 1, kind = "terminal", cwd = "/w/repo" } }
	eq(S.routes[1]({ url = "https://app.qualflare.com/project/other/launches?p=launch&p.seq=1", pane = 1, mods = {} }, S.window_cx(1)), nil)
end)

test("route_links=false passes every Qualflare link", function()
	S.kv.route_links = false
	S.panes = { { pane = 1, kind = "terminal", cwd = "/w/repo" } }
	eq(S.routes[1]({ url = "https://app.qualflare.com/project/demo-app/launches?p=launch&p.seq=42", pane = 1, mods = {} }, S.window_cx(1)), nil)
	S.kv.route_links = nil
end)

test("bridge fix starts omp at the project root; upload types into a terminal", function()
	local cx = S.window_cx(3)
	local d = S.routes[1]({ url = "qualflare-tern:fix?id=demo-app&root=%2Fw%2Frepo", pane = 3, mods = {} }, cx)
	eq(d.handled, true)
	local r = S.runs[#S.runs]; eq(r[2], "/skill:qf-fix"); eq(r[3], "/w/repo")
	S.panes = { { pane = 4, kind = "terminal", cwd = "/w/repo", at_prompt = true } }
	S.files["/w/repo/qualflare-results"] = "" -- report_dirs checks existence
	S.routes[1]({ url = "qualflare-tern:upload?id=demo-app&root=%2Fw%2Frepo", pane = 3, mods = {} }, cx)
	eq(S.writes[#S.writes].pane, 4); has(S.writes[#S.writes].text, "qf demo-app collect")
end)
```

Follow the existing tests' setup for the project fixture under `/w/repo`. Reuse `.qualflare/test-state.md` the way the `Show launches` test already does.

- [ ] **Step 2: Run the tests and watch them fail.**
- [ ] **Step 3: Implement** them. Update the existing `Show launches` test to expect the `tab` placement if the stub records `how`.
- [ ] **Step 4: Run the type check and tests.** Expected: all pass.
- [ ] **Step 5: Commit** `feat: open Qualflare links in the tab`.

---

### Task 6: Docs and live check

**Files:**
- Modify: `README.md`. The "Launches pane" paragraph becomes "Qualflare tab", describing what's on the page, the keys, and that `app.qualflare.com` launch links open it. Add `route_links` to the settings table and the new toggle to the commands table. Drop the clusters mention from the pane description, since the list lens still shows clusters.
- Modify: `docs/superpowers/specs/2026-11-16-qualflare-tab-design.md`: Status `implemented`, plus a line for each spike-driven deviation.

- [ ] **Step 1:** Update both documents.
- [ ] **Step 2:** Run the full type check and tests one last time. Expected: clean; all pass.
- [ ] **Step 3: Live check with the owner** (ask first; they are logged in to `app-landing`). In their Tern, in `~/Astrais/landing-fe`, run *Qualflare: Show launches*. Expected: a tab titled `Qualflare · app-landing` with launch #1 (passed, 4/4, Staging), the stats strip, and the card with the AI summary "The launch passed with no failures." Check:
  1. the project menu lists `app-landing`, `stage`, `starter`;
  2. `R` refreshes;
  3. ⏎ opens the launch page;
  4. `echo https://app.qualflare.com/project/app-landing/launches?p=launch\&p.seq=1` in a terminal, then clicking the link, opens the tab on #1.
  
  The owner takes the README screenshot here.
- [ ] **Step 4: Commit** `docs: Qualflare tab`.
