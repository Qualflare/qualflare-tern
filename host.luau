--!strict
-- Host half: runs in the session daemon. Watches shell commands, draws the
-- `qf` lenses and the launches block.

local detect = require("./lib/detect")
local project = require("./lib/project")
local qf = require("./lib/qf")
local links = require("./lib/links")
local tab = require("./lib/tab")
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

-- Set by the block section below: refreshes open panes on a project after
-- an upload to it.
local on_upload: (identifier: string, took_ms: number) -> () = function(_identifier: string, _took_ms: number) end

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
	if status == 0 then
		on_upload(words[2], took_ms)
	end
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
		return views.own(views.launch_url(identifier, value))
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
-- Block: the Qualflare tab (kind `qualflare.launches`, args {identifier?, seq?})
---------------------------------------------------------------------------

type BlockState = {
	identifier: string?,
	projects: { string },
	launches: { any }?,
	more: boolean,
	page: number,
	error: string?,
	status: number?,
	loading: boolean,
	selected: number?,
	now: number,
	refreshed: number?,
	menu_open: boolean,
	menu_active: string?,
	-- an older launch a link asked for, fetched on its own (not in `launches`)
	pinned: any?,
	cwd: string?,
	root: string?,
	timer: TimerHandle?,
	-- bumped per qf list request; older answers are dropped
	req: number,
	clusters: { any }?,
	fresh: number?,
	-- an upload from a terminal whose launch hasn't been picked out yet:
	-- `base` the newest seq when it finished, `since` when it started (Unix s)
	upload: { base: any, since: number, retried: boolean }?,
}

-- Whether the block's pane still exists (blocks have no close handler).
local function running(pane: number): boolean
	for _, p in tern.pane.list() do
		if p.pane == pane then
			return true
		end
	end
	return false
end

-- An identifier as `qf projects` prints it, not a sentence it may print instead.
local function is_identifier(line: string): boolean
	return string.match(line, "^[%w][%w%-_%.]*$") ~= nil
end

local REFRESH_MS = 60000
-- An upload's launch may not be listed at once; look again once after this.
local UPLOAD_RETRY_MS = 5000
local CLUSTERS_SHOWN = 3

-- Open Qualflare panes by pane id, for refreshing after uploads.
local live: { [number]: { s: BlockState, cx: BlockCx } } = {}

local function launch_seq(item: any): number?
	if type(item) ~= "string" then
		return nil
	end
	local seq = string.match(item, "^launch=(%d+)$")
	return if seq then tonumber(seq) else nil
end

local function has_seq(launches: { any }?, seq: number?): boolean
	if launches == nil or seq == nil then
		return false
	end
	for _, l in launches do
		if l.seq == seq then
			return true
		end
	end
	return false
end

local function cluster_id(item: any): string?
	if type(item) ~= "string" then
		return nil
	end
	return string.match(item, "^cluster=(.+)$")
end

local function seqs_of(list: { any }): { [any]: boolean }
	local seen: { [any]: boolean } = {}
	for _, l in list do
		if l.seq ~= nil then
			seen[l.seq] = true
		end
	end
	return seen
end

-- Page 1 from a refresh replaces the top of the list but keeps launches that
-- Show more loaded; a later page is appended. Either way no seq appears twice.
local function apply_page(s: BlockState, data: any, append: boolean)
	local items: { any } = views.items(data) or {}
	local paging = if type(data) == "table" and type(data.paging) == "table" then data.paging else {}
	local page = if type(paging.page) == "number" then paging.page else 1
	local pages = if type(paging.pages) == "number" then paging.pages else page
	local old = s.launches
	if append and old then
		local merged = table.clone(old :: { any })
		local seen = seqs_of(merged)
		for _, l in items do
			if not seen[l.seq] then
				table.insert(merged, l)
				seen[l.seq] = true
			end
		end
		s.launches = merged
		s.page = page
		s.more = page < pages
	elseif old and s.page > 1 then
		local merged = table.clone(items)
		local seen = seqs_of(merged)
		for _, l in old :: { any } do
			if not seen[l.seq] then
				table.insert(merged, l)
				seen[l.seq] = true
			end
		end
		s.launches = merged
	else
		s.launches = items
		s.page = page
		s.more = page < pages
	end
