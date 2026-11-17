--!strict
-- Window half: palette commands, Carly exports, and the omp hand-off.

local detect = require("./lib/detect")
local links = require("./lib/links")
local project = require("./lib/project")
local qf = require("./lib/qf")
local views = require("./lib/views")

-- The project of the focused pane, if it has one.
local function focused_project(cx: WindowCx): (project.Project?, number?, string?)
	local pane = cx.session:focused()
	if pane == nil then
		return nil, nil, nil
	end
	local info = cx.session:pane(pane)
	local cwd = if info and info.cwd and info.cwd ~= "" then info.cwd else nil
	if cwd == nil then
		return nil, pane, nil
	end
	return project.find_cached(cwd :: string), pane, cwd
end

local function no_project(cx: WindowCx)
	cx:toast("info", "No Qualflare project here", "Run /qf-init in Claude Code or omp to set one up.")
end

tern.command({
	id = "launches",
	title = "Qualflare: Show launches",
	icon = "list-checks",
	run = function(cx: WindowCx)
		local proj = focused_project(cx)
		local args = if proj then { proj.package.identifier } else nil
		cx:new_block("qualflare.launches", args, "beside")
	end,
})

tern.command({
	-- "dashboard" is the older command that opens the website.
	id = "overview",
	title = "Qualflare: Show dashboard",
	icon = "list-checks",
	run = function(cx: WindowCx)
		local proj = focused_project(cx)
		local args = if proj then { proj.package.identifier } else nil
		cx:new_block("qualflare.dashboard", args, "beside")
	end,
})

-- The Qualflare panes that may ask the window, through the bridge, to open a
-- view or hand work over.
local QUALFLARE_BLOCKS: { [string]: boolean } = {
	["qualflare.launches"] = true,
	["qualflare.dashboard"] = true,
}

-- Bridge actions that only open a view of a project: no folder needed.
local VIEW_ACTIONS: { [string]: string } = {
	dashboard = "qualflare.dashboard",
	launches = "qualflare.launches",
}

