--!strict
-- Host half: runs in the session daemon. Watches shell commands, draws the
-- `qf` lenses and the launches block.

local detect = require("./lib/detect")
local project = require("./lib/project")
local qf = require("./lib/qf")
local views = require("./lib/views")

local ui = tern.ui

local MARKERS = tern.plugin.data .. "/markers"
tern.fs.mkdir(MARKERS)

---------------------------------------------------------------------------
-- Upload after tests
---------------------------------------------------------------------------

type Pending = { cwd: string, project: project.Project, marker: string }
local pending: { [number]: Pending } = {}

local function setting_on(key: string): boolean
	return tern.kv.get(key) ~= false
end

tern.on("command_started", function(ev: { pane: number, line: string, cwd: string? }, _cx: EffectCx)
	pending[ev.pane] = nil
	if not setting_on("auto_prompt") or ev.cwd == nil then
		return
	end
	if not detect.is_test_command(ev.line) then
		return
	end
	local proj = project.find(ev.cwd :: string)
	if proj == nil then
		return
	end
	-- `tern.fs` has no mtime, so `find -newer` compares against this file.
	local marker = `{MARKERS}/{ev.pane}`
	tern.fs.write(marker, "")
	pending[ev.pane] = { cwd = ev.cwd :: string, project = proj, marker = marker }
end)

local function pane_busy(pane: number): boolean
	for _, p in tern.pane.list() do
		if p.pane == pane then
			return p.busy == true
		end
	end
	return true -- gone
end

local function offer_upload(ev: { pane: number }, p: Pending, cx: EffectCx)
	local extra = tern.kv.get("report_dirs")
	local dirs = detect.report_dirs(p.project.root, p.project.package.path, if type(extra) == "table" then extra else nil)
	if #dirs == 0 then
		return
	end
	local argv = { "find" }
	for _, d in dirs do
		table.insert(argv, d)
	end
	for _, a in { "-type", "f", "-newer", p.marker, "(", "-name", "*.json", "-o", "-name", "*.jsonl", "-o", "-name", "*.xml", ")" } do
		table.insert(argv, a)
	end
	tern.process.run(argv, { timeout_ms = 5000 }, function(res: ProcessResult)
		local files = {}
		for f in string.gmatch(res.stdout, "[^\n]+") do
			table.insert(files, f)
		end
		if #files == 0 or pane_busy(ev.pane) then
			return
		end
		local parts = { "qf", p.project.package.identifier, "collect" }
		for _, t in detect.collect_targets(files, p.cwd) do
			table.insert(parts, qf.quote(t))
		end
		local cmd = table.concat(parts, " ")
		-- Left on the prompt, not run: the person presses Enter.
		tern.pane.write(ev.pane, cmd)
		pcall(function()
			cx:toast("info", `{#files} new test report(s)`, "Press Enter to upload them to Qualflare")
		end)
	end)
end

-- `qf <id> collect …` finishing: remember the result for the status widget.
local function record_upload(line: string, status: number, took_ms: number)
	local words = detect.strip_wrappers(detect.words(line))
	if #words < 3 or (string.match(words[1], "([^/]+)$")) ~= "qf" or words[3] ~= "collect" then
		return
	end
	if table.find(words, "--dry-run") then
		return
	end
	local label = qf.explain(status)
	tern.kv.set("last_upload", {
		identifier = words[2],
		status = status,
		label = label,
		took_ms = took_ms,
	})
	pcall(tern.chrome.refresh)
end

tern.on("command_finished", function(ev: { pane: number, line: string, status: number, took_ms: number }, cx: EffectCx)
	record_upload(ev.line, ev.status, ev.took_ms)
	local p = pending[ev.pane]
	pending[ev.pane] = nil
	if p and detect.finished_normally(ev.status) then
		offer_upload(ev, p, cx)
	end
end)

tern.on("pane_exited", function(ev: { pane: number })
	pending[ev.pane] = nil
end)

---------------------------------------------------------------------------
-- Status widget: the last upload
---------------------------------------------------------------------------

pcall(tern.chrome.widget, "last-upload", {
	name = "Qualflare upload",
	description = "Result of the last qf collect",
	icon = "list-checks",
	render = function(_pane: StatusPaneInfo?): WidgetView?
		local u = tern.kv.get("last_upload")
		if type(u) ~= "table" then
			return nil
		end
		local label, tone = qf.explain(u.status)
		return {
			text = `{u.identifier}: {label}`,
			tone = if tone == "success" then "success" elseif tone == "warn" then "warning" else "error",
			title = "Last qf collect. Click to open launches.",
			command = "plugin.qualflare.launches",
		}
	end,
})

