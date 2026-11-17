--!strict
-- The Qualflare dashboard's page: the project Overview from
-- `qf <id> overview --days 7|28`, as six cards (headline against the project's
-- target, change against the previous window, daily line). A pure function of
-- the block's state, laid out like the launches pane.

local qf = require("./qf")
local views = require("./views")

local ui = tern.ui
local M = {}

export type DashState = {
	identifier: string?,
	projects: { string },
	-- 7 or 28
	days: number,
	-- the decoded `qf overview` answer
	data: any?,
	error: string?,
	status: number?,
	-- `qf` printed something other than JSON: a version without `overview`
	outdated: boolean,
	loading: boolean,
	-- Unix seconds
	now: number,
	refreshed: number?,
	menu_open: boolean,
	menu_active: string?,
}

-- Whether a rising value is good, per KPI; nil for neither (launches).
local HIGHER_IS_BETTER: { [string]: boolean } = {
	successRate = true,
	automationRate = true,
	flakeRate = false,
	launchP90 = false,
	defectsOpened = false,
}

-- After this long without a new metrics bucket, say the numbers are stale.
local STALE_S = 30 * 60
-- After this long without a successful refresh of its own (it tries every
-- minute), the pane says when it last managed one.
local REFRESH_LATE_S = 3 * 60

local function number(v: any): number?
	return if type(v) == "number" then v else nil
end

local function duration(secs: number): string
	local s = math.floor(secs + 0.5)
	if s < 60 then
		return `{s}s`
	elseif s < 3600 then
		return `{s // 60}m {s % 60}s`
	end
	return `{s // 3600}h {(s % 3600) // 60}m`
end

-- The card's big number: "94.3%", "4m 12s", "5 today", or "–".
function M.headline(kpi: any): string
	local v = number(kpi.latest)
	if v == nil then
		return "–"
	end
	local value = v :: number
	if kpi.unit == "percent" then
		return if kpi.key == "automationRate" then string.format("%.0f%%", value) else string.format("%.1f%%", value)
	elseif kpi.unit == "seconds" then
		return duration(value)
	end
	return `{math.floor(value + 0.5)} today`
end

-- The change badge: "▲ 3.5%" in green when that direction is good for this
-- KPI, red when bad, muted for launches; "no change" within the server's
-- threshold; nil when there is nothing to compare.
function M.change(kpi: any): { text: string, tone: string }?
	if kpi.trend == "none" then
		return { text = "no change", tone = "muted" }
	end
	local pct = number(kpi.percentChange)
	if pct == nil then
		return nil
	end
	local p = pct :: number
	local up = if kpi.trend == "up" then true elseif kpi.trend == "down" then false else p > 0
	local text = `{if up then "▲" else "▼"} {string.format("%.1f", math.abs(p))}%`
	local good = HIGHER_IS_BETTER[kpi.key]
	local tone = if good == nil then "muted" elseif up == good then "success" else "error"
	return { text = text, tone = tone }
end

-- Whether the headline meets the project's target (the website's metric
-- card): nil when there's no target, no reading, or no good direction.
function M.meets(kpi: any): boolean?
	local good = HIGHER_IS_BETTER[kpi.key]
	local v, target = number(kpi.latest), number(kpi.target)
	if good == nil or v == nil or target == nil then
		return nil
	end
	return if good then (v :: number) >= (target :: number) else (v :: number) <= (target :: number)
end

local function head(s: DashState): Node
	local menu = ui.node("select", {
		key = "project",
		variant = "quiet",
		options = s.projects,
		value = s.identifier,
		placeholder = "Project",
		open = s.menu_open,
		active = s.menu_active,
	})
	local left: { Node } = { ui.text({ ui.span("Qualflare", "title") }), menu }
	local through = if s.data then s.data.dataThrough else nil
	local meta = "Dashboard"
	if type(through) == "string" then
		meta ..= ` · data from {views.ago(through, s.now)}`
	end
	table.insert(left, ui.text({ ui.span(meta, "muted") }))
	local function window(days: number): Node
		return ui.button(`{days} days`, {
			key = `days{days}`,
			size = "sm",
			variant = if s.days == days then "primary" else "quiet",
			actions = { click = `days{days}` },
		})
	end
	return ui.node("row", { key = "head", justify = "between", align = "center", wrap = true }, {
		ui.node("row", { key = "start", gap = "sm", align = "center" }, left),
		ui.node("row", { key = "end", gap = "sm", align = "center" }, {
			window(7),
			window(28),
			ui.button("Open on website", { key = "open", icon = "open", keys = { "enter" }, disabled = s.identifier == nil, actions = { click = "open" } }),
			ui.button("Launches", { key = "launches", icon = "list-checks", keys = { "l" }, disabled = s.identifier == nil, actions = { click = "launches" } }),
			ui.button("Refresh", { key = "refresh", icon = "repeat", keys = { "r" }, busy = s.loading, disabled = s.identifier == nil, actions = { click = "refresh" } }),
		}),
	})
end

local function line(kpi: any, buckets: { any }): Node
	local series = {}
	local labels = {}
	local values = if type(kpi.values) == "table" then kpi.values else {}
	for i = 1, #buckets do
		local v = number(values[i])
		-- A table without a value is a gap in the line.
		table.insert(series, if v then { value = v } else {})
		local b = buckets[i]
		table.insert(labels, if type(b) == "string" then string.sub(b, 6) else "")
	end
	local unit = if kpi.unit == "percent" then "%" elseif kpi.unit == "seconds" then "s" else nil
	return ui.node("chart", { kind = "line", size = "sm", series = series, labels = labels, unit = unit, last = false })