local function under(path: string, root: string): boolean
	return path == root or string.sub(path, 1, #root + 1) == root .. "/"
end

-- A visible terminal pane at its prompt inside `root`: the focused one if
-- it qualifies, else one in the same tab as `near`, else any.
local function terminal_in(cx: WindowCx, root: string, near: number?): (number?, string?)
	local function ok(info: PaneInfo?): boolean
		return info ~= nil
			and info.kind == "terminal"
			and info.at_prompt == true
			and info.parked ~= true
			and type(info.cwd) == "string"
			and under(info.cwd :: string, root)
	end
	local focused = cx.session:focused()
	if focused then
		local info = cx.session:pane(focused)
		if ok(info) then
			return focused, (info :: PaneInfo).cwd
		end
	end
	local tab = if near then cx.session:tab_of(near) else nil
	local first: PaneInfo? = nil
	for _, info in cx.session:panes() do
		if ok(info) then
			if tab ~= nil and cx.session:tab_of(info.pane) == tab then
				return info.pane, info.cwd
			end
			first = first or info
		end
	end
	if first then
		return (first :: PaneInfo).pane, (first :: PaneInfo).cwd
	end
	return nil, nil
end

-- Types `qf <identifier> collect <report folder>` into a terminal of the
-- project at `root` (the given pane, else one `terminal_in` finds). Typed,
-- not run: the person checks it and presses Enter.
local function upload_into(cx: WindowCx, identifier: string, root: string, pane: number?, cwd: string?, near: number?)
	local target, target_cwd = pane, cwd
	local found = false
	if target == nil or target_cwd == nil then
		target, target_cwd = terminal_in(cx, root, near)
		found = true
	end
	if target == nil or target_cwd == nil then
		cx:toast("info", `Open a terminal in {root} to upload`, nil)
		return
	end
	local proj = project.find_cached(root)
	local pkg_path = ""
	if proj then
		for _, pkg in (proj :: project.Project).packages do
			if pkg.identifier == identifier then
				pkg_path = pkg.path
			end
		end
	end
	local extra = tern.kv.get("report_dirs")
	local dirs = detect.report_dirs(root, pkg_path, if type(extra) == "table" then extra else nil)
	if #dirs == 0 then
		cx:toast("info", "No report folder yet", "Run your tests with a Qualflare reporter, or /qf-run.")
		return
	end
	local rel = detect.relative(dirs[1], target_cwd :: string)
	cx:run(target :: number, `qf {qf.quote(identifier)} collect {qf.quote(rel)}`)
	if found then
		cx.layout:focus(target :: number) -- show where the command went
	end
end

local function fix_in(cx: WindowCx, root: string)
	-- Needs the Qualflare plugin in omp (its qf-fix skill).
	cx.agents:start({ prompt = "/skill:qf-fix", cwd = root, how = "split" })
end

tern.command({
	id = "upload",
	title = "Qualflare: Upload test results",
	icon = "push",
	run = function(cx: WindowCx)
		local proj, pane, cwd = focused_project(cx)
		if proj == nil or pane == nil or cwd == nil then
			return no_project(cx)
		end
		local p = proj :: project.Project
		upload_into(cx, p.package.identifier, p.root, pane, cwd)
	end,
})

tern.command({
	id = "dashboard",
	title = "Qualflare: Open website",
	icon = "globe",
	run = function(cx: WindowCx)
		local proj = focused_project(cx)
		if proj == nil then
			return no_project(cx)
		end
		cx:open(views.project_url((proj :: project.Project).package.identifier, "launches"))
	end,
})

tern.command({
	id = "fix",
	title = "Qualflare: Fix failing tests with omp",
	icon = "app-omp",
	run = function(cx: WindowCx)
		local proj, _, cwd = focused_project(cx)
		if proj == nil or cwd == nil then
			return no_project(cx)
		end
		fix_in(cx, (proj :: project.Project).root)
	end,
})

tern.command({
	id = "toggle_prompt",
	title = "Qualflare: Toggle upload prompt after tests",
	icon = "bell",
	run = function(cx: WindowCx)
		local on = tern.kv.get("auto_prompt") ~= false
		tern.kv.set("auto_prompt", not on)
		cx:toast("info", if on then "Upload prompt off" else "Upload prompt on", nil)
	end,
})

tern.command({
	id = "toggle_links",
	title = "Qualflare: Toggle opening Qualflare links in Tern",
	icon = "link",
	run = function(cx: WindowCx)
		local on = tern.kv.get("route_links") ~= false
		tern.kv.set("route_links", not on)
		cx:toast("info", if on then "Qualflare links open in the browser" else "Qualflare links open in Tern", nil)
	end,
})

---------------------------------------------------------------------------
-- Links: the tab's hand-offs, and dashboard launch links from terminals
---------------------------------------------------------------------------

-- Identifiers the link route can map a dashboard slug to: what `qf
-- projects` listed when a tab last opened, plus the clicked pane's project.
local function known_identifiers(cwd: string?): { string }
	local list: { string } = {}
	local saved = tern.kv.get("known_identifiers")
	if type(saved) == "table" then
		for _, id in saved do
			if type(id) == "string" then
				table.insert(list, id)
			end
		end
	end
	if cwd and cwd ~= "" then
		local proj = project.find_cached(cwd :: string)
		if proj then
			for _, pkg in (proj :: project.Project).packages do
				if not table.find(list, pkg.identifier) then
					table.insert(list, pkg.identifier)
				end
			end
		end
	end
	return list
end

-- Whether `root` is the folder of a Qualflare project that has `id`.
local function project_has(root: string, id: string): boolean
	local proj = project.find_cached(root)
	if proj == nil or (proj :: project.Project).root ~= root then
		return false
	end
	for _, pkg in (proj :: project.Project).packages do
		if pkg.identifier == id then
			return true
		end
	end
	return false
end

tern.route.link(function(link: LinkRequest, cx: WindowCx): RouteDecision?
	local info = if link.pane ~= nil then cx.session:pane(link.pane) else nil
	local action, params = links.parse_bridge(link.url)
	if action then
		-- Only the Qualflare tab hands work over, and only for its own
		-- project: a link printed anywhere else could name any folder.
		local from_qualflare = info ~= nil and info.kind == "plugin" and QUALFLARE_BLOCKS[info.block or ""] == true
		local id, root = params.id, params.root
		local view = VIEW_ACTIONS[action]
		if view then
			-- Open the other Qualflare view beside the pane that asked.
			if from_qualflare and type(id) == "string" and string.match(id, "^[%w][%w%-_%.]*$") then
				cx:new_block(view, { id :: string }, "beside", { target = link.pane })
			end
			return { handled = true }
		end
		local from_tab = info ~= nil and info.kind == "plugin" and info.block == "qualflare.launches"
		if not from_tab or id == nil or root == nil or not project_has(root :: string, id :: string) then
			return { handled = true }
		end
		if action == "upload" then
			upload_into(cx, id :: string, root :: string, nil, nil, link.pane)
		elseif action == "fix" then
			fix_in(cx, root :: string)
		end
		return { handled = true }
	end
	if tern.kv.get("route_links") == false then
		return nil
	end
	-- The plugin's own website opens (lens rows, the tab's button) go out.
	if string.find(link.url, views.OWN, 1, true) then
		return nil
	end
	-- Only clicks in terminals.
	if info == nil or (info :: PaneInfo).kind ~= "terminal" then
		return nil
	end
	local target = links.launch_from_url(link.url)
	if target == nil then
		return nil
	end
	local id = links.identifier_for(target.slug, known_identifiers((info :: PaneInfo).cwd))
	if id == nil then
		return nil
	end
	return { block = "qualflare.launches", args = { id :: string, tostring(target.seq) } }
end)

