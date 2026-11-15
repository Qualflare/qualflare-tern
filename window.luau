--!strict
-- Window half: palette commands, Carly exports, and the omp hand-off.

local detect = require("./lib/detect")
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
		cx:new_block("qualflare.launches", args, "split")
	end,
})

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
		local extra = tern.kv.get("report_dirs")
		local dirs = detect.report_dirs(p.root, p.package.path, if type(extra) == "table" then extra else nil)
		if #dirs == 0 then
			cx:toast("info", "No report folder yet", "Run your tests with a Qualflare reporter, or /qf-run.")
			return
		end
		local target = detect.relative(dirs[1], cwd :: string)
		-- Typed, not run: the person checks it and presses Enter.
		cx:run(pane :: number, `qf {p.package.identifier} collect {qf.quote(target)}`)
	end,
})

tern.command({
	id = "dashboard",
	title = "Qualflare: Open dashboard",
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
		-- Needs the Qualflare plugin in omp (its qf-fix skill).
		cx.agents:start({ prompt = "/skill:qf-fix", cwd = (proj :: project.Project).root, how = "split" })
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
