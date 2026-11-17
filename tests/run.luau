-- Plugin tests outside Tern: `luau tests/run.luau` (see README).
local S = require("./stub")
local detect = require("../lib/detect")
local project = require("../lib/project")
local qf = require("../lib/qf")
local views = require("../lib/views")
local links = require("../lib/links")
local tab = require("../lib/tab")
local dashboard = require("../lib/dashboard")

local passed, failed, pending = 0, 0, 0
local function test(name: string, fn: () -> ())
	S.reset()
	local ok, err = pcall(fn)
	if ok then
		passed += 1
	else
		failed += 1
		print("FAIL " .. name .. "\n     " .. tostring(err))
	end
end
local function eq(a: any, b: any, msg: string?)
	if a ~= b then
		error(`{msg or "values differ"}: expected {tostring(b)}, got {tostring(a)}`, 2)
	end
end
local function has(hay: string, needle: string)
	if not string.find(hay, needle, 1, true) then
		error(`expected to find "{needle}" in: {hay}`, 2)
	end
end
local function no(hay: string, needle: string)
	if string.find(hay, needle, 1, true) then
		error(`expected no "{needle}" in: {hay}`, 2)
	end
end

local function st(over: any): any
	local s: any = { identifier = "demo-app", projects = { "demo-app", "web" }, launches = nil, more = false, loading = false, now = 1763294400, menu_open = false, selected = nil }
	for k, v in over do
		s[k] = v
	end
	return s
end

local STATE = [[
<!-- qualflare-test-state v:1 -->
## Packages
| Path | Identifier |
|------|------------|
| (root) | demo-app |
| packages/web | acme-web |

## Frameworks in use
| Package | Slug | Language | File count | Top-level paths |
|---------|------|----------|------------|-----------------|
| (root) | jest | TypeScript | 3 | src/**/*.test.ts |
]]

---------------------------------------------------------------------------
-- lib
---------------------------------------------------------------------------

