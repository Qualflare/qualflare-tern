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
	-- the project's folder; nil when this pane's folder isn't that project
	root: string?,
	-- the newest failure clusters, fetched when the newest launch failed
	clusters: { any }?,
	-- the seq of a launch an upload from a terminal just added
	fresh: number?,
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
		return "Open this pane from a folder of the project to upload or fix"
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
			ui.button("Dashboard", { key = "dashboard", icon = "gauge", keys = { "d" }, disabled = s.identifier == nil, actions = { click = "dashboard" } }),
			ui.button("Upload", { key = "upload", icon = "push", keys = { "u" }, disabled = hand_off_reason(s), actions = { click = "upload" } }),
			ui.button("Refresh", { key = "refresh", icon = "repeat", keys = { "r" }, busy = s.loading, disabled = s.identifier == nil, actions = { click = "refresh" } }),
		}),
	})
end

local STALE_DAYS = 7
local TREND_MAX = 20

-- The one-line answer to "is my latest run OK?" for the newest launch.
function M.verdict(l: any, now: number): { tone: string, text: string }
	local failed = views.failed(l)
	local total = num(l.totalCount)
	local parts: { string } = {}
	local tone
	if failed > 0 then
		tone = "error"
		table.insert(parts, if total >= failed then `✗ {failed} of {total} failing` else `✗ {failed} failing`)
		table.insert(parts, str(l.branch))
	elseif views.failing(l) then
		-- marked failed, but no failing tests counted
		tone = "error"
		local said = ({ error = "errored", timeout = "timed out" } :: { [string]: string })[str(l.status)] or "failed"
		table.insert(parts, `✗ Latest run {said}`)
		table.insert(parts, str(l.branch))
	elseif str(l.status) == "passed" then
		tone = "success"
		table.insert(parts, "✓ Latest run passed")
		table.insert(parts, if total > 0 then `{total} tests` else "")
	else
		tone = "info"
		local status = str(l.status)
		table.insert(parts, if status ~= "" then `● Latest run {status}` else "● Latest run")
		table.insert(parts, str(l.branch))
	end
	table.insert(parts, str(l.environmentName))
	table.insert(parts, views.ago(l.createdAt, now))
	local shown: { string } = {}
	for _, p in parts do
		if p ~= "" then
			table.insert(shown, p)
		end
	end
	return { tone = tone, text = table.concat(shown, " · ") }
end

local function pass_rate(l: any): number
	local total = num(l.totalCount)
	return if total > 0 then math.floor(num(l.passedCount) / total * 100 + 0.5) else 0
end