---------------------------------------------------------------------------
-- Lens: qf <id> collect
---------------------------------------------------------------------------

type CollectState = { identifier: string, lines: { string }, status: number? }

tern.lens.define("collect", {
	open = function(run: LensRun, _cx: EffectCx): CollectState
		return { identifier = run.args[1] or "", lines = {}, status = nil }
	end,
	line = function(s: CollectState, l: LensLine)
		if #s.lines < 500 then
			table.insert(s.lines, l.text)
		end
	end,
	finish = function(s: CollectState, status: number)
		s.status = status
	end,
	view = function(s: CollectState): Node?
		local notes: { Node } = {}
		local files: string? = nil
		local message: string? = nil
		for _, line in s.lines do
			local n = string.match(line, "^Processing (%d+) test result file")
			if n then
				files = n
			elseif string.match(line, "^OK ") then
				message = string.sub(line, 4)
			elseif string.match(line, "^ERR ") or string.match(line, "^Error:") then
				message = (string.gsub(line, "^ERR ", ""))
			elseif string.match(line, "^ignored ") or string.match(line, "^skipped ") or string.match(line, "^merging ") then
				table.insert(notes, ui.text({ ui.span(line, "muted") }))
			elseif line ~= "" then
				table.insert(notes, ui.text(line))
			end
		end
		if s.status == nil then
			return ui.progress(nil, if files then `Uploading {files} file(s) to Qualflare…` else "Uploading to Qualflare…")
		end
		local label, tone = qf.explain(s.status :: number)
		local head = ui.row({
			ui.badge(label, if tone == "warn" then "warning" elseif tone == "bad" then "error" else "success"),
			ui.text({ ui.span(s.identifier, "mono") }),
			if files then ui.text({ ui.span(`{files} file(s)`, "muted") }) else ui.text(""),
		})
		local body: { Node } = { head }
		if message then
			table.insert(body, ui.text(message))
		end
		if s.status == 3 then
			table.insert(body, ui.text({ ui.span("Run ", "muted"), ui.span(`qf login {s.identifier}`, "code"), ui.span(" in your terminal.", "muted") }))
		end
		for _, n in notes do
			table.insert(body, n)
		end
		if s.status == 0 then
			table.insert(body, ui.button("Open launches", { icon = "open", actions = { click = "open" } }))
		end
		return ui.col(body)
	end,
	event = function(s: CollectState, ev: UiEvent, cx: EffectCx)
		if ev.ev == "action" and ev.act == "open" then
			cx:open(views.project_url(s.identifier, "launches"))
		end
	end,
})

---------------------------------------------------------------------------
-- Lens: qf <id> launches|clusters|defects list
---------------------------------------------------------------------------

type ListState = { identifier: string, kind: string, lines: { string }, data: any?, done: boolean }

-- Row ids and button acts both name the item: "launch=12", "cluster=7",
-- "defect=3". Returns the dashboard URL for an open (button or double-click).
local function item_url(identifier: string, ev: UiEvent): string?
	local s = if ev.ev == "action" then ev.act elseif ev.ev == "activate" then ev.item else nil
	if type(s) ~= "string" then
		return nil
	end
	local kind, value = string.match(s, "^(%a+)=(.+)$")
	if kind == "launch" then
		return views.launch_url(identifier, value)
	elseif kind == "cluster" then
		return views.cluster_url(identifier, value)
	elseif kind == "defect" then
		return views.defect_url(identifier, value)
	end
	return nil
end

tern.lens.define("list", {
	open = function(run: LensRun, _cx: EffectCx): ListState
		return { identifier = run.args[1] or "", kind = run.args[2] or "", lines = {}, data = nil, done = false }
	end,
	line = function(s: ListState, l: LensLine)
		table.insert(s.lines, l.text)
	end,
	finish = function(s: ListState, status: number)
		s.done = true
		if status == 0 then
			local ok, data = pcall(tern.json.decode, table.concat(s.lines, "\n"))
			if ok then
				s.data = data
			end
		end
		s.lines = {}
	end,
	view = function(s: ListState): Node?
		if not s.done or s.data == nil then
			return nil -- raw output until the JSON parses
		end
		local items = views.items(s.data)
		if items == nil then
			return nil
		end
		if s.kind == "launches" then
			return views.launches_table(items)
		elseif s.kind == "clusters" then
			return views.clusters_table(items)
		end
		return views.defects_table(items)
	end,
	event = function(s: ListState, ev: UiEvent, cx: EffectCx)
		local url = item_url(s.identifier, ev)
		if url then
			cx:open(url)
		end
	end,
})