test("parse_packages reads the Packages table only", function()
	local p = project.parse_packages(STATE)
	eq(#p, 2)
	eq(p[1].path, "")
	eq(p[1].identifier, "demo-app")
	eq(p[2].path, "packages/web")
	eq(p[2].identifier, "acme-web")
end)

test("find picks the deepest package containing cwd", function()
	S.files["/w/repo/.qualflare/test-state.md"] = STATE
	eq((project.find("/w/repo/packages/web/src") :: any).package.identifier, "acme-web")
	eq((project.find("/w/repo/docs") :: any).package.identifier, "demo-app")
	eq((project.find("/w/repo") :: any).root, "/w/repo")
	eq(project.find("/elsewhere"), nil)
end)

test("strip_wrappers drops env assignments and runners", function()
	local w = detect.strip_wrappers(detect.words("CI=1 FOO=bar npx playwright test --project=x"))
	eq(w[1], "playwright")
	eq(w[2], "test")
	local p = detect.strip_wrappers(detect.words("pnpm exec vitest run"))
	eq(p[1], "vitest")
end)

test("collect_targets lists few files, else their common dir", function()
	local few = detect.collect_targets({ "/r/qualflare-results/a.json", "/r/qualflare-results/b.json" }, "/r")
	eq(#few, 2)
	eq(few[1], "qualflare-results/a.json")
	local many = {}
	for i = 1, 5 do
		table.insert(many, `/r/.qualflare/results/junit/T{i}.xml`)
	end
	local t = detect.collect_targets(many, "/r")
	eq(#t, 1)
	eq(t[1], ".qualflare/results/junit")
end)

test("qf.quote leaves plain paths and quotes the rest", function()
	eq(qf.quote("qualflare-results/a.json"), "qualflare-results/a.json")
	eq(qf.quote("my results/a.json"), "'my results/a.json'")
	eq(qf.quote("it's"), "'it'\\''s'")
end)

test("qf.explain maps the CLI's exit codes", function()
	eq((qf.explain(0)), "Uploaded")
	eq((qf.explain(3)), "Not logged in")
	eq((qf.explain(4)), "Forbidden or plan limit")
	eq((qf.explain(7)), "Server busy, retry")
end)

---------------------------------------------------------------------------
-- host.luau
---------------------------------------------------------------------------

require("../host")

local LAUNCHES = [[{
  "items": [
    {"seq": 42, "status": "failed", "totalCount": 120, "passedCount": 110, "failedCount": 7, "errorCount": 1, "skippedCount": 2, "flakyCount": 3, "environmentName": "staging", "branch": "feat/checkout", "createdAt": "2026-11-15T14:32:10Z"},
    {"seq": 41, "status": "passed", "totalCount": 118, "passedCount": 118, "failedCount": 0, "skippedCount": 0, "environmentName": "staging", "branch": null, "createdAt": "2026-11-15T09:01:44Z"}
  ],
  "paging": {"page": 1, "pages": 1, "perPage": 20, "totalItems": 2}
}]]
local CLUSTERS = [[{"items": [{"id": 7, "label": "TimeoutError waiting for #pay-button", "summary": "Checkout button never shows", "severity": "high", "failureCount": 5, "lastSeenAt": "2026-11-15T14:32:10Z"}], "paging": {}}]]

local function lines(text: string): { { text: string, links: {} } }
	local out = {}
	for l in string.gmatch(text .. "\n", "([^\n]*)\n") do
		table.insert(out, { text = l, links = {} })
	end
	return out
end

test("host registers both lenses, the block and the widget", function()
	assert(S.lenses.collect, "collect lens")
	assert(S.lenses.list, "list lens")
	assert(S.blocks.launches, "launches block")
	assert(S.widgets["last-upload"], "widget")
end)

test("collect lens: progress while running, card when done", function()
	local L = S.lenses.collect
	local s = L.open({ line = "qf demo-app collect r.xml", typed = "", program = "qf", args = { "demo-app", "collect", "r.xml" } }, S.effect_cx())
	for _, l in lines("Processing 2 test result file(s)...") do
		L.line(s, l)
	end
	eq(L.view(s).k, "progress")
	for _, l in lines("skipped 1 video attachment(s): upload them with --upload-artifacts=video\nOK Test results collected successfully") do
		L.line(s, l)
	end
	L.finish(s, 0)
	local t = S.text(L.view(s))
	has(t, "Uploaded")
	has(t, "2 file(s)")
	has(t, "skipped 1 video")
	has(t, "Test results collected successfully")
	L.event(s, { ev = "action", act = "open" }, S.effect_cx())
	eq(S.opened[1], "https://app.qualflare.com/project/demo-app/launches")
end)

test("collect lens: exit 3 says how to log in", function()
	local L = S.lenses.collect
	local s = L.open({ line = "", typed = "", program = "qf", args = { "demo-app", "collect", "x" } }, S.effect_cx())
	L.line(s, { text = "ERR no token loaded", links = {} })
	L.finish(s, 3)
	local t = S.text(L.view(s))
	has(t, "Not logged in")
	has(t, "qf login demo-app")
end)

test("list lens: raw until JSON parses, then a launches table", function()
	local L = S.lenses.list
	local s = L.open({ line = "", typed = "", program = "qf", args = { "demo-app", "launches", "list" } }, S.effect_cx())
	for _, l in lines(LAUNCHES) do
		L.line(s, l)
	end
	eq(L.view(s), nil, "view before finish")
	L.finish(s, 0)
	local v = L.view(s)
	eq(v.k, "table")
	eq(#v.p.rows, 2)
	eq(v.p.rows[1].id, "launch=42")
	has(S.text(v), "#42")
	has(S.text(v), "110 / 8 / 2")
	-- open button and double-click
	L.event(s, { ev = "action", act = "launch=42" }, S.effect_cx())
	L.event(s, { ev = "activate", item = "launch=41" }, S.effect_cx())
	eq(S.opened[1], "https://app.qualflare.com/project/demo-app/launches?p=launch&p.seq=42&src=tern")
	eq(S.opened[2], "https://app.qualflare.com/project/demo-app/launches?p=launch&p.seq=41&src=tern")
end)

test("list lens: a failed qf leaves raw output", function()
	local L = S.lenses.list
	local s = L.open({ line = "", typed = "", program = "qf", args = { "demo-app", "launches", "list" } }, S.effect_cx())
	L.line(s, { text = "Error: unauthorized", links = {} })
	L.finish(s, 3)
	eq(L.view(s), nil)
end)

test("slugs setting overrides the dashboard slug", function()
	S.kv.slugs = { ["demo-app"] = "demo" }
	local L = S.lenses.list
	local s = L.open({ line = "", typed = "", program = "qf", args = { "demo-app", "clusters", "list" } }, S.effect_cx())
	for _, l in lines(CLUSTERS) do
		L.line(s, l)
	end
	L.finish(s, 0)
	L.event(s, { ev = "action", act = "cluster=7" }, S.effect_cx())
	eq(S.opened[1], "https://app.qualflare.com/project/demo/clusters/7")
	S.kv.slugs = nil
end)

test("block loads projects and launches through qf", function()
	S.kv.qf_path = "/bin/qf"
	qf.reset()
	S.process["/bin/qf projects"] = { status = 0, stdout = "demo-app\nweb\n", stderr = "", timed_out = false }
	S.process["/bin/qf demo-app launches list"] = { status = 0, stdout = LAUNCHES, stderr = "", timed_out = false }
	local B = S.blocks.launches
	local cx = S.block_cx(5, "/w/repo")
	local s = B.init(cx, { "demo-app" }, nil)
	eq(B.title(s), "Qualflare · demo-app")
	eq(#s.projects, 2)
	eq(S.kv.known_identifiers[2], "web")
	has(S.text(B.view(s, cx).main), "8 of 120 failing")
	B.event(s, { ev = "activate", item = "launch=42" }, cx)
	eq(S.opened[#S.opened], "https://app.qualflare.com/project/demo-app/launches?p=launch&p.seq=42&src=tern")
	B.event(s, { ev = "select", item = "launch=41" }, cx)
	B.event(s, { ev = "action", act = "open" }, cx)
	eq(S.opened[#S.opened], "https://app.qualflare.com/project/demo-app/launches?p=launch&p.seq=41&src=tern")
	eq(B.save(s).identifier, "demo-app")
	eq(B.save(s).selected, 41)
end)

test("block opens on a launch from args and switches project", function()
	S.process["/bin/qf web launches list"] = { status = 0, stdout = LAUNCHES, stderr = "", timed_out = false }
	local B = S.blocks.launches
	local cx = S.block_cx(8, nil)
	local s = B.init(cx, { "demo-app", "41" }, nil)
	eq(s.selected, 41)
	B.event(s, { ev = "change", id = "main.head.start.project", value = "web" }, cx)
	eq(s.identifier, "web")
	eq(s.selected, nil)
	eq(B.title(s), "Qualflare · web")
end)

test("block keeps the selected launch across refresh", function()
	local B = S.blocks.launches
	local cx = S.block_cx(9, nil)
	local s = B.init(cx, { "demo-app" }, nil)
	B.event(s, { ev = "select", item = "launch=41" }, cx)
	B.key(s, { name = "r", ctrl = false, alt = false, shift = false, meta = false }, cx)
	eq(s.selected, 41)
	s.selected = 9999
	B.key(s, { name = "r", ctrl = false, alt = false, shift = false, meta = false }, cx)
	eq(s.selected, nil)
end)

test("block moves the selection with arrow keys", function()
	local B = S.blocks.launches
	local cx = S.block_cx(12, nil)
	local s = B.init(cx, { "demo-app" }, nil)
	local k = function(name: string): any
		return { name = name, ctrl = false, alt = false, shift = false, meta = false }
	end
	eq(B.key(s, k("down"), cx), true)
	eq(s.selected, 41)
	B.key(s, k("up"), cx)
	eq(s.selected, 42)
	B.key(s, k("enter"), cx)
	eq(S.opened[#S.opened], "https://app.qualflare.com/project/demo-app/launches?p=launch&p.seq=42&src=tern")
	eq(B.key(s, k("x"), cx), false)
end)

test("block pages with Show more", function()
	S.process["/bin/qf paged launches list"] = { status = 0, stdout = '{"items":[{"seq":3,"status":"passed"}],"paging":{"page":1,"pages":2}}', stderr = "", timed_out = false }
	S.process["/bin/qf paged launches list --page 2"] = { status = 0, stdout = '{"items":[{"seq":2,"status":"passed"}],"paging":{"page":2,"pages":2}}', stderr = "", timed_out = false }
	local B = S.blocks.launches
	local cx = S.block_cx(11, nil)
	local s = B.init(cx, { "paged" }, nil)
	eq(s.more, true)
	B.event(s, { ev = "action", act = "more" }, cx)
	eq(#s.launches, 2)
	eq(s.more, false)
end)

test("block shows qf's error and the login hint", function()
	S.process["/bin/qf nologin launches list"] = { status = 3, stdout = "", stderr = "Error: no token loaded; run 'qf login'\n", timed_out = false }
	local B = S.blocks.launches
	local cx = S.block_cx(6, nil)
	local s = B.init(cx, { "nologin" }, nil)
	has(S.text(B.view(s, cx).main), "qf login nologin")
end)

test("block without a project explains /qf-init", function()
	local B = S.blocks.launches
	local cx = S.block_cx(7, "/nowhere")
	S.process["/bin/qf projects"] = { status = 0, stdout = "", stderr = "", timed_out = false }
	local s = B.init(cx, {}, nil)
	has(S.text(B.view(s, cx).main), "/qf-init")
end)

test("block buttons hand upload and fix to the window", function()
	local B = S.blocks.launches
	local cx = S.block_cx(10, "/w/repo")
	local s = B.init(cx, { "demo-app" }, nil)
	B.event(s, { ev = "action", act = "upload" }, cx)
	has(S.opened[#S.opened], "qualflare-tern:upload?id=demo-app")
	B.event(s, { ev = "action", act = "fix" }, cx)
	has(S.opened[#S.opened], "qualflare-tern:fix?id=demo-app")
	has(S.opened[#S.opened], "root=%2Fw%2Frepo")
end)

test("finished qf collect updates the status widget", function()
	S.fire("command_finished", { pane = 1, line = "qf demo-app collect r.xml", status = 0, took_ms = 900 })
	eq(S.kv.last_upload.identifier, "demo-app")
	local w = S.widgets["last-upload"].render(nil)
	eq(w.text, "demo-app: Uploaded")
	eq(w.tone, "success")
	S.fire("command_finished", { pane = 1, line = "qf demo-app collect r.xml --dry-run", status = 1, took_ms = 9 })
	eq(S.kv.last_upload.status, 0, "dry runs don't count")
end)

test("a test run that writes reports leaves qf collect on the prompt", function()
	S.files["/w/repo/.qualflare/test-state.md"] = STATE
	S.files["/w/repo/qualflare-results/.keep"] = ""
	S.panes = { { pane = 3, cwd = "/w/repo", program = "zsh", title = "", busy = false } }
	S.process["find /w/repo/qualflare-results"] = { status = 0, stdout = "/w/repo/qualflare-results/jest.json\n", stderr = "", timed_out = false }
	local real = detect.is_test_command
	detect.is_test_command = function(_line)
		return true
	end
	S.fire("command_started", { pane = 3, line = "npx jest", cwd = "/w/repo" })
	S.fire("command_finished", { pane = 3, line = "npx jest", status = 1, took_ms = 4000 })
	detect.is_test_command = real
	eq(#S.writes, 1)
	eq(S.writes[1].text, "qf demo-app collect qualflare-results/jest.json")
	eq(S.toasts[1][2], "1 new test report(s)")
end)

test("no upload offer when the run wrote nothing new", function()
	S.process["find /w/repo/qualflare-results"] = { status = 0, stdout = "", stderr = "", timed_out = false }
	local real = detect.is_test_command
	detect.is_test_command = function(_line)
		return true
	end
	S.fire("command_started", { pane = 3, line = "npx jest", cwd = "/w/repo" })
	S.fire("command_finished", { pane = 3, line = "npx jest", status = 0, took_ms = 4000 })
	detect.is_test_command = real
	eq(#S.writes, 0)
end)

---------------------------------------------------------------------------
-- window.luau
---------------------------------------------------------------------------

require("../window")

test("window registers commands and Carly exports", function()
	for _, id in { "launches", "upload", "dashboard", "fix", "toggle_prompt" } do
		assert(S.commands[id], "command " .. id)
	end
	assert(S.exports.launches and S.exports.clusters and S.exports.project, "exports")
end)

test("Show launches opens the block in a pane beside the focused one", function()
	S.panes = { { pane = 3, cwd = "/w/repo/packages/web", title = "" } }
	local cx = S.window_cx(3)
	S.commands.launches.run(cx)
	eq(cx.blocks[1][1], "qualflare.launches")
	eq(cx.blocks[1][2][1], "acme-web")
	eq(cx.blocks[1][3], "beside")
end)

test("Fix with omp starts an agent on qf-fix at the project root", function()
	S.panes = { { pane = 3, cwd = "/w/repo/src", title = "" } }
	S.commands.fix.run(S.window_cx(3))
	eq(S.runs[1][1], "agent")
	eq(S.runs[1][2], "/skill:qf-fix")
	eq(S.runs[1][3], "/w/repo")
end)

test("route opens launch links from terminals in the tab", function()
	S.kv.known_identifiers = { "demo-app" }
	S.panes = { { pane = 1, kind = "terminal", cwd = "/w/repo", title = "" } }
	local d = S.routes[1]({ url = "https://app.qualflare.com/project/demo-app/launches?p=launch&p.seq=42", pane = 1, mods = {} }, S.window_cx(1))
	eq(d.block, "qualflare.launches")
	eq(d.args[1], "demo-app")
	eq(d.args[2], "42")
end)

test("route knows the focused pane's project without qf projects", function()
	S.kv.known_identifiers = nil
	S.files["/w/repo/.qualflare/test-state.md"] = STATE
	S.panes = { { pane = 1, kind = "terminal", cwd = "/w/repo/packages/web", title = "" } }
	local d = S.routes[1]({ url = "https://app.qualflare.com/project/acme-web/launches?p=launch&p.seq=3", pane = 1, mods = {} }, S.window_cx(1))
	eq(d.args[1], "acme-web")
end)

test("route ignores links from non-terminal panes", function()
	S.kv.known_identifiers = { "demo-app" }
	S.panes = { { pane = 2, kind = "plugin", cwd = "", title = "" } }
	eq(S.routes[1]({ url = "https://app.qualflare.com/project/demo-app/launches?p=launch&p.seq=42", pane = 2, mods = {} }, S.window_cx(2)), nil)
end)

test("route passes links for unknown slugs", function()
	S.kv.known_identifiers = { "demo-app" }
	S.panes = { { pane = 1, kind = "terminal", cwd = "/elsewhere", title = "" } }
	eq(S.routes[1]({ url = "https://app.qualflare.com/project/other/launches?p=launch&p.seq=1", pane = 1, mods = {} }, S.window_cx(1)), nil)
end)

test("route_links=false passes every Qualflare link", function()
	S.kv.known_identifiers = { "demo-app" }
	S.kv.route_links = false
	S.panes = { { pane = 1, kind = "terminal", cwd = "/w/repo", title = "" } }
	eq(S.routes[1]({ url = "https://app.qualflare.com/project/demo-app/launches?p=launch&p.seq=42", pane = 1, mods = {} }, S.window_cx(1)), nil)
	S.kv.route_links = nil
end)

test("bridge fix starts omp at the project root; upload types into a terminal", function()
	S.files["/w/repo/.qualflare/test-state.md"] = STATE
	S.files["/w/repo/qualflare-results/.keep"] = ""
	S.panes = { { pane = 3, kind = "plugin", cwd = "", title = "", block = "qualflare.launches" } }
	local cx = S.window_cx(3)
	local d = S.routes[1]({ url = "qualflare-tern:fix?id=demo-app&root=%2Fw%2Frepo", pane = 3, mods = {} }, cx)
	eq(d.handled, true)
	local r = S.runs[#S.runs]
	eq(r[2], "/skill:qf-fix")
	eq(r[3], "/w/repo")
	S.panes = {
		{ pane = 3, kind = "plugin", cwd = "", title = "", block = "qualflare.launches" },
		{ pane = 5, kind = "terminal", cwd = "/elsewhere", title = "", at_prompt = true },
		{ pane = 4, kind = "terminal", cwd = "/w/repo", title = "", at_prompt = true },
	}
	S.routes[1]({ url = "qualflare-tern:upload?id=demo-app&root=%2Fw%2Frepo", pane = 3, mods = {} }, cx)
	eq(S.writes[#S.writes].pane, 4)
	has(S.writes[#S.writes].text, "qf demo-app collect qualflare-results")
end)

test("bridge upload with no terminal in the project says where to open one", function()
	S.files["/w/repo/.qualflare/test-state.md"] = STATE
	S.files["/w/repo/qualflare-results/.keep"] = ""
	S.panes = { { pane = 3, kind = "plugin", cwd = "", title = "", block = "qualflare.launches" } }
	S.routes[1]({ url = "qualflare-tern:upload?id=demo-app&root=%2Fw%2Frepo", pane = 3, mods = {} }, S.window_cx(3))
	eq(#S.writes, 0)
	has(S.toasts[#S.toasts][2], "Open a terminal in /w/repo")
end)

---------------------------------------------------------------------------
-- Final review fixes
---------------------------------------------------------------------------

local function key(name: string): any
	return { name = name, ctrl = false, alt = false, shift = false, meta = false }
end

local function plain_projects()
	S.kv.qf_path = "/bin/qf"
	qf.reset()
	S.process["/bin/qf projects"] = { status = 0, stdout = "demo-app\nweb\n", stderr = "", timed_out = false }
	S.process["/bin/qf demo-app launches list"] = { status = 0, stdout = LAUNCHES, stderr = "", timed_out = false }
	S.process["/bin/qf web launches list"] = { status = 0, stdout = LAUNCHES, stderr = "", timed_out = false }
end

test("review: a restored tab keeps its saved project over launch args", function()
	plain_projects()
	local B = S.blocks.launches
	local s = B.init(S.block_cx(20, nil), { "demo-app", "42" }, { identifier = "web", selected = 41 })
	eq(s.identifier, "web")
	eq(s.selected, 41)
end)

test("review: the refresh timer stops once the tab's pane is gone", function()
	plain_projects()
	S.panes = { { pane = 21, title = "" } }
	local B = S.blocks.launches
	B.init(S.block_cx(21, nil), { "demo-app" }, nil)
	local t = S.timers[#S.timers]
	S.panes = {}
	local before = #S.runs
	t.fn()
	eq(#S.runs, before, "no qf run after the pane closed")
	eq(#S.timers, 1, "no new timer scheduled")
	S.panes = {}
end)

test("review: refresh keeps Show more pages, dedupes and keeps the selection", function()
	S.kv.qf_path = "/bin/qf"
	qf.reset()
	S.process["/bin/qf pg launches list"] = { status = 0, stdout = '{"items":[{"seq":4,"status":"passed"},{"seq":3,"status":"passed"}],"paging":{"page":1,"pages":2}}', stderr = "", timed_out = false }
	S.process["/bin/qf pg launches list --page 2"] = { status = 0, stdout = '{"items":[{"seq":3,"status":"passed"},{"seq":1,"status":"passed"}],"paging":{"page":2,"pages":2}}', stderr = "", timed_out = false }
	local B = S.blocks.launches
	local cx = S.block_cx(22, nil)
	local s = B.init(cx, { "pg" }, nil)
	B.event(s, { ev = "action", act = "more" }, cx)
	eq(#s.launches, 3, "duplicate #3 dropped")
	B.event(s, { ev = "select", item = "launch=1" }, cx)
	B.key(s, key("r"), cx)
	eq(#s.launches, 3, "refresh keeps the extra page")
	eq(s.selected, 1)
end)

test("review: a link to an older launch fetches and shows it", function()
	plain_projects()
	S.process["/bin/qf demo-app launch get 5"] = { status = 0, stdout = '{"seq":5,"status":"failed","totalCount":3,"passedCount":1,"failedCount":2,"branch":"old-branch"}', stderr = "", timed_out = false }
	local B = S.blocks.launches
	local cx = S.block_cx(23, nil)
	local s = B.init(cx, { "demo-app", "5" }, nil)
	eq(s.selected, 5)
	has(S.text(B.view(s, cx).main), "old-branch")
end)

test("review: the project menu takes arrow keys and Enter while open", function()
	plain_projects()
	local B = S.blocks.launches
	local cx = S.block_cx(24, nil)
	local s = B.init(cx, { "demo-app" }, nil)
	local opened = #S.opened
	B.key(s, key("p"), cx)
	B.key(s, key("down"), cx)
	B.key(s, key("enter"), cx)
	eq(s.identifier, "web")
	eq(s.menu_open, false)
	eq(#S.opened, opened, "Enter in the menu doesn't open the website")
end)

test("review: qf projects' no-projects sentence isn't a project", function()
	S.kv.qf_path = "/bin/qf"
	qf.reset()
	S.process["/bin/qf projects"] = { status = 0, stdout = "No projects configured. Run 'qf login <identifier> <token>' to get started.\n", stderr = "", timed_out = false }
	S.kv.known_identifiers = { "stale" }
	local B = S.blocks.launches
	local s = B.init(S.block_cx(25, "/nowhere"), {}, nil)
	eq(s.identifier, nil)
	eq(#s.projects, 0)
	eq(#S.kv.known_identifiers, 0)
end)

test("review: hand-offs use the shown project's folder, or are refused", function()
	plain_projects()
	S.files["/w/repo/.qualflare/test-state.md"] = STATE
	S.process["/bin/qf other launches list"] = { status = 0, stdout = LAUNCHES, stderr = "", timed_out = false }
	local B = S.blocks.launches
	local cx = S.block_cx(26, "/w/repo")
	local s = B.init(cx, { "demo-app" }, nil)
	B.event(s, { ev = "change", id = "main.head.start.project", value = "other" }, cx)
	local opened = #S.opened
	B.event(s, { ev = "action", act = "upload" }, cx)
	eq(#S.opened, opened, "no hand-off for a project outside this folder")
	has(S.toasts[#S.toasts][2], "other")
	B.event(s, { ev = "change", id = "main.head.start.project", value = "acme-web" }, cx)
	B.event(s, { ev = "action", act = "upload" }, cx)
	has(S.opened[#S.opened], "id=acme-web")
	has(S.opened[#S.opened], "root=%2Fw%2Frepo")
end)

test("review: upload skips parked panes and prefers the tab's own tab, then focuses it", function()
	S.files["/w/repo/.qualflare/test-state.md"] = STATE
	S.files["/w/repo/qualflare-results/.keep"] = ""
	S.panes = {
		{ pane = 3, kind = "plugin", cwd = "", title = "", tab = 1, block = "qualflare.launches" },
		{ pane = 6, kind = "terminal", cwd = "/w/repo", title = "", at_prompt = true, parked = true },
		{ pane = 7, kind = "terminal", cwd = "/w/repo", title = "", at_prompt = true, tab = 2 },
		{ pane = 8, kind = "terminal", cwd = "/w/repo", title = "", at_prompt = true, tab = 1 },
	}
	S.routes[1]({ url = "qualflare-tern:upload?id=demo-app&root=%2Fw%2Frepo", pane = 3, mods = {} }, S.window_cx(3))
	eq(S.writes[#S.writes].pane, 8)
	eq(S.focused_panes[#S.focused_panes], 8)
end)

test("review: hand-off links only work from the Qualflare tab, for its project", function()
	S.files["/w/repo/.qualflare/test-state.md"] = STATE
	S.files["/w/repo/qualflare-results/.keep"] = ""
	S.panes = {
		{ pane = 1, kind = "terminal", cwd = "/w/repo", title = "", at_prompt = true },
		{ pane = 3, kind = "plugin", cwd = "", title = "", block = "qualflare.launches" },
	}
	local agents = #S.runs
	S.routes[1]({ url = "qualflare-tern:fix?id=demo-app&root=%2Fw%2Frepo", pane = 1, mods = {} }, S.window_cx(1))
	eq(#S.runs, agents, "a terminal can't start omp through a hand-off link")
	S.routes[1]({ url = "qualflare-tern:fix?id=demo-app&root=%2FUsers%2Fsomeone", pane = 3, mods = {} }, S.window_cx(3))
	eq(#S.runs, agents, "no omp in a folder that isn't the project")
	S.files["/w/repo/.qualflare/test-state.md"] = STATE .. "| other | x; curl evil |\n"
	S.routes[1]({ url = "qualflare-tern:upload?id=x%3B%20curl%20evil&root=%2Fw%2Frepo", pane = 3, mods = {} }, S.window_cx(3))
	for _, w in S.writes do
		assert(not string.find(w.text, "qf x; curl", 1, true), "identifier typed unquoted: " .. w.text)
	end
end)

test("review: the plugin's own website opens aren't routed back into the tab", function()
	S.kv.known_identifiers = { "demo-app" }
	S.panes = { { pane = 1, kind = "terminal", cwd = "/w/repo", title = "" } }
	local L = S.lenses.list
	local ls = L.open({ line = "", typed = "", program = "qf", args = { "demo-app", "launches", "list" } }, S.effect_cx())
	for _, l in lines(LAUNCHES) do
		L.line(ls, l)
	end
	L.finish(ls, 0)
	L.event(ls, { ev = "activate", item = "launch=42" }, S.effect_cx())
	local url = S.opened[#S.opened]
	eq(S.routes[1]({ url = url, pane = 1, mods = {} }, S.window_cx(1)), nil)
end)

---------------------------------------------------------------------------
-- Test-run detection: the rules in lib/detect.luau
---------------------------------------------------------------------------

local SHOULD = {
	-- 1. runners by name
	"npx jest",
	"jest --watch",
	"pnpm exec vitest run",
	"mocha test/",
	"pytest -q tests/",
	"python3 -m pytest -k login",
	"detox test -c ios.sim.release",
	"maestro test flows/",
	"qualflare-go ./...",
	"qualflare-maestro test flows/",
	-- 2. subcommands
	"go test ./...",
	"flutter test",
	"dart test",
	"CI=1 npx playwright test --project=chromium",
	"npx cypress run --spec cypress/e2e/login.cy.ts",
	"npx wdio run ./wdio.conf.ts",
	"./gradlew test",
	"./gradlew :app:connectedAndroidTest",
	"gradle cleanTest test",
	"mvn -q verify",
	"./mvnw test",
	"npm test",
	"npm t",
	"yarn test",
	"bun test",
	-- 3. named scripts
	"npm run test:e2e",
	"pnpm test:unit",
	"yarn run test-ci",
	"pnpm e2e",
	"make test",
	"make -j4 test-e2e",
	"just e2e",
}
local SHOULD_NOT = {
	"ls",
	"git status",
	"npm run build",
	"npm install",
	"go build ./...",
	"go vet ./...",
	"npx playwright install",
	"npx cypress open",
	"flutter run",
	"./gradlew build",
	"mvn package",
	"python3 app.py",
	"make",
	"make build",
	"qf demo collect x.xml",
}

---------------------------------------------------------------------------
-- Qualflare pane v2: clusters and live refresh
---------------------------------------------------------------------------

local CLUSTERS_CMD = "/bin/qf demo-app clusters list --sort-by lastSeenAt --sort-desc"
local FOUR_CLUSTERS = '{"items":[{"id":1,"label":"a"},{"id":2,"label":"b"},{"id":3,"label":"c"},{"id":4,"label":"d"}],"paging":{}}'
local NEWER = '{"items":[{"seq":43,"status":"passed","totalCount":120,"passedCount":120}, {"seq":42,"status":"failed","totalCount":120,"passedCount":110,"failedCount":8}],"paging":{"page":1,"pages":1}}'

local function ran(cmd: string): number
	local n = 0
	for _, argv in S.runs do
		if table.concat(argv, " ") == cmd then
			n += 1
		end
	end
	return n
end

test("v2: a failing newest launch fetches the three newest clusters", function()
	plain_projects()
	S.process[CLUSTERS_CMD] = { status = 0, stdout = FOUR_CLUSTERS, stderr = "", timed_out = false }
	local s = S.blocks.launches.init(S.block_cx(41, nil), { "demo-app" }, nil)
	eq(ran(CLUSTERS_CMD), 1)
	eq(#s.clusters, 3)
	eq(s.clusters[1].label, "a")
	S.process[CLUSTERS_CMD] = nil
end)

test("v2: a passing newest launch skips clusters", function()
	plain_projects()
	S.process["/bin/qf ok launches list"] = { status = 0, stdout = '{"items":[{"seq":2,"status":"passed","totalCount":1,"passedCount":1}],"paging":{}}', stderr = "", timed_out = false }
	local s = S.blocks.launches.init(S.block_cx(42, nil), { "ok" }, nil)
	eq(ran("/bin/qf ok clusters list --sort-by lastSeenAt --sort-desc"), 0)
	eq(s.clusters, nil)
end)

test("v2: a failed clusters call hides them without an error", function()
	plain_projects()
	S.process[CLUSTERS_CMD] = { status = 3, stdout = "", stderr = "no token loaded", timed_out = false }
	local s = S.blocks.launches.init(S.block_cx(43, nil), { "demo-app" }, nil)
	eq(s.clusters, nil)
	eq(s.error, nil)
	eq(#s.launches, 2)
	S.process[CLUSTERS_CMD] = { status = 0, stdout = "not json", stderr = "", timed_out = false }
	S.blocks.launches.key(s, key("r"), S.block_cx(43, nil))
	eq(s.clusters, nil)
	S.process[CLUSTERS_CMD] = nil
end)

test("v2: a cluster row opens the cluster on the website", function()
	plain_projects()
	local B = S.blocks.launches
	local cx = S.block_cx(44, nil)
	local s = B.init(cx, { "demo-app" }, nil)
	B.event(s, { ev = "activate", item = "cluster=7" }, cx)
	eq(S.opened[#S.opened], "https://app.qualflare.com/project/demo-app/clusters/7?src=tern")
	B.event(s, { ev = "action", act = "cluster=8" }, cx)
	eq(S.opened[#S.opened], "https://app.qualflare.com/project/demo-app/clusters/8?src=tern")
	eq(s.selected, nil, "a cluster isn't a launch selection")
end)

test("v2: an upload refreshes open panes on that project only, and marks the new launch", function()
	plain_projects()
	local B = S.blocks.launches
	S.panes = { { pane = 51, title = "" }, { pane = 52, title = "" } }
	local a = B.init(S.block_cx(51, nil), { "demo-app" }, nil)
	local b = B.init(S.block_cx(52, nil), { "web" }, nil)
	local closed = B.init(S.block_cx(53, nil), { "demo-app" }, nil)
	S.process["/bin/qf demo-app launches list"] = { status = 0, stdout = NEWER, stderr = "", timed_out = false }
	local web_runs = ran("/bin/qf web launches list")
	S.fire("command_finished", { pane = 9, line = "qf demo-app collect r.xml", status = 1, took_ms = 5 })
	eq(a.launches[1].seq, 42, "a failed upload refreshes nothing")
	S.fire("command_finished", { pane = 9, line = "qf demo-app collect r.xml", status = 0, took_ms = 5 })
	eq(a.launches[1].seq, 43)
	eq(a.selected, 43)
	eq(a.fresh, 43)
	has(S.text(B.view(a, S.block_cx(51, nil)).main), "new")
	eq(b.launches[1].seq, 42)
	eq(ran("/bin/qf web launches list"), web_runs, "another project's pane isn't refreshed")
	eq(closed.launches[1].seq, 42, "a closed pane isn't refreshed")
	B.key(a, key("r"), S.block_cx(51, nil))
	eq(a.fresh, nil, "an ordinary refresh clears the mark")
	S.panes = {}
	S.process["/bin/qf demo-app launches list"] = { status = 0, stdout = LAUNCHES, stderr = "", timed_out = false }
end)

test("v2: an upload not listed yet is retried once", function()
	plain_projects()
	local B = S.blocks.launches
	S.panes = { { pane = 61, title = "" } }
	local a = B.init(S.block_cx(61, nil), { "demo-app" }, nil)
	local timers = #S.timers
	S.fire("command_finished", { pane = 9, line = "qf demo-app collect r.xml", status = 0, took_ms = 5 })
	eq(a.fresh, nil)
	eq(#S.timers, timers + 1, "one retry scheduled")
	S.process["/bin/qf demo-app launches list"] = { status = 0, stdout = NEWER, stderr = "", timed_out = false }
	S.timers[#S.timers].fn()
	eq(a.fresh, 43)
	eq(a.selected, 43)
	eq(#S.timers, timers + 1, "no second retry")
	S.panes = {}
	S.process["/bin/qf demo-app launches list"] = { status = 0, stdout = LAUNCHES, stderr = "", timed_out = false }
end)

test("v2: a pane saved by 0.2.0 restores", function()
	plain_projects()
	local B = S.blocks.launches
	local cx = S.block_cx(71, nil)
	local launches = (tern.json.decode(LAUNCHES) :: any).items
	local s = B.init(cx, { "demo-app" }, { identifier = "demo-app", launches = launches, selected = 41, refreshed = 1 })
	eq(s.selected, 41)
	has(S.text(B.view(s, cx).main), "8 of 120 failing")
end)

test("review2: pressing R while the upload refresh is in flight still marks the new launch", function()
	plain_projects()
	local B = S.blocks.launches
	S.panes = { { pane = 81, title = "" } }
	local cx = S.block_cx(81, nil)
	local a = B.init(cx, { "demo-app" }, nil)
	S.process["/bin/qf demo-app launches list"] = { status = 0, stdout = NEWER, stderr = "", timed_out = false }
	S.defer = true
	S.fire("command_finished", { pane = 9, line = "qf demo-app collect r.xml", status = 0, took_ms = 5 })
	B.key(a, key("r"), cx)
	S.flush()
	S.defer = false
	eq(a.selected, 43)
	eq(a.fresh, 43)
	S.panes = {}
	S.process["/bin/qf demo-app launches list"] = { status = 0, stdout = LAUNCHES, stderr = "", timed_out = false }
end)

test("review2: a launch listed before collect finished still counts as the upload's", function()
	plain_projects()
	local B = S.blocks.launches
	S.panes = { { pane = 82, title = "" } }
	local now = os.time()
	local just = os.date("!%Y-%m-%dT%H:%M:%SZ", now - 3)
	local list = `\{"items":[\{"seq":43,"status":"passed","totalCount":1,"passedCount":1,"createdAt":"{just}"},\{"seq":42,"status":"failed","totalCount":1,"failedCount":1,"createdAt":"2026-01-01T00:00:00Z"}],"paging":\{}}`
	S.process["/bin/qf demo-app launches list"] = { status = 0, stdout = list, stderr = "", timed_out = false }
	local a = B.init(S.block_cx(82, nil), { "demo-app" }, nil)
	eq(a.launches[1].seq, 43, "already listed")
	S.fire("command_finished", { pane = 9, line = "qf demo-app collect r.xml", status = 0, took_ms = 8000 })
	eq(a.selected, 43)
	eq(a.fresh, 43)
	S.panes = {}
	S.process["/bin/qf demo-app launches list"] = { status = 0, stdout = LAUNCHES, stderr = "", timed_out = false }
end)

test("review2: what changed compares with the last run on the same branch and environment", function()
	local launches = {
		{ seq = 42, branch = "feat/checkout", environmentName = "Staging", totalCount = 10, failedCount = 4 },
		{ seq = 41, branch = "main", environmentName = "Production", totalCount = 10, failedCount = 0 },
		{ seq = 40, branch = "feat/checkout", environmentName = "Staging", totalCount = 10, failedCount = 1 },
	}
	local t = S.text(tab.view(st({ launches = launches })).main)
	has(t, "3 more failing than #40")
	no(t, "than #41")
	local other = S.text(tab.view(st({ launches = { launches[1], launches[2] } })).main)
	no(other, "than #41")
	no(other, "Same counts")
end)

test("review2: where to look keeps clusters seen since the newest run, with ages", function()
	local newest = { seq = 9, status = "failed", totalCount = 2, failedCount = 1, createdAt = "2026-11-15T12:00:00Z" }
	local clusters = {
		{ id = 1, label = "fresh one", lastSeenAt = "2026-11-15T12:05:00Z" },
		{ id = 2, label = "old one", lastSeenAt = "2026-11-08T12:00:00Z" },
	}
	local now = views.epoch("2026-11-15T14:05:00Z") :: number
	local t = S.text(tab.view(st({ launches = { newest }, clusters = clusters, now = now })).main)
	has(t, "fresh one")
	no(t, "old one")
	has(t, "2 h ago")
	no(S.text(tab.view(st({ launches = { newest }, clusters = { clusters[2] }, now = now })).main), "Where to look")
end)

test("review2: switching project drops the old project's clusters and mark", function()
	plain_projects()
	S.process[CLUSTERS_CMD] = { status = 0, stdout = FOUR_CLUSTERS, stderr = "", timed_out = false }
	local B = S.blocks.launches
	local cx = S.block_cx(83, nil)
	local s = B.init(cx, { "demo-app" }, nil)
	eq(#s.clusters, 3)
	s.fresh = 42
	S.defer = true
	B.event(s, { ev = "change", id = "main.head.start.project", value = "web" }, cx)
	eq(s.clusters, nil)
	eq(s.fresh, nil)
	S.flush()
	S.defer = false
	S.process[CLUSTERS_CMD] = nil
end)

test("polish: a newest run marked failed without counts still fetches clusters", function()
	plain_projects()
	S.process["/bin/qf bare launches list"] = { status = 0, stdout = '{"items":[{"seq":3,"status":"failed","totalCount":0}],"paging":{}}', stderr = "", timed_out = false }
	S.blocks.launches.init(S.block_cx(91, nil), { "bare" }, nil)
	eq(ran("/bin/qf bare clusters list --sort-by lastSeenAt --sort-desc"), 1)
end)

test("Ctrl-C and signals don't get the upload prompt", function()
	eq(detect.finished_normally(0), true)
	eq(detect.finished_normally(1), true)
	eq(detect.finished_normally(130), false)
	eq(detect.finished_normally(137), false)
	eq(detect.finished_normally(-1), false)
	S.files["/w/repo/.qualflare/test-state.md"] = STATE
	S.files["/w/repo/qualflare-results/.keep"] = ""
	S.panes = { { pane = 3, cwd = "/w/repo", program = "zsh", title = "", busy = false } }
	S.process["find /w/repo/qualflare-results"] = { status = 0, stdout = "/w/repo/qualflare-results/jest.json\n", stderr = "", timed_out = false }
	S.fire("command_started", { pane = 3, line = "npx jest", cwd = "/w/repo" })
	S.fire("command_finished", { pane = 3, line = "npx jest", status = 130, took_ms = 2000 })
	eq(#S.writes, 0)
end)

local any_true = false
for _, l in SHOULD do
	any_true = any_true or detect.is_test_command(l)
end
if not any_true then
	pending += 1
	print("PENDING is_test_command: write the rules in lib/detect.luau")
else
	for _, l in SHOULD do
		test("is a test run: " .. l, function()
			eq(detect.is_test_command(l), true)
		end)
	end
	for _, l in SHOULD_NOT do
		test("is not a test run: " .. l, function()
			eq(detect.is_test_command(l), false)
		end)
	end
end


---------------------------------------------------------------------------
-- Qualflare tab helpers
---------------------------------------------------------------------------

test("views.ago buckets relative times", function()
	local t = views.epoch("2026-11-16T12:00:00Z") :: number
	eq(views.epoch("2026-11-16T12:00:00.123456Z"), t)
	eq(views.ago("2026-11-16T12:00:00Z", t + 30), "just now")
	eq(views.ago("2026-11-16T12:00:00Z", t + 300), "5 min ago")
	eq(views.ago("2026-11-16T12:00:00Z", t + 3 * 3600), "3 h ago")
	eq(views.ago("2026-11-16T12:00:00Z", t + 2 * 86400), "2 d ago")
	eq(views.ago("2026-11-16T12:00:00Z", t + 8 * 86400), "8 d ago")
	eq(views.ago("2026-11-16T12:00:00Z", t + 40 * 86400), "Nov 16")
	eq(views.ago("2026-11-16T12:00:00Z", t + 400 * 86400), "Nov 16, 2026")
	eq(views.ago(t, t + 400 * 86400), "400 d ago")
	eq(views.days("2026-11-16T12:00:00Z", t + 8 * 86400 + 5), 8)
	eq(views.days(nil, t), nil)
	eq(views.ago(nil, t), "")
	eq(views.epoch("2000-03-01T00:00:00Z"), 951868800) -- leap-year arithmetic
end)

test("views.change compares a launch with the one before", function()
	local prev = { seq = 41, totalCount = 118, failedCount = 0 }
	eq(views.change({ seq = 42, totalCount = 120, failedCount = 7, errorCount = 1 }, prev), "+2 tests · 8 more failing than #41")
	eq(views.change({ seq = 42, totalCount = 115, failedCount = 0 }, { seq = 41, totalCount = 118, failedCount = 3 }), "−3 tests · 3 fewer failing than #41")
	eq(views.change({ seq = 42, totalCount = 118 }, prev), "Same counts as #41")
	eq(views.change({ seq = 42, totalCount = 118, failedCount = 1 }, prev), "1 more failing than #41")
end)

test("views.failed adds failures, errors and timeouts", function()
	eq(views.failed({ failedCount = 7, errorCount = 1, timeoutCount = 2 }), 10)
	eq(views.failed({}), 0)
end)

test("views.summary tolerates null, pending and bad JSON", function()
	eq(views.summary({}), nil)
	eq(views.summary({ aiSummary = tern.json.null }), nil)
	eq(views.summary({ aiSummary = "not json" }), nil)
	eq(views.summary({ aiSummary = '{"executiveSummary":""}' }), nil)
	local s = views.summary({ aiSummary = '{"executiveSummary":"Checkout broke.","riskLevel":"medium","riskJustification":"Payments fail.","failingAreas":[{"area":"checkout","description":"card form"}, "login"],"recommendations":["Fix the form."]}' }) :: any
	eq(s.text, "Checkout broke.")
	eq(s.risk, "medium")
	eq(s.why, "Payments fail.")
	eq(#s.areas, 2)
	has(s.areas[1], "checkout")
	has(s.areas[1], "card form")
	eq(s.areas[2], "login")
	eq(s.recommendations[1], "Fix the form.")
end)

test("links parse launch URLs and the bridge", function()
	local l = links.launch_from_url("https://app.qualflare.com/project/acme-web/launches?p=launch&p.seq=128") :: any
	eq(l.slug, "acme-web")
	eq(l.seq, 128)
	local l2 = links.launch_from_url("https://app.qualflare.com/project/acme-web/launches?p.seq=7&p=launch") :: any
	eq(l2.seq, 7)
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
	eq(action, "fix")
	eq(params.root, "/w/my repo")
	eq((links.parse_bridge("https://x")), nil)
end)

test("qf.lines returns trimmed non-empty lines", function()
	S.kv.qf_path = "/bin/qf"
	qf.reset()
	S.process["/bin/qf projects"] = { status = 0, stdout = "app-landing\n stage\n\nstarter\n", stderr = "", timed_out = false }
	local got: any
	qf.lines({ "projects" }, nil, function(r)
		got = r
	end)
	eq(got.ok, true)
	eq(#got.lines, 3)
	eq(got.lines[2], "stage")
end)


---------------------------------------------------------------------------
-- Qualflare tab page
---------------------------------------------------------------------------


-- The first node in a view tree that `pred` accepts.
local function find(n: any, pred: (any) -> boolean): any
	if type(n) ~= "table" then
		return nil
	end
	if type(n.k) == "string" and pred(n) then
		return n
	end
	for _, v in n do
		local got = find(v, pred)
		if got then
			return got
		end
	end
	return nil
end
local function keyed(key: string): (any) -> boolean
	return function(n)
		return type(n.p) == "table" and n.p.key == key
	end
end

test("tab: launches page has head, verdict, change, trend, table and the selected card", function()
	local launches = (tern.json.decode(LAUNCHES) :: any).items
	local v = tab.view(st({ launches = launches, selected = launches[2].seq, refreshed = 1763294400 - 60 }))
	local t = S.text(v.main)
	has(t, "Qualflare")
	has(t, "updated 1 min ago")
	has(t, "8 of 120 failing")
	no(t, "than #41") -- #41 is on another branch: no like-for-like comparison
	no(S.kind_list(v.main), "stats")
	has(S.kind_list(v.main), "chart")
	has(t, "#" .. tostring(launches[2].seq))
	has(t, "Open on website")
	has(S.kind_list(v.main), "select")
	has(S.text(v.dock), "R refresh")
	eq(tab.selected_launch(st({ launches = launches, selected = 41 })).seq, 41)
	eq(tab.selected_launch(st({ launches = launches })).seq, 42)
	eq(find(v.main, keyed("launches")).p.wrap, true, "table and card wrap in a narrow pane")
end)

test("tab: table and card share the row by starting widths, so the card sits beside the table", function()
	local launches = (tern.json.decode(LAUNCHES) :: any).items
	local v = tab.view(st({ launches = launches }))
	local list = find(v.main, keyed("list"))
	local card = find(v.main, keyed("detail"))
	eq(list.p.basis, 0.6)
	eq(card.p.basis, 0.36)
	-- room for both: 60% + 36% + the gap fits, so wrap only kicks in when the minimums don't
	assert(list.p.basis + card.p.basis < 1)
end)

test("views: launches table hides Branch and Environment when no run has one", function()
	local function heads(n: any): string
		local t = {}
		for _, c in n.p.cols do
			table.insert(t, c.head)
		end
		return table.concat(t, ",")
	end
	local bare = views.launches_table({ { seq = 1, status = "passed", environmentName = "Staging", branch = tern.json.null } }, { now = 0, buttons = false })
	no(heads(bare), "Branch")
	has(heads(bare), "Environment")
	eq(#bare.p.rows[1].cells, #bare.p.cols, "one cell per column")
	local full = views.launches_table({ { seq = 1, status = "passed", branch = "main" } }, { now = 0 })
	has(heads(full), "Branch")
	no(heads(full), "Environment")
	eq(#full.p.rows[1].cells, #full.p.cols)
end)

test("polish: a run marked failed counts as failing even without failure counts", function()
	eq(views.failing({ failedCount = 1 }), true)
	eq(views.failing({ status = "failed" }), true)
	eq(views.failing({ status = "error" }), true)
	eq(views.failing({ status = "timeout" }), true)
	eq(views.failing({ status = "passed" }), false)
	eq(views.failing({ status = "running" }), false)
	local bare = { seq = 3, status = "failed", totalCount = 10, passedCount = 10, environmentName = "Staging" }
	local v = tab.verdict(bare, 0)
	eq(v.tone, "error")
	has(v.text, "✗ Latest run failed · Staging")
	local view = tab.view(st({ launches = { bare, { seq = 2, status = "passed", totalCount = 1, passedCount = 1 } }, clusters = { { id = 1, label = "boom" } } }))
	local chart = find(view.main, function(n)
		return n.k == "chart"
	end)
	eq(chart.p.series[2].tone, "error", "its bar is red")
	has(S.text(view.main), "Fix with omp")
	has(S.text(view.main), "Where to look")
end)

test("polish: failures with no total don't read as 'of 0'", function()
	local v = tab.verdict({ failedCount = 3 }, 0)
	has(v.text, "✗ 3 failing")
	no(v.text, "of 0")
end)

test("polish: trend bars are tall enough to tell 92% from 100%", function()
	local launches = (tern.json.decode(LAUNCHES) :: any).items
	local chart = find(tab.view(st({ launches = launches })).main, function(n)
		return n.k == "chart"
	end)
	eq(chart.p.size, "md")
end)

test("tab: verdict reads failing, passed and other states", function()
	local launches = (tern.json.decode(LAUNCHES) :: any).items
	local now = 1763294400
	local f = tab.verdict(launches[1], now)
	eq(f.tone, "error")
	has(f.text, "✗ 8 of 120 failing · feat/checkout · staging · ")
	local p = tab.verdict(launches[2], now)
	eq(p.tone, "success")
	has(p.text, "✓ Latest run passed · 118 tests · staging · ")
	no(p.text, "no branch")
	has(tab.verdict({ status = "running" }, now).text, "● Latest run running")
	has(tab.verdict({ status = "passed", totalCount = 0 }, now).text, "Latest run passed")
	has(tab.verdict({}, now).text, "Latest run")
end)

test("tab: one launch has no trend and no change line", function()
	local launches = (tern.json.decode(LAUNCHES) :: any).items
	local v = tab.view(st({ launches = { launches[2] } }))
	no(S.kind_list(v.main), "chart")
	no(S.text(v.main), "than #")
	no(S.text(v.main), "Same counts")
end)

test("tab: trend bars run oldest to newest, red where runs failed", function()
	local launches = (tern.json.decode(LAUNCHES) :: any).items
	local chart = find(tab.view(st({ launches = launches })).main, function(n)
		return n.k == "chart"
	end)
	eq(chart.p.kind, "bars")
	eq(#chart.p.series, 2)
	has(chart.p.series[1].title, "#41")
	eq(chart.p.series[1].value, 100)
	eq(chart.p.series[2].tone, "error")
	eq(chart.p.series[2].value, 92) -- 110 of 120
	-- a launch with no tests counts as 0, not NaN
	local zero = find(tab.view(st({ launches = { { seq = 2, totalCount = 0 }, { seq = 1 } } })).main, function(n)
		return n.k == "chart"
	end)
	eq(zero.p.series[1].value, 0)
end)

test("tab: an old newest run says how long ago the last run was", function()
	local launches = (tern.json.decode(LAUNCHES) :: any).items
	local newest = views.epoch(launches[1].createdAt) :: number
	local t = S.text(tab.view(st({ launches = launches, now = newest + 8 * 86400 + 60 })).main)
	has(t, "No runs in 8 days")
	no(S.text(tab.view(st({ launches = launches })).main), "No runs in")
end)

test("tab: the card has its status at the head and wraps its text", function()
	local l = { seq = 5, status = "failed", environmentName = "Staging", totalCount = 10, passedCount = 9, failedCount = 1, framework = "junit", os = "darwin/arm64", aiSummary = '{"executiveSummary":"Checkout broke.","riskLevel":"low","riskJustification":"Only one test.","failingAreas":["checkout"],"recommendations":["Continue monitoring test results for any regressions in later runs."]}' }
	local v = tab.view(st({ launches = { l } }))
	local card = find(v.main, keyed("detail"))
	eq(card.p.props["end"], "main.launches.detail.status", "end takes the badge's full id")
	has(S.text(card.p.head), "#5 · Staging")
	no(S.text(card), "no branch")
	no(S.kind_list(card), "list")
	no(S.kind_list(card), "test_summary")
	has(S.text(card), "Continue monitoring test results for any regressions in later runs.")
	has(S.text(card), "junit · darwin/arm64")
	has(S.text(card), "Only one test.")
end)

test("tab: where to look lists clusters only when the newest run failed", function()
	local launches = (tern.json.decode(LAUNCHES) :: any).items
	local clusters = (tern.json.decode(CLUSTERS) :: any).items
	local t = S.text(tab.view(st({ launches = launches, clusters = clusters })).main)
	has(t, "Where to look")
	has(t, "TimeoutError waiting for #pay-button")
	no(S.text(tab.view(st({ launches = { launches[2] }, clusters = clusters })).main), "Where to look")
	no(S.text(tab.view(st({ launches = launches })).main), "Where to look")
end)

test("tab: a launch just uploaded is marked new", function()
	local launches = (tern.json.decode(LAUNCHES) :: any).items
	has(S.text(tab.view(st({ launches = launches, fresh = 42 })).main), "new")
	no(S.text(tab.view(st({ launches = launches, fresh = 41 })).main), "| new")
end)

test("tab: Fix with omp shows only on failed launches", function()
	local launches = (tern.json.decode(LAUNCHES) :: any).items -- fixture: [1] failed, [2] passed
	has(S.text(tab.view(st({ launches = launches, selected = launches[1].seq })).main), "Fix with omp")
	assert(not string.find(S.text(tab.view(st({ launches = launches, selected = launches[2].seq })).main), "Fix with omp", 1, true))
end)

test("tab: the card shows the AI summary when there is one", function()
	local l = { seq = 5, status = "failed", totalCount = 10, passedCount = 9, failedCount = 1, aiSummary = '{"executiveSummary":"Checkout broke.","riskLevel":"high","riskJustification":"Payments fail.","failingAreas":["checkout"],"recommendations":["Fix the form."]}' }
	local t = S.text(tab.view(st({ launches = { l } })).main)
	has(t, "Checkout broke.")
	has(t, "Payments fail.")
	has(t, "Fix the form.")
end)

test("tab: Show more appears when another page exists", function()
	local launches = (tern.json.decode(LAUNCHES) :: any).items
	has(S.text(tab.view(st({ launches = launches, more = true })).main), "Show more")
	assert(not string.find(S.text(tab.view(st({ launches = launches })).main), "Show more", 1, true))
end)

test("tab: empty launches shows the empty state", function()
	local t = S.text(tab.view(st({ launches = {} })).main)
	has(t, "No launches yet")
	no(t, "Latest run")
end)

test("tab: loading, error and no-project states", function()
	has(S.kind_list(tab.view(st({ loading = true })).main), "skeleton")
	local e = S.text(tab.view(st({ error = "no token loaded", status = 3 })).main)
	has(e, "Not logged in")
	has(e, "qf login demo-app")
	has(e, "Retry")
	local none = st({})
	none.identifier = nil
	has(S.text(tab.view(none).main), "No Qualflare project here")
	-- stale data stays on screen while a refresh runs
	local launches = (tern.json.decode(LAUNCHES) :: any).items
	has(S.text(tab.view(st({ loading = true, launches = launches })).main), "8 of 120 failing")
end)

---------------------------------------------------------------------------
-- Qualflare dashboard
---------------------------------------------------------------------------

local OVERVIEW = [[{
  "window": {"from": "2026-11-11", "to": "2026-11-17", "days": 7},
  "buckets": ["2026-11-11","2026-11-12","2026-11-13","2026-11-14","2026-11-15","2026-11-16","2026-11-17"],
  "kpis": [
    {"key":"successRate","label":"Success rate","unit":"percent","latest":94.26,"previous":91,"percentChange":3.5,"trend":"up","target":95,"values":[90,null,92,93,94,94,94.26]},
    {"key":"flakeRate","label":"Flake rate","unit":"percent","latest":1,"previous":1.5,"percentChange":-33.3,"trend":"down","target":2,"values":[1,1,1,1,1,1,1]},
    {"key":"launchP90","label":"Launch p90","unit":"seconds","latest":252,"previous":233,"percentChange":8,"trend":"up","target":null,"values":[230,240,250,252,252,252,252]},
    {"key":"automationRate","label":"Automation","unit":"percent","latest":63.4,"previous":63.4,"percentChange":0,"trend":"none","target":null,"values":[63,63,63,63,63,63,63.4]},
    {"key":"defectsOpened","label":"Defects opened","unit":"count","latest":2,"previous":1,"percentChange":100,"trend":"up","target":null,"values":[0,1,0,2,1,0,2]},
    {"key":"launches","label":"Launches","unit":"count","latest":5,"previous":4,"percentChange":25,"trend":"up","target":null,"values":[3,4,5,4,3,4,5]}
  ],
  "warnings": [],
  "dataThrough": "2026-11-17T09:00:00Z"
}]]
local OV_NOW = 1794906000 -- 2026-11-17T09:00:00Z

local function dst(over: any): any
	local s: any = { identifier = "demo-app", projects = { "demo-app", "web" }, days = 7, data = nil, outdated = false, loading = false, now = OV_NOW + 300, menu_open = false }
	for k, v in over do
		s[k] = v
	end
	return s
end

test("dashboard.headline formats each unit", function()
	eq(dashboard.headline({ key = "successRate", unit = "percent", latest = 94.26 }), "94.3%")
	eq(dashboard.headline({ key = "automationRate", unit = "percent", latest = 63.4 }), "63%")
	eq(dashboard.headline({ key = "launchP90", unit = "seconds", latest = 42 }), "42s")
	eq(dashboard.headline({ key = "launchP90", unit = "seconds", latest = 252 }), "4m 12s")
	eq(dashboard.headline({ key = "launchP90", unit = "seconds", latest = 3780 }), "1h 3m")
	eq(dashboard.headline({ key = "launches", unit = "count", latest = 5 }), "5 today")
	eq(dashboard.headline({ key = "successRate", unit = "percent", latest = nil }), "–")
	eq(dashboard.headline({ key = "successRate", unit = "percent", latest = tern.json.null }), "–")
end)

test("dashboard.change colours by whether the direction is good", function()
	local none = dashboard.change({ key = "automationRate", trend = "none", percentChange = 0 }) :: any
	eq(none.text, "no change")
	eq(none.tone, "muted")
	eq(dashboard.change({ key = "successRate", trend = "neutral", percentChange = nil }), nil)
	local up = dashboard.change({ key = "successRate", trend = "up", percentChange = 3.5 }) :: any
	eq(up.text, "▲ 3.5%")
	eq(up.tone, "success")
	eq((dashboard.change({ key = "flakeRate", trend = "up", percentChange = 2 }) :: any).tone, "error")
	eq((dashboard.change({ key = "launchP90", trend = "down", percentChange = -8 }) :: any).tone, "success")
	eq((dashboard.change({ key = "launches", trend = "up", percentChange = 25 }) :: any).tone, "muted")
	eq((dashboard.change({ key = "defectsOpened", trend = "down", percentChange = -3.26 }) :: any).text, "▼ 3.3%")
end)

test("dashboard.meets compares against the target the website's way", function()
	eq(dashboard.meets({ key = "successRate", latest = 94, target = 95 }), false)
	eq(dashboard.meets({ key = "flakeRate", latest = 1, target = 2 }), true)
	eq(dashboard.meets({ key = "launchP90", latest = 300, target = 300 }), true)
	eq(dashboard.meets({ key = "successRate", latest = 94, target = nil }), nil)
	eq(dashboard.meets({ key = "successRate", latest = nil, target = 95 }), nil)
	eq(dashboard.meets({ key = "launches", latest = 5, target = 3 }), nil)
end)

test("dashboard view: six cards with lines, data age and the window buttons", function()
	local v = dashboard.view(dst({ data = tern.json.decode(OVERVIEW), refreshed = OV_NOW }))
	local t = S.text(v.main)
	for _, k in { "successRate", "flakeRate", "launchP90", "automationRate", "defectsOpened", "launches" } do
		local card = find(v.main, keyed(k))
		assert(card, "card " .. k)
		assert(find(card, function(n)
			return n.k == "chart" and n.p.kind == "line"
		end), "line chart in " .. k)
	end
	has(t, "94.3%")
	has(t, "4m 12s")
	has(t, "5 today")
	has(t, "▲ 3.5%")
	has(t, "no change")
	has(t, "data from 5 min ago")
	local function button(k: string): any
		return find(v.main, function(n)
			return n.k == "button" and n.p.props and n.p.props.key == k
		end)
	end
	local b7 = button("days7")
	local b28 = button("days28")
	eq(b7.p.props.variant, "primary")
	assert(b28.p.props.variant ~= "primary", "28 days isn't the active window")
	has(S.text(v.dock), "W window")
	no(t, "haven't updated")
end)

test("dashboard view: a fresh project's nulls show dashes and gaps", function()
	local data = tern.json.decode(OVERVIEW) :: any
	for _, k in data.kpis do
		k.latest, k.previous, k.percentChange, k.trend = tern.json.null, tern.json.null, tern.json.null, "neutral"
		for i in k.values do
			k.values[i] = tern.json.null
		end
	end
	local v = dashboard.view(dst({ data = data }))
	has(S.text(v.main), "–")
	no(S.text(v.main), "▲")
	local chart = find(find(v.main, keyed("successRate")), function(n)
		return n.k == "chart"
	end)
	eq(#chart.p.series, 7)
	eq(type(chart.p.series[1]), "table")
	eq(chart.p.series[1].value, nil)
end)

test("dashboard view: states", function()
	local none = dst({})
	none.identifier = nil
	has(S.text(dashboard.view(none).main), "No Qualflare project here")
	local e = S.text(dashboard.view(dst({ error = "no token loaded", status = 3 })).main)
	has(e, "Not logged in")
	has(e, "qf login demo-app")
	has(e, "Retry")
	has(S.kind_list(dashboard.view(dst({ loading = true })).main), "skeleton")
	local old = S.text(dashboard.view(dst({ outdated = true })).main)
	has(old, "Update qf to use the dashboard")
	has(old, "brew install qualflare/tap/qf")
	has(S.text(dashboard.view(dst({ data = tern.json.decode(OVERVIEW), now = OV_NOW + 45 * 60 })).main), "haven't updated")
end)

test("views.overview_url is the project home", function()
	eq(views.overview_url("demo-app"), "https://app.qualflare.com/project/demo-app")
end)

local function overview_for(days: number): string
	return (string.gsub(OVERVIEW, '"days": 7', `"days": {days}`))
end

local function dash_projects()
	plain_projects()
	S.process["/bin/qf demo-app overview --days 7"] = { status = 0, stdout = overview_for(7), stderr = "", timed_out = false }
	S.process["/bin/qf demo-app overview --days 28"] = { status = 0, stdout = overview_for(28), stderr = "", timed_out = false }
end

test("dashboard block loads the overview and switches window", function()
	dash_projects()
	local B = S.blocks.dashboard
	local cx = S.block_cx(101, nil)
	local s = B.init(cx, { "demo-app" }, nil)
	eq(B.title(s), "Qualflare dashboard · demo-app")
	eq(s.days, 7)
	eq(s.data.window.days, 7)
	B.event(s, { ev = "action", act = "days28" }, cx)
	eq(s.days, 28)
	eq(s.data.window.days, 28)
	B.key(s, key("w"), cx)
	eq(s.days, 7)
	has(S.text(B.view(s, cx).main), "Success rate")
end)

test("dashboard block: an older window's late answer never wins", function()
	dash_projects()
	local B = S.blocks.dashboard
	local cx = S.block_cx(102, nil)
	local s = B.init(cx, { "demo-app" }, nil)
	S.defer = true
	B.event(s, { ev = "action", act = "refresh" }, cx) -- 7 days, in flight
	B.event(s, { ev = "action", act = "days28" }, cx) -- 28 days, in flight
	local q = S.deferred
	S.deferred = {}
	S.defer = false
	q[2]() -- the 28-day answer lands first
	q[1]() -- then the stale 7-day one
	eq(s.days, 28)
	eq(s.data.window.days, 28)
end)

test("dashboard block: an old qf and a logged-out project", function()
	dash_projects()
	S.process["/bin/qf old overview --days 7"] = { status = 0, stdout = "Usage:\n  qf old [command]\n", stderr = "", timed_out = false }
	S.process["/bin/qf out overview --days 7"] = { status = 3, stdout = "", stderr = "Error: no token loaded", timed_out = false }
	local B = S.blocks.dashboard
	local old = B.init(S.block_cx(103, nil), { "old" }, nil)
	eq(old.outdated, true)
	has(S.text(B.view(old, S.block_cx(103, nil)).main), "Update qf")
	local out = B.init(S.block_cx(104, nil), { "out" }, nil)
	eq(out.status, 3)
	eq(out.outdated, false)
end)

test("dashboard block: the refresh timer stops once the pane is gone", function()
	dash_projects()
	S.panes = { { pane = 105, title = "" } }
	S.blocks.dashboard.init(S.block_cx(105, nil), { "demo-app" }, nil)
	local t = S.timers[#S.timers]
	S.panes = {}
	local before = #S.runs
	t.fn()
	eq(#S.runs, before, "no qf after the pane closed")
end)

test("dashboard block: saved state comes back", function()
	dash_projects()
	local B = S.blocks.dashboard
	local s = B.init(S.block_cx(106, nil), { "demo-app" }, nil)
	B.event(s, { ev = "action", act = "days28" }, S.block_cx(106, nil))
	local saved = B.save(s)
	eq(saved.identifier, "demo-app")
	eq(saved.days, 28)
	local back = B.init(S.block_cx(107, nil), { "web" }, saved)
	eq(back.identifier, "demo-app")
	eq(back.days, 28)
end)

test("dashboard and launches panes link to each other and to the website", function()
	dash_projects()
	local B = S.blocks.dashboard
	local cx = S.block_cx(108, nil)
	local s = B.init(cx, { "demo-app" }, nil)
	B.event(s, { ev = "action", act = "open" }, cx)
	eq(S.opened[#S.opened], "https://app.qualflare.com/project/demo-app?src=tern")
	B.event(s, { ev = "action", act = "launches" }, cx)
	eq(S.opened[#S.opened], "qualflare-tern:launches?id=demo-app")
	local L = S.blocks.launches
	local lcx = S.block_cx(109, nil)
	local ls = L.init(lcx, { "demo-app" }, nil)
	L.event(ls, { ev = "action", act = "dashboard" }, lcx)
	eq(S.opened[#S.opened], "qualflare-tern:dashboard?id=demo-app")
	has(S.text(tab.view(ls).main), "Dashboard")
end)

test("window: Show dashboard and the bridge open the dashboard beside", function()
	S.panes = { { pane = 3, cwd = "/w/repo/packages/web", title = "" } }
	S.files["/w/repo/.qualflare/test-state.md"] = STATE
	local cx = S.window_cx(3)
	S.commands.overview.run(cx)
	eq(cx.blocks[1][1], "qualflare.dashboard")
	eq(cx.blocks[1][2][1], "acme-web")
	eq(cx.blocks[1][3], "beside")

	S.panes = {
		{ pane = 3, kind = "plugin", cwd = "", title = "", block = "qualflare.launches" },
		{ pane = 4, kind = "plugin", cwd = "", title = "", block = "qualflare.dashboard" },
		{ pane = 5, kind = "terminal", cwd = "/w/repo", title = "" },
	}
	local wcx = S.window_cx(3)
	eq(S.routes[1]({ url = "qualflare-tern:dashboard?id=demo-app", pane = 3, mods = {} }, wcx).handled, true)
	eq(wcx.blocks[1][1], "qualflare.dashboard")
	eq(wcx.blocks[1][2][1], "demo-app")
	eq(S.routes[1]({ url = "qualflare-tern:launches?id=demo-app", pane = 4, mods = {} }, wcx).handled, true)
	eq(wcx.blocks[2][1], "qualflare.launches")
	-- from a terminal, or with a malformed id: swallowed, nothing opens
	eq(S.routes[1]({ url = "qualflare-tern:dashboard?id=demo-app", pane = 5, mods = {} }, wcx).handled, true)
	eq(S.routes[1]({ url = "qualflare-tern:dashboard?id=..%2Fx", pane = 3, mods = {} }, wcx).handled, true)
	eq(#wcx.blocks, 2)
	S.panes = {}
end)

test("review: an unknown data age keeps the cards; all-empty numbers explain why", function()
	local data = tern.json.decode(OVERVIEW) :: any
	data.dataThrough = tern.json.null
	local v = dashboard.view(dst({ data = data }))
	assert(find(v.main, keyed("successRate")), "the cards stay when only the data age is unknown")
	has(S.text(v.main), "data age unknown")
	no(S.text(v.main), "No metrics yet")
	local empty = tern.json.decode(OVERVIEW) :: any
	for _, k in empty.kpis do
		k.latest = tern.json.null
	end
	local e = dashboard.view(dst({ data = empty }))
	has(S.text(e.main), "No metrics yet")
	assert(find(e.main, keyed("successRate")), "cards still drawn")
end)

test("review: switching window never shows the other window's numbers as its own", function()
	dash_projects()
	local B = S.blocks.dashboard
	local cx = S.block_cx(110, nil)
	local s = B.init(cx, { "demo-app" }, nil)
	eq(s.data.window.days, 7)
	S.defer = true
	B.key(s, key("w"), cx) -- 28 days asked, not answered yet
	eq(s.days, 28)
	eq(s.data, nil, "no 7-day numbers under the 28-day button while it loads")
	has(S.kind_list(B.view(s, cx).main), "skeleton")
	S.deferred = {}
	S.defer = false
	-- the 28-day request fails: still no 7-day numbers shown as 28
	S.process["/bin/qf demo-app overview --days 28"] = { status = 7, stdout = "", stderr = "Error: timeout", timed_out = false }
	B.event(s, { ev = "action", act = "refresh" }, cx)
	eq(s.data, nil)
	eq(s.status, 7)
	-- back to 7 shows the 7-day numbers it already has, at once
	S.defer = true
	B.key(s, key("w"), cx)
	eq(s.data.window.days, 7)
	S.deferred = {}
	S.defer = false
	-- a save that mixes windows comes back without the mismatched numbers
	local back = B.init(S.block_cx(111, nil), { "demo-app" }, { identifier = "demo-app", days = 28, data = tern.json.decode(OVERVIEW) })
	assert(back.data == nil or back.data.window.days == 28, "restored data must match the window")
end)

test("review: target-coloured headlines keep the title style; open on website; caption", function()
	local v = dashboard.view(dst({ data = tern.json.decode(OVERVIEW) }))
	local card = find(v.main, keyed("successRate"))
	local span = find(card, function(n)
		return n.k == "text" and n.p.spans and n.p.spans[1] and n.p.spans[1].t == "94.3%"
	end)
	eq(span.p.spans[1].s, "title error")
	assert(find(v.main, function(n)
		return n.k == "button" and n.p.props and n.p.props.key == "open"
	end), "an Open on website button")
	has(S.text(v.main), "daily average of the 7 days before")
end)

test("dashboard block: an old qf rejecting --days reads as outdated", function()
	dash_projects()
	S.process["/bin/qf old2 overview --days 7"] = { status = 1, stdout = "", stderr = "Error: unknown flag: --days\nUsage:\n  qf old2 [command]", timed_out = false }
	S.process["/bin/qf old3 overview --days 7"] = { status = 1, stdout = "", stderr = 'Error: unknown command "overview" for "qf old3"', timed_out = false }
	local B = S.blocks.dashboard
	for _, id in { "old2", "old3" } do
		local s = B.init(S.block_cx(120, nil), { id }, nil)
		eq(s.outdated, true, id)
		has(S.text(B.view(s, S.block_cx(120, nil)).main), "Update qf to use the dashboard")
	end
end)

print(`{passed} passed, {failed} failed, {pending} pending`)
if failed > 0 then
	error("tests failed")
end
