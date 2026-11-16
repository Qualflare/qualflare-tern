--!strict
-- The Qualflare tab's page: a pure function of the block's state, laid out
-- as Tern's design guide asks (head row, stats strip, view, key legend).

local qf = require("./qf")
local views = require("./views")

local ui = tern.ui
local M = {}

export type TabState = {
	identifier: string?,
	projects: { string },
	launches: { any }?,
	-- another page of launches exists
	more: boolean,
	error: string?,
	status: number?,
	loading: boolean,
	-- the selected launch's `seq`
	selected: number?,
	-- Unix seconds
	now: number,
	refreshed: number?,
	menu_open: boolean,
	-- the highlighted project while the menu is open
	menu_active: string?,
	-- an older launch fetched on its own for the card
	pinned: any?,
	-- the project's folder; nil when this tab's folder isn't that project
	root: string?,
}

local RISK_TONE: { [string]: string } = {
	low = "muted",
	medium = "warning",
	high = "error",
	critical = "error",
}

local function str(v: any): string
	if v == nil or v == tern.json.null then
		return ""
	end
	return tostring(v)
end

local function num(v: any): number
	return if type(v) == "number" then v else 0
end

-- The launch the card shows: the selected one, else the newest.
function M.selected_launch(s: TabState): any?
	local launches = s.launches
	if launches == nil or #launches == 0 then
		return nil
	end
	if s.selected ~= nil then
		for _, l in launches do
			if l.seq == s.selected then
				return l
			end
		end
		if s.pinned and s.pinned.seq == s.selected then
			return s.pinned
		end
	end
	return launches[1]
end

-- Why Upload and Fix can't run here, or false when they can.
local function hand_off_reason(s: TabState): string | boolean
	if s.identifier == nil then
		return true
	end
	if s.root == nil then
		return "Open this tab from a folder of the project to upload or fix"
	end
	return false
end

local function head(s: TabState): Node
	local title: { Span | string } = { ui.span("Qualflare", "title") }
	local menu = ui.node("select", {
		key = "project",
		variant = "quiet",
		options = s.projects,
		value = s.identifier,
		placeholder = "Project",
		open = s.menu_open,
		active = s.menu_active,
	})
	local meta = if s.refreshed then ui.text({ ui.span(`· updated {views.ago(s.refreshed, s.now)}`, "muted") }) else nil
	local left: { Node } = { ui.text(title), menu }
	if meta then
		table.insert(left, meta)
	end
	return ui.node("row", { key = "head", justify = "between", align = "center" }, {
		ui.node("row", { key = "start", gap = "sm", align = "center" }, left),
		ui.node("row", { key = "end", gap = "sm", align = "center" }, {
			ui.button("Upload", { key = "upload", icon = "push", keys = { "u" }, disabled = hand_off_reason(s), actions = { click = "upload" } }),
			ui.button("Refresh", { key = "refresh", icon = "repeat", keys = { "r" }, busy = s.loading, disabled = s.identifier == nil, actions = { click = "refresh" } }),
		}),
	})
end

local function stats(l: any, now: number): Node
	local total = num(l.totalCount)
	local rate = if total > 0 then `{math.floor(num(l.passedCount) / total * 100 + 0.5)}%` else "–"
	local failed = views.failed(l)
	local flaky = num(l.flakyCount)
	local node = ui.stats({
		{ label = "Pass rate", value = rate, sub = `#{str(l.seq)}` },
		{ label = "Failed", value = tostring(failed), tone = if failed > 0 then "error" else nil },
		{ label = "Flaky", value = tostring(flaky), tone = if flaky > 0 then "warning" else nil },
		{ label = "Last run", value = views.ago(l.createdAt, now) },
	})
	node.p = node.p or {}
	;(node.p :: any).key = "stats"
	return node
end

local function bullet_list(items: { string }): Node
	local rows: { Item } = {}
	for _, t in items do
		table.insert(rows, { label = t })
	end
	return ui.list(rows)
end