---------------------------------------------------------------------------
-- Block: Qualflare launches
---------------------------------------------------------------------------

type BlockState = {
	identifier: string?,
	cwd: string?,
	launches: { any }?,
	clusters: { any }?,
	error: string?,
	loading: boolean,
	selected: string?,
	refreshed: string?,
	timer: TimerHandle?,
}

local REFRESH_MS = 60000

local function refresh(s: BlockState, cx: BlockCx)
	local id = s.identifier
	if id == nil then
		return
	end
	s.loading = true
	local remaining = 2
	local function done()
		remaining -= 1
		if remaining == 0 then
			s.loading = false
			cx:render()
		end
	end
	qf.read({ id, "launches", "list" }, s.cwd, function(r)
		if r.ok then
			s.launches = views.items(r.data) or {}
			s.error = nil
		else
			s.error = r.err
		end
		done()
	end)
	qf.read({ id, "clusters", "list" }, s.cwd, function(r)
		if r.ok then
			s.clusters = views.items(r.data) or {}
		end
		done()
	end)
end

local function schedule(s: BlockState, cx: BlockCx)
	if s.timer then
		s.timer:cancel()
	end
	s.timer = tern.timer(REFRESH_MS, function()
		refresh(s, cx)
		schedule(s, cx)
	end)
end

tern.block.define("launches", {
	font = "sans",
	init = function(cx: BlockCx, args: { string }, saved: any): BlockState
		local s: BlockState = { loading = false, cwd = cx.cwd }
		if type(saved) == "table" then
			s.identifier = saved.identifier
			s.launches = saved.launches
			s.clusters = saved.clusters
		end
		if args[1] then
			s.identifier = args[1]
		elseif s.identifier == nil and cx.cwd then
			local proj = project.find(cx.cwd :: string)
			if proj then
				s.identifier = proj.package.identifier
			end
		end
		if s.identifier == nil then
			s.error = "No Qualflare project here. Run /qf-init in Claude Code or omp, or open this block from a project folder."
		else
			refresh(s, cx)
			schedule(s, cx)
		end
		return s
	end,
	title = function(s: BlockState): string?
		return if s.identifier then `Qualflare · {s.identifier}` else "Qualflare"
	end,
	view = function(s: BlockState, _cx: BlockCx): BlockView
		local parts: { Node } = {}
		if s.error then
			table.insert(parts, ui.text({ ui.span(s.error :: string, "error") }))
		end
		local launches = s.launches
		if launches and #launches > 0 then
			table.insert(parts, views.latest_stats(launches[1]))
		end
		if launches then
			table.insert(parts, ui.section("Launches", { views.launches_table(launches, { selected = s.selected, max = 50 }) }))
		elseif s.loading then
			table.insert(parts, ui.progress(nil, "Loading launches…"))
		end
		local clusters = s.clusters
		if clusters and #clusters > 0 then
			table.insert(parts, ui.section("Failure clusters", { views.clusters_table(clusters) }))
		end
		local dock = ui.row({
			ui.button("Refresh", { icon = "repeat", busy = s.loading, actions = { click = "refresh" } }),
			ui.button("Open dashboard", { icon = "open", variant = "quiet", actions = { click = "dashboard" } }),
		})
		return { main = ui.col(parts), dock = if s.identifier then dock else nil }
	end,
	event = function(s: BlockState, ev: UiEvent, cx: BlockCx)
		local id = s.identifier
		if id == nil then
			return
		end
		if ev.ev == "action" and ev.act == "refresh" then
			refresh(s, cx)
		elseif ev.ev == "action" and ev.act == "dashboard" then
			cx:open(views.project_url(id, "launches"))
		elseif ev.ev == "select" and type(ev.item) == "string" then
			s.selected = ev.item
		else
			local url = item_url(id, ev)
			if url then
				cx:open(url)
			end
		end
	end,
	key = function(s: BlockState, key: Key, cx: BlockCx): boolean?
		if key.name == "r" and not key.meta and not key.ctrl then
			refresh(s, cx)
			return true
		end
		return false
	end,
	save = function(s: BlockState): any
		return { identifier = s.identifier, launches = s.launches, clusters = s.clusters }
	end,
})