end

local function card(kpi: any, buckets: { any }): Node
	local verdict = M.meets(kpi)
	local tone = if verdict == true then "success" elseif verdict == false then "error" else nil
	local top: { Node } = { ui.text({ ui.span(M.headline(kpi), if tone then "title " .. tone else "title") }) }
	local change = M.change(kpi)
	if change then
		local c = change :: { text: string, tone: string }
		table.insert(top, ui.badge(c.text, c.tone))
	end
	local body: { Node } = { ui.node("row", { gap = "sm", align = "center" }, top) }
	local target = number(kpi.target)
	if target then
		local shown = M.headline({ key = kpi.key, unit = kpi.unit, latest = target })
		table.insert(body, ui.text({ ui.span(`Target {shown}`, "muted") }))
	end
	table.insert(body, line(kpi, buckets))
	local label = if type(kpi.label) == "string" then kpi.label else tostring(kpi.key)
	local c = ui.card(label, body, {})
	c.p = c.p or {}
	;(c.p :: any).key = kpi.key
	;(c.p :: any).grow = 1
	;(c.p :: any).basis = 0.3
	;(c.p :: any).min = { w = "26ch" }
	return c
end

local function empty(props: { [string]: any }, buttons: { Node }?): Node
	props.key = props.key or "state"
	props.grow = 1
	return ui.node("empty", props, buttons)
end

local function legend(): Node
	return ui.text({
		ui.span("W window · R refresh · L launches · P project · ⏎ open on website", "muted"),
	})
end

function M.view(s: DashState): BlockView
	local parts: { Node } = { head(s) }
	local id = s.identifier
	local data = s.data

	if id == nil then
		table.insert(parts, empty({
			icon = "folder",
			title = "No Qualflare project here",
			text = "Run /qf-init in Claude Code or omp, or pick a project above.",
		}))
	elseif s.outdated then
		table.insert(parts, empty({
			icon = "push",
			title = "Update qf to use the dashboard",
			text = "This qf has no overview command. Update it: brew install qualflare/tap/qf, or npm install -g @qualflare/cli.",
		}, {
			ui.button("Retry", { key = "retry", icon = "repeat", actions = { click = "retry" } }),
		}))
	elseif s.error ~= nil and data == nil then
		local label = qf.explain(s.status or 1)
		local text = if s.status == 3 then `Run qf login {id} in a terminal.` else s.error
		table.insert(parts, empty({ tone = "error", title = label, text = text }, {
			ui.button("Retry", { key = "retry", icon = "repeat", actions = { click = "retry" } }),
		}))
	elseif data == nil then
		table.insert(parts, ui.node("skeleton", { key = "cards-loading", shape = "card", tiles = 6 }))
	else
		local kpis: { any } = if type(data.kpis) == "table" then data.kpis else {}
		if type(data.dataThrough) == "string" then
			-- Judged at the pane's last refresh, not now: a laptop that slept
			-- doesn't make the server's metrics stale.
			local through = views.epoch(data.dataThrough)
			local at = s.refreshed or s.now
			if through and at - (through :: number) > STALE_S then
				table.insert(parts, ui.text({ ui.span(`Metrics last updated {views.ago(data.dataThrough, s.now)}.`, "warning") }))
			end
		else
			-- The numbers came, but not how fresh they are (the server couldn't
			-- read the rollup's watermark, or it has never run).
			table.insert(parts, ui.text({ ui.span("Metrics data age unknown.", "muted") }))
		end
		if s.refreshed and s.now - (s.refreshed :: number) > REFRESH_LATE_S then
			table.insert(parts, ui.text({ ui.span(`Last refreshed {views.ago(s.refreshed, s.now)}.`, "muted") }))
		end
		if type(data.warnings) == "table" then
			for _, w in data.warnings do
				if type(w) == "string" and w ~= "" then
					table.insert(parts, ui.text({ ui.span(w, "warning") }))
				end
			end
		end
		if s.error then
			table.insert(parts, ui.text({ ui.span(s.error :: string, "error") }))
		end
		local any = false
		for _, kpi in kpis do
			if number(kpi.latest) ~= nil then
				any = true
			end
		end
		if not any then
			table.insert(parts, ui.text({ ui.span(`No metrics yet. They appear a few minutes after the first upload: qf {id} collect.`, "muted") }))
		end
		local buckets = if type(data.buckets) == "table" then data.buckets else {}
		local cards: { Node } = {}
		for _, kpi in kpis do
			table.insert(cards, card(kpi, buckets))
		end
		table.insert(parts, ui.node("row", { key = "cards", gap = "lg", align = "start", wrap = true }, cards))
		local n = if type(data.window) == "table" and type(data.window.days) == "number" then data.window.days else s.days
		table.insert(parts, ui.text({ ui.span(`Change: the latest day against the daily average of the {n} days before. Launches and defects count today (UTC).`, "muted") }))
	end

	return {
		main = ui.node("col", { gap = "lg" }, parts),
		dock = legend(),
	}
end

return M