end

-- Fetches a launch the list doesn't hold (a link to an older one) for the card.
local function pin_selected(s: BlockState, cx: BlockCx)
	local id, seq = s.identifier, s.selected
	if id == nil or seq == nil or has_seq(s.launches, seq) then
		return
	end
	if s.pinned and s.pinned.seq == seq then
		return
	end
	qf.read({ id :: string, "launch", "get", tostring(seq) }, s.cwd, function(r)
		if s.identifier ~= id or s.selected ~= seq then
			return
		end
		if r.ok and type(r.data) == "table" then
			s.pinned = r.data
		else
			s.selected = nil
		end
		cx:render()
	end)
end

-- The newest failure clusters, only worth fetching when the newest launch
-- failed. A failed call just leaves them out.
local function load_clusters(s: BlockState, cx: BlockCx)
	local id = s.identifier
	local launches = s.launches
	if id == nil or launches == nil or #launches == 0 or views.failed(launches[1]) == 0 then
		s.clusters = nil
		return
	end
	local req = s.req
	qf.read({ id :: string, "clusters", "list", "--sort-by", "lastSeenAt", "--sort-desc" }, s.cwd, function(r)
		if s.identifier ~= id or s.req ~= req then
			return
		end
		local items = if r.ok then views.items(r.data) else nil
		if items then
			local top: { any } = {}
			for i = 1, math.min(#items, CLUSTERS_SHOWN) do
				table.insert(top, items[i])
			end
			s.clusters = top
		else
			s.clusters = nil
		end
		cx:render()
	end)
end

local function newest_seq(s: BlockState): any
	local launches = s.launches
	return if launches and launches[1] then launches[1].seq else nil
end

local refresh: (s: BlockState, cx: BlockCx) -> ()

-- After an upload, the first answer that has its launch selects and marks it.
-- Kept as state, so any refresh (R, the timer, the retry) can finish it.
local function pick_upload(s: BlockState, cx: BlockCx)
	local up = s.upload
	if up == nil then
		s.fresh = nil -- an ordinary refresh clears the mark
		return
	end
	local launches = s.launches
	local newest = if launches then launches[1] else nil
	local seq = newest_seq(s)
	local created = if newest then views.epoch(newest.createdAt) else nil
	-- New since the upload finished, or created while it ran (a refresh may
	-- have listed it before collect returned).
	if seq ~= nil and (seq ~= up.base or (created ~= nil and created >= up.since)) then
		s.selected = seq
		s.pinned = nil
		s.fresh = seq
		s.upload = nil
	elseif not up.retried then
		up.retried = true
		tern.timer(UPLOAD_RETRY_MS, function()
			if running(cx.pane) and s.upload == up then
				refresh(s, cx)
			end
		end)
	else
		s.upload = nil
	end
end

function refresh(s: BlockState, cx: BlockCx)
	local id = s.identifier
	if id == nil then
		return
	end
	s.loading = true
	s.req += 1
	local req = s.req
	qf.read({ id, "launches", "list" }, s.cwd, function(r)
		if s.identifier ~= id or s.req ~= req then
			return -- the project changed, or a newer request went out
		end
		s.loading = false
		s.now = os.time()
		if r.ok then
			apply_page(s, r.data, false)
			s.error = nil
			s.status = nil
			s.refreshed = s.now
			pick_upload(s, cx)
			if not has_seq(s.launches, s.selected) and not (s.pinned and s.pinned.seq == s.selected) then
				pin_selected(s, cx)
			end
			load_clusters(s, cx)
		else
			s.error = r.err
			s.status = r.status
		end
		cx:render()
	end)
end

-- Slack for clock differences between this machine and the server.
local UPLOAD_SLACK_S = 30

on_upload = function(identifier: string, took_ms: number)
	for pane, b in live do
		if not running(pane) then
			live[pane] = nil
		elseif b.s.identifier == identifier then
			b.s.upload = {
				base = newest_seq(b.s),
				since = os.time() - took_ms // 1000 - UPLOAD_SLACK_S,
				retried = false,
			}
			refresh(b.s, b.cx)
		end
	end
end

local function load_more(s: BlockState, cx: BlockCx)
	local id = s.identifier
	if id == nil or not s.more or s.loading then
		return
	end
	s.loading = true
	s.req += 1
	local req = s.req
	qf.read({ id, "launches", "list", "--page", tostring(s.page + 1) }, s.cwd, function(r)
		if s.identifier ~= id or s.req ~= req then
			return
		end
		s.loading = false
		if r.ok then
			apply_page(s, r.data, true)
		else
			s.error = r.err
			s.status = r.status
		end
		cx:render()
	end)
end

local function schedule(s: BlockState, cx: BlockCx)
	if s.timer then
		(s.timer :: TimerHandle):cancel()
	end
	s.timer = tern.timer(REFRESH_MS, function()
		if not running(cx.pane) then
			live[cx.pane] = nil
			return -- the pane closed
		end
		refresh(s, cx)
		schedule(s, cx)
	end)
end

local function load_projects(s: BlockState, cx: BlockCx)
	qf.lines({ "projects" }, s.cwd, function(r)
		local list: { string } = {}
		for _, line in r.lines do
			if is_identifier(line) then
				table.insert(list, line)
			end
		end
		tern.kv.set("known_identifiers", table.clone(list))
		if not r.ok then
			return
		end
		-- A project folder's identifier counts even if `qf projects` lacks it.
		if s.identifier and not table.find(list, s.identifier :: string) then
			table.insert(list, 1, s.identifier :: string)
		end
		s.projects = list
		if s.identifier == nil and #list > 0 then
			s.identifier = list[1]
			s.error = nil
			refresh(s, cx)
			schedule(s, cx)
		end
		cx:render()
	end)
end

-- The folder of the tab's project, when the tab's folder belongs to it.
-- Upload and Fix need it; without it they're refused.
local function root_for(cwd: string?, id: string?): string?
	if cwd == nil or id == nil then
		return nil
	end
	local proj = project.find(cwd :: string)
	if proj == nil then
		return nil
	end
	for _, pkg in (proj :: project.Project).packages do
		if pkg.identifier == id then
			return proj.root
		end
	end
	return nil
end

local function set_project(s: BlockState, cx: BlockCx, id: string)
	if id == s.identifier then
		return
	end
	s.identifier = id
	s.root = root_for(s.cwd, id)
	s.launches = nil
	s.pinned = nil
	s.selected = nil
	s.error = nil
	s.status = nil
	s.more = false
	s.page = 1
	s.refreshed = nil
	s.clusters = nil
	s.fresh = nil
	s.upload = nil
	refresh(s, cx)
	schedule(s, cx)
	cx:save()
end

local function selected_seq(s: BlockState): number?
	local l = tab.selected_launch(s)
	return if l and type(l.seq) == "number" then l.seq else nil
end

local function open_selected(s: BlockState, cx: BlockCx, seq: number?)
	local id = s.identifier
	local target = seq or selected_seq(s)
	if id and target then
		cx:open(views.own(views.launch_url(id :: string, target)))
	end
end

-- Steps the selection through the list (`-1` up, `1` down).
local function move(s: BlockState, step: number)
	local launches = s.launches
	if launches == nil or #launches == 0 then
		return
	end
	local at = 1
	local current = selected_seq(s)
	for i, l in launches do
		if l.seq == current then
			at = i
		end
	end
	local next_at = math.clamp(at + step, 1, #launches)
	s.selected = launches[next_at].seq
end

local function hand_off(s: BlockState, cx: BlockCx, action: string)
	local id = s.identifier
	if id == nil then
		return
	end
	if s.root == nil then
		cx:toast("info", `{id} isn't in this pane's folder`, "Open the pane from a folder of that project to upload or fix.")
		return
	end
	cx:open(links.bridge(action, { id = id :: string, root = s.root :: string }))
end

tern.block.define("launches", {
	font = "sans",
	init = function(cx: BlockCx, args: { string }, saved: any): BlockState
		local s: BlockState = {
			projects = {},
			more = false,
			page = 1,
			loading = false,
			now = os.time(),
			menu_open = false,
			cwd = cx.cwd,
			req = 0,
		}
		local proj = if cx.cwd then project.find(cx.cwd :: string) else nil
		if type(saved) == "table" then
			-- A restart (reload, daemon restart) brings the same args back;
			-- what the person changed since lives in `saved`.
			s.identifier = saved.identifier
			s.launches = saved.launches
			s.selected = saved.selected
			s.refreshed = saved.refreshed
		else
			if args[1] and args[1] ~= "" then
				s.identifier = args[1]
			elseif proj then
				s.identifier = proj.package.identifier
			end
			s.selected = if args[2] then tonumber(args[2]) else nil
		end
		s.root = root_for(cx.cwd, s.identifier)
		if s.identifier then
			s.projects = { s.identifier :: string }
			refresh(s, cx)
			schedule(s, cx)
		end
		load_projects(s, cx)
		live[cx.pane] = { s = s, cx = cx }
		return s
	end,
	title = function(s: BlockState): string?
		return if s.identifier then `Qualflare · {s.identifier}` else "Qualflare"
	end,
	view = function(s: BlockState, _cx: BlockCx): BlockView
		s.now = os.time()
		return tab.view(s)
	end,
	event = function(s: BlockState, ev: UiEvent, cx: BlockCx)
		local last = if type(ev.id) == "string" then string.match(ev.id, "([^%.]+)$") else nil
		if last == "project" and ev.ev == "change" and type(ev.value) == "string" then
			s.menu_open = false
			set_project(s, cx, ev.value)
		elseif last == "project" and ev.ev == "toggle" then
			s.menu_open = if type(ev.open) == "boolean" then ev.open else not s.menu_open
		elseif ev.ev == "select" and launch_seq(ev.item) then
			s.selected = launch_seq(ev.item)
		elseif ev.ev == "activate" and launch_seq(ev.item) then
			s.selected = launch_seq(ev.item)
			open_selected(s, cx, s.selected)
		elseif ev.ev == "activate" and cluster_id(ev.item) and s.identifier then
			cx:open(views.own(views.cluster_url(s.identifier :: string, cluster_id(ev.item))))
		elseif ev.ev == "action" then
			local act = ev.act
			if act == "open" then
				open_selected(s, cx, nil)
			elseif act == "refresh" or act == "retry" then
				refresh(s, cx)
			elseif act == "more" then
				load_more(s, cx)
			elseif act == "upload" or act == "fix" then
				hand_off(s, cx, act)
			elseif cluster_id(act) and s.identifier then
				cx:open(views.own(views.cluster_url(s.identifier :: string, cluster_id(act))))
			end
		end
	end,
	key = function(s: BlockState, key: Key, cx: BlockCx): boolean?
		if key.ctrl or key.meta or key.alt then
			return false
		end
		local n = key.name
		if s.menu_open then
			-- The project menu has the keys while it's open.
			local at = table.find(s.projects, s.menu_active or s.identifier or "") or 0
			if n == "up" or n == "k" then
				s.menu_active = s.projects[math.max(at - 1, 1)]
			elseif n == "down" or n == "j" then
				s.menu_active = s.projects[math.min(at + 1, #s.projects)]
			elseif n == "enter" then
				s.menu_open = false
				if s.menu_active then
					set_project(s, cx, s.menu_active :: string)
				end
			elseif n == "escape" then
				s.menu_open = false
			else
				return false
			end
			return true
		end
		if n == "r" then
			refresh(s, cx)
		elseif n == "u" then
			hand_off(s, cx, "upload")
		elseif n == "p" then
			s.menu_open = true
			s.menu_active = s.identifier
		elseif n == "up" or n == "k" then
			move(s, -1)
		elseif n == "down" or n == "j" then
			move(s, 1)
		elseif n == "enter" then
			open_selected(s, cx, nil)
		else
			return false
		end
		return true
	end,
	save = function(s: BlockState): any
		return { identifier = s.identifier, launches = s.launches, selected = s.selected, refreshed = s.refreshed }
	end,
})