-- Verdict, then staleness or what changed, then the trend of recent runs.
local function overview(s: TabState, launches: { any }): Node
	local newest = launches[1]
	local v = M.verdict(newest, s.now)
	local head: { Node } = { ui.text({ ui.span(v.text, v.tone) }) }
	if s.fresh ~= nil and s.fresh == newest.seq then
		table.insert(head, ui.badge("new", "accent"))
	end
	local parts: { Node } = { ui.node("row", { key = "verdict", gap = "sm", align = "center", wrap = true }, head) }

	local days = views.days(newest.createdAt, s.now)
	if days ~= nil and days > STALE_DAYS then
		local how = if hand_off_reason(s) == false
			then "Run your tests, then press U to upload."
			else `Run your tests and upload with qf {s.identifier or "<id>"} collect.`
		table.insert(parts, ui.text({ ui.span(`No runs in {days} days. {how}`, "warning") }))
	else
		-- Compare like with like: the last run on the same branch and environment.
		local prev = nil
		for i = 2, #launches do
			local l = launches[i]
			if str(l.branch) == str(newest.branch) and str(l.environmentName) == str(newest.environmentName) then
				prev = l
				break
			end
		end
		if prev then
			table.insert(parts, ui.text({ ui.span(views.change(newest, prev), "muted") }))
		end
	end

	if #launches > 1 then
		local series = {}
		local n = math.min(#launches, TREND_MAX)
		for i = n, 1, -1 do
			local l = launches[i]
			local failed = views.failed(l)
			table.insert(series, {
				value = pass_rate(l),
				label = `#{str(l.seq)}`,
				title = `#{str(l.seq)} · {str(l.status)} · {num(l.passedCount)} passed, {failed} failed`,
				tone = if views.failing(l) then "error" else "success",
			})
		end
		table.insert(parts, ui.node("chart", {
			key = "trend",
			kind = "bars",
			-- 4 lines: tall enough that 92% and 100% look different
			size = "md",
			min = 0,
			max = 100,
			series = series,
			summary = { ui.span(`Pass rate, last {n} runs`, "muted") },
		}))
	end
	return ui.node("col", { key = "overview", gap = "sm" }, parts)
end

-- Wrapping lines with bullets: list rows never wrap, and these are sentences.
local function bullet_list(items: { string }): Node
	local rows: { Node } = {}
	for _, t in items do
		table.insert(rows, ui.text({ ui.span("• ", "muted"), ui.span(t) }))
	end
	return ui.node("col", { gap = "xs" }, rows)
end

local function card(l: any, s: TabState): Node
	local failed = views.failed(l)
	local facts: { string } = {}
	for _, v in { str(l.framework), str(l.os), str(l.browser), string.sub(str(l.commit), 1, 8), str(l.milestoneName), views.when(l.createdAt) } do
		if v ~= "" then
			table.insert(facts, v)
		end
	end

	-- Drawn at the card head's end: the card's `end` prop names its full id
	-- (main → launches row → detail card → status).
	local status = ui.badge(str(l.status), views.tone(l.status))
	status.p = status.p or {}
	;(status.p :: any).key = "status"
	local body: { Node } = { status }
	local sum = views.summary(l)
	if sum then
		local summary = sum :: views.Summary
		table.insert(body, ui.text(summary.text))
		if summary.risk then
			local risk = summary.risk :: string
			table.insert(body, ui.node("row", { gap = "sm" }, { ui.badge(`Risk: {risk}`, RISK_TONE[risk] or "muted") }))
			if summary.why then
				table.insert(body, ui.text(summary.why :: string))
			end
		end
		if #summary.areas > 0 then
			table.insert(body, ui.section("Failing areas", { bullet_list(summary.areas) }))
		end
		if #summary.recommendations > 0 then
			table.insert(body, ui.section("Recommendations", { bullet_list(summary.recommendations) }))
		end
	else
		local counts = `{num(l.passedCount)} passed · {failed} failed · {num(l.skippedCount)} skipped. No AI summary yet.`
		table.insert(body, ui.text({ ui.span(counts, "muted") }))
	end
	if #facts > 0 then
		table.insert(body, ui.text({ ui.span(table.concat(facts, " · "), "muted") }))
	end
	local buttons: { Node } = {
		ui.button("Open on website", { key = "open", variant = "primary", icon = "open", keys = { "enter" }, actions = { click = "open" } }),
	}
	if views.failing(l) then
		table.insert(buttons, ui.button("Fix with omp", { key = "fix", icon = "app-omp", disabled = hand_off_reason(s), actions = { click = "fix" } }))
	end
	table.insert(body, ui.node("row", { gap = "sm", wrap = true }, buttons))

	local head: { string } = { `#{str(l.seq)}` }
	for _, v in { str(l.branch), str(l.environmentName) } do
		if v ~= "" then
			table.insert(head, v)
		end
	end
	local c = ui.card(table.concat(head, " · "), body, { key = "detail", icon = "list-checks", ["end"] = "main.launches.detail.status" })
	c.p = c.p or {}
	;(c.p :: any).key = "detail"
	;(c.p :: any).grow = 1
	-- Starting widths (60% table, 36% card, plus the gap) fit one row, so
	-- the card only wraps under the table when the minimum widths don't fit.
	;(c.p :: any).basis = 0.36
	;(c.p :: any).min = { w = "36ch" }
	;(c.p :: any).max = { w = "60ch" }
	return c
end

-- The newest failure clusters, when the newest run failed.
local function where_to_look(s: TabState, launches: { any }): Node?
	local clusters = s.clusters
	if clusters == nil or #clusters == 0 or not views.failing(launches[1]) then
		return nil
	end
	-- Clusters last seen before the newest run aren't about it.
	local since = views.epoch(launches[1].createdAt)
	local top: { any } = {}
	for _, c in clusters do
		local seen = views.epoch(c.lastSeenAt)
		if since == nil or seen == nil or seen >= since then
			table.insert(top, c)
		end
		if #top == 3 then
			break
		end
	end
	if #top == 0 then
		return nil
	end
	return ui.section("Where to look", { views.clusters_table(top, s.now) })
end

local function empty(props: { [string]: any }, buttons: { Node }?): Node
	props.key = props.key or "state"
	props.grow = 1
	return ui.node("empty", props, buttons)
end

local function legend(): Node
	return ui.text({
		ui.span("↑↓ select · ⏎ open on website · R refresh · D dashboard · U upload · P project", "muted"),
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
		table.insert(parts, overview(s, launches))
		local left: { Node } = {
			views.launches_table(launches, { selected = if l then `launch={str(l.seq)}` else nil, now = s.now, max = 200, buttons = false }),
		}
		if s.more then
			table.insert(left, ui.button("Show more", { key = "more", variant = "quiet", size = "sm", busy = s.loading, actions = { click = "more" } }))
		end
		local row: { Node } = { ui.node("col", { key = "list", gap = "sm", grow = 2, basis = 0.6, min = { w = "44ch" } }, left) }
		if l then
			table.insert(row, card(l, s))
		end
		-- wrap: in a narrow pane the card drops under the table
		table.insert(parts, ui.node("row", { key = "launches", gap = "lg", align = "start", wrap = true }, row))
		local look = where_to_look(s, launches)
		if look then
			table.insert(parts, look)
		end
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