local function card(l: any, s: TabState): Node
	local failed = views.failed(l)
	local facts: { { Spans } } = {}
	local function fact(label: string, value: any)
		local v = str(value)
		if v ~= "" then
			table.insert(facts, { label, v })
		end
	end
	fact("Framework", l.framework)
	fact("OS", l.os)
	fact("Browser", l.browser)
	local commit = str(l.commit)
	fact("Commit", string.sub(commit, 1, 8))
	fact("Milestone", l.milestoneName)
	fact("Created", views.when(l.createdAt))

	local body: { Node } = {
		ui.badge(str(l.status), views.tone(l.status)),
		ui.test_summary(num(l.passedCount), failed, num(l.skippedCount), nil),
	}
	if #facts > 0 then
		table.insert(body, ui.kv(facts))
	end
	local sum = views.summary(l)
	if sum then
		local summary = sum :: views.Summary
		table.insert(body, ui.text(summary.text))
		if summary.risk then
			local risk = summary.risk :: string
			local line: { Node } = { ui.badge(`Risk: {risk}`, RISK_TONE[risk] or "muted") }
			if summary.why then
				table.insert(line, ui.text({ ui.span(summary.why :: string, "muted") }))
			end
			table.insert(body, ui.node("row", { gap = "sm", align = "center" }, line))
		end
		if #summary.areas > 0 then
			table.insert(body, ui.section("Failing areas", { bullet_list(summary.areas) }))
		end
		if #summary.recommendations > 0 then
			table.insert(body, ui.section("Recommendations", { bullet_list(summary.recommendations) }))
		end
	end
	local buttons: { Node } = {
		ui.button("Open on website", { key = "open", variant = "primary", icon = "open", keys = { "enter" }, actions = { click = "open" } }),
	}
	if failed > 0 then
		table.insert(buttons, ui.button("Fix with omp", { key = "fix", icon = "app-omp", disabled = hand_off_reason(s), actions = { click = "fix" } }))
	end
	table.insert(body, ui.node("row", { gap = "sm" }, buttons))

	local env = str(l.environmentName)
	local branch = str(l.branch)
	local title = `#{str(l.seq)} · {if branch ~= "" then branch else "no branch"}{if env ~= "" then " · " .. env else ""}`
	local c = ui.card(title, body, { key = "detail", icon = "list-checks" })
	c.p = c.p or {}
	;(c.p :: any).min = { w = "36ch" }
	;(c.p :: any).max = { w = "48ch" }
	return c
end

local function empty(props: { [string]: any }, buttons: { Node }?): Node
	props.key = props.key or "state"
	props.grow = 1
	return ui.node("empty", props, buttons)
end

local function legend(): Node
	return ui.text({
		ui.span("↑↓ select · ⏎ open on website · R refresh · U upload · P project", "muted"),
	})
end

function M.view(s: TabState): BlockView
	local parts: { Node } = { head(s) }
	local launches = s.launches
	local id = s.identifier

	if id == nil then
		table.insert(parts, empty({
			icon = "folder",
			title = "No Qualflare project here",
			text = "Run /qf-init in Claude Code or omp, or pick a project above.",
		}))
	elseif s.error ~= nil and (launches == nil or #(launches :: { any }) == 0) then
		local label = qf.explain(s.status or 1)
		local text = if s.status == 3 then `Run qf login {id} in a terminal.` else s.error
		table.insert(parts, empty({ tone = "error", title = label, text = text }, {
			ui.button("Retry", { key = "retry", icon = "repeat", actions = { click = "retry" } }),
		}))
	elseif launches == nil then
		table.insert(parts, ui.node("skeleton", { key = "stats-loading", shape = "card", tiles = 4 }))
		table.insert(parts, ui.node("skeleton", { key = "launches-loading", shape = "rows", rows = 6 }))
	elseif #launches == 0 then
		table.insert(parts, empty({
			icon = "inbox",
			title = "No launches yet",
			text = `Upload results with qf {id} collect, or press U.`,
		}, {
			ui.button("Upload", { key = "upload-empty", variant = "primary", icon = "push", actions = { click = "upload" } }),
		}))
	else
		local l = M.selected_launch(s)
		table.insert(parts, stats(launches[1], s.now))
		local left: { Node } = {
			views.launches_table(launches, { selected = if l then `launch={str(l.seq)}` else nil, now = s.now, max = 200, buttons = false }),
		}
		if s.more then
			table.insert(left, ui.button("Show more", { key = "more", variant = "quiet", size = "sm", busy = s.loading, actions = { click = "more" } }))
		end
		local row: { Node } = { ui.node("col", { key = "list", gap = "sm", grow = 1 }, left) }
		if l then
			table.insert(row, card(l, s))
		end
		table.insert(parts, ui.node("row", { key = "launches", gap = "lg", align = "start" }, row))
		if s.error then
			-- A refresh failed but older data is still worth showing.
			table.insert(parts, 2, ui.text({ ui.span(s.error :: string, "error") }))
		end
	end

	return {
		main = ui.node("col", { gap = "lg" }, parts),
		dock = legend(),
	}
end

return M
