-- Plugin tests outside Tern: `luau tests/run.luau` (see README).
local S = require("./stub")
local detect = require("../lib/detect")
local project = require("../lib/project")
local qf = require("../lib/qf")
local views = require("../lib/views")
local links = require("../lib/links")
local tab = require("../lib/tab")

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
	eq(S.opened[1], "https://app.qualflare.com/project/demo-app/launches?p=launch&p.seq=42")
	eq(S.opened[2], "https://app.qualflare.com/project/demo-app/launches?p=launch&p.seq=41")
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
	has(S.text(B.view(s, cx).main), "Pass rate")
	B.event(s, { ev = "activate", item = "launch=42" }, cx)
	eq(S.opened[#S.opened], "https://app.qualflare.com/project/demo-app/launches?p=launch&p.seq=42")
	B.event(s, { ev = "select", item = "launch=41" }, cx)
	B.event(s, { ev = "action", act = "open" }, cx)
	eq(S.opened[#S.opened], "https://app.qualflare.com/project/demo-app/launches?p=launch&p.seq=41")
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
	eq(S.opened[#S.opened], "https://app.qualflare.com/project/demo-app/launches?p=launch&p.seq=42")
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

test("Show launches opens the block for the focused project", function()
	S.panes = { { pane = 3, cwd = "/w/repo/packages/web", title = "" } }
	local cx = S.window_cx(3)
	S.commands.launches.run(cx)
	eq(cx.blocks[1][1], "qualflare.launches")
	eq(cx.blocks[1][2][1], "acme-web")
end)

test("Fix with omp starts an agent on qf-fix at the project root", function()
	S.panes = { { pane = 3, cwd = "/w/repo/src", title = "" } }
	S.commands.fix.run(S.window_cx(3))
	eq(S.runs[1][1], "agent")
	eq(S.runs[1][2], "/skill:qf-fix")
	eq(S.runs[1][3], "/w/repo")
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
	eq(views.ago("2026-11-16T12:00:00Z", t + 8 * 86400), "2026-11-16 12:00")
	eq(views.ago(nil, t), "")
	eq(views.epoch("2000-03-01T00:00:00Z"), 951868800) -- leap-year arithmetic
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

local function st(over: any): any
	local s: any = { identifier = "demo-app", projects = { "demo-app", "web" }, launches = nil, more = false, loading = false, now = 1763294400, menu_open = false, selected = nil }
	for k, v in over do
		s[k] = v
	end
	return s
end

test("tab: launches page has head, stats, table and the selected card", function()
	local launches = (tern.json.decode(LAUNCHES) :: any).items
	local v = tab.view(st({ launches = launches, selected = launches[2].seq, refreshed = 1763294400 - 60 }))
	local t = S.text(v.main)
	has(t, "Qualflare")
	has(t, "Pass rate")
	has(t, "Failed")
	has(t, "Flaky")
	has(t, "Last run")
	has(t, "updated 1 min ago")
	has(t, "#" .. tostring(launches[2].seq))
	has(t, "Open on website")
	has(S.kind_list(v.main), "select")
	has(S.text(v.dock), "R refresh")
	eq(tab.selected_launch(st({ launches = launches, selected = 41 })).seq, 41)
	eq(tab.selected_launch(st({ launches = launches })).seq, 42)
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
	assert(not string.find(t, "Pass rate", 1, true), "no stats strip when empty")
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
	has(S.text(tab.view(st({ loading = true, launches = launches })).main), "Pass rate")
end)

print(`{passed} passed, {failed} failed, {pending} pending`)
if failed > 0 then
	error("tests failed")
end