---------------------------------------------------------------------------
-- Carly: read-only exports and request context
---------------------------------------------------------------------------

local function identifier_or_focused(cx: WindowCx, id: string?): string?
	if type(id) == "string" and id ~= "" then
		return id
	end
	local proj = focused_project(cx)
	return if proj then proj.package.identifier else nil
end

local function read_export(name: string, sub: string, doc: string)
	tern.carly.export(name, {
		sig = "(identifier: string?) -> {items: {any}}",
		doc = doc,
	}, function(id: string?, cx: WindowCx, call: ExportCall)
		local ident = identifier_or_focused(cx, id)
		if ident == nil then
			call:fail("No Qualflare project: pass a qf identifier, or focus a pane inside a project.")
			return call:wait(1000)
		end
		qf.read({ ident :: string, sub, "list" }, nil, function(r)
			if r.ok then
				call:reply(r.data)
			else
				call:fail(r.err or "qf failed")
			end
		end)
		return call:wait(25000)
	end)
end

read_export("launches", "launches", "Recent Qualflare launches (newest first) for a qf identifier, default the focused pane's project. Items have seq, status, passedCount, failedCount, skippedCount, flakyCount, environmentName, branch, createdAt.")
read_export("clusters", "clusters", "Qualflare failure clusters: groups of similar failures with label, severity, failureCount, rootCause, fixSuggestion and sampleFailures.")

tern.carly.export("project", {
	sig = "() -> {root: string, identifier: string, packages: {any}}?",
	doc = "The Qualflare project of the focused pane, from .qualflare/test-state.md; nil when there is none.",
}, function(cx: WindowCx, _call: ExportCall)
	local proj = focused_project(cx)
	if proj == nil then
		return nil
	end
	local p = proj :: project.Project
	return { root = p.root, identifier = p.package.identifier, packages = p.packages }
end)

tern.carly.context(function(cx: WindowCx): string?
	local proj = focused_project(cx)
	if proj == nil then
		return nil
	end
	local id = (proj :: project.Project).package.identifier
	local u = tern.kv.get("last_upload")
	local last = if type(u) == "table" and u.identifier == id then ` Last upload: {u.label}.` else ""
	return `Focused pane is in Qualflare project "{id}" (qf {id} …).{last}`
end)
