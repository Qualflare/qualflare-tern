--!strict
-- Views shared by the lenses and the launches block. Field names follow the
-- token API (api-service public/api/responses): lists are {items, paging}.

local ui = tern.ui
local M = {}

local APP = "https://app.qualflare.com"

-- The dashboard slug for a `qf` identifier: the `slugs` setting, else the
-- identifier itself (the CLI README suggests naming it after the slug).
function M.slug(identifier: string): string
	local map = tern.kv.get("slugs")
	if type(map) == "table" and type(map[identifier]) == "string" then
		return map[identifier]
	end
	return identifier
end

function M.launch_url(identifier: string, seq: any): string
	return `{APP}/project/{M.slug(identifier)}/launches?p=launch&p.seq={seq}`
end

function M.cluster_url(identifier: string, id: any): string
	return `{APP}/project/{M.slug(identifier)}/clusters/{id}`
end

function M.defect_url(identifier: string, seq: any): string
	return `{APP}/project/{M.slug(identifier)}/defects?p=defect&p.seq={seq}`
end

-- Marks a dashboard URL the plugin itself opens, so the link route lets it
-- through to the browser instead of opening the tab again.
M.OWN = "src=tern"

function M.own(url: string): string
	return url .. (if string.find(url, "?", 1, true) then "&" else "?") .. M.OWN
end

function M.project_url(identifier: string, page: string?): string
	return `{APP}/project/{M.slug(identifier)}/{page or "launches"}`
end

local STATUS_TONE: { [string]: string } = {
	passed = "success",
	failed = "error",
	error = "error",
	timeout = "error",
	aborted = "warning",
	skipped = "muted",
	pending = "info",
	draft = "muted",
	-- clusters
	analysed = "success",
	-- severities
	critical = "error",
	high = "error",
	medium = "warning",
	low = "muted",
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

-- "2026-11-15T14:32:10Z" -> "2026-11-15 14:32"
function M.when(ts: any): string
	local s = str(ts)
	local d, t = string.match(s, "^(%d%d%d%d%-%d%d%-%d%d)T(%d%d:%d%d)")
	return if d then `{d} {t}` else s
end

-- Days since 1970-01-01 for a civil date (Howard Hinnant's days_from_civil).
local function days_from_civil(y: number, m: number, d: number): number
	if m <= 2 then
		y -= 1
	end
	local era = y // 400
	local yoe = y - era * 400
	local mp = if m > 2 then m - 3 else m + 9
	local doy = (153 * mp + 2) // 5 + d - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	return era * 146097 + doe - 719468
end

-- An ISO-8601 UTC timestamp ("2026-10-28T12:24:11.911391Z") as Unix seconds.
function M.epoch(ts: any): number?
	local y, mo, d, h, mi, se = string.match(str(ts), "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
	if y == nil then
		return nil
	end
	local days = days_from_civil(tonumber(y) :: number, tonumber(mo) :: number, tonumber(d) :: number)
	return days * 86400 + (tonumber(h) :: number) * 3600 + (tonumber(mi) :: number) * 60 + (tonumber(se) :: number)
end

local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

-- Whole days since `ts` (an ISO timestamp or Unix seconds), or nil.
function M.days(ts: any, now: number): number?
	local t = if type(ts) == "number" then ts else M.epoch(ts)
	if t == nil then
		return nil
	end
	return math.max(0, now - t) // 86400
end

-- "just now", "5 min ago", "3 h ago", "12 d ago", then the date ("Oct 28",
-- or "Oct 28, 2025" in another year) from 30 days on.
-- `ts` is an ISO timestamp or Unix seconds; seconds always stay relative.
function M.ago(ts: any, now: number): string
	local t = if type(ts) == "number" then ts else M.epoch(ts)
	if t == nil then
		return ""
	end
	local secs = math.max(0, now - t)
	if secs < 60 then
		return "just now"
	elseif secs < 3600 then
		return `{secs // 60} min ago`
	elseif secs < 86400 then
		return `{secs // 3600} h ago`
	elseif secs < 30 * 86400 or type(ts) == "number" then
		return `{secs // 86400} d ago`
	end
	local y, mo, d = string.match(str(ts), "^(%d%d%d%d)%-(%d%d)%-(%d%d)")
	local year, month, day = tonumber(y) :: number, tonumber(mo) :: number, tonumber(d) :: number
	local label = `{MONTHS[month] or mo} {day}`
	local next_year = days_from_civil(year + 1, 1, 1) * 86400
	if now >= next_year then
		return `{label}, {year}`
	end
	return label
end

-- How a launch differs from the one before it, e.g.
-- "+2 tests · 8 more failing than #41", or "Same counts as #41".
function M.change(cur: any, prev: any): string
	local parts: { string } = {}
	local tests = num(cur.totalCount) - num(prev.totalCount)
	if tests > 0 then
		table.insert(parts, `+{tests} tests`)
	elseif tests < 0 then
		table.insert(parts, `−{-tests} tests`)
	end
	local failing = M.failed(cur) - M.failed(prev)
	local ref = `#{str(prev.seq)}`
	if failing > 0 then
		table.insert(parts, `{failing} more failing than {ref}`)
	elseif failing < 0 then
		table.insert(parts, `{-failing} fewer failing than {ref}`)
	elseif #parts > 0 then
		parts[#parts] ..= ` since {ref}`
	end
	if #parts == 0 then
		return `Same counts as {ref}`
	end
	return table.concat(parts, " · ")
end

-- Failures of any kind in a launch: failed, errored and timed out.
function M.failed(l: any): number
	return num(l.failedCount) + num(l.errorCount) + num(l.timeoutCount)
end

export type Summary = { text: string, risk: string?, why: string?, areas: { string }, recommendations: { string } }

-- One line for an item of `failingAreas` or `recommendations`: a string, or
-- a table with a name (`area`, `name`, `title`) and maybe a `description`.
local function line_of(v: any): string?
	if type(v) == "string" then
		return if v ~= "" then v else nil
	end
	if type(v) ~= "table" then
		return nil
	end
	local name = v.area or v.name or v.title or v.text
	local desc = v.description or v.detail
	if type(name) == "string" and type(desc) == "string" and desc ~= "" then
		return `{name}: {desc}`
	end
	return if type(name) == "string" then name elseif type(desc) == "string" then desc else nil
end

local function lines_of(v: any): { string }
	local out: { string } = {}
	if type(v) == "table" then
		for _, item in v do
			local l = line_of(item)
			if l then
				table.insert(out, l)
			end
		end
	end
	return out
end

-- Qualflare's AI summary of a launch (`aiSummary`, a JSON string), or nil
-- while there is none, it is still pending, or it doesn't parse.
function M.summary(l: any): Summary?
	local raw = l.aiSummary
	if type(raw) ~= "string" then
		return nil
	end
	local ok, data = pcall(tern.json.decode, raw)
	if not ok or type(data) ~= "table" then
		return nil
	end
	local text = data.executiveSummary
	if type(text) ~= "string" or text == "" then
		return nil
	end
	return {
		text = text,
		risk = if type(data.riskLevel) == "string" then data.riskLevel else nil,
		why = if type(data.riskJustification) == "string" then data.riskJustification else nil,
		areas = lines_of(data.failingAreas),
		recommendations = lines_of(data.recommendations),
	}
end

-- The tone a status or severity is drawn in.
function M.tone(status: any): string
	return STATUS_TONE[str(status)] or "muted"
end

function M.badge(status: any): BadgeCell
	return { badge = { text = str(status), tone = M.tone(status) } }
end

export type Items = { any }

-- `{items = [...]}` (list endpoints) or a bare array.
function M.items(data: any): Items?
	if type(data) ~= "table" then
		return nil
	end
	if type(data.items) == "table" then
		return data.items
	end
	if data[1] ~= nil then
		return data
	end
	return nil
end

-- `now` (Unix seconds) shows ages ("12 min ago") instead of dates; `buttons =
-- false` drops the trailing open button (the tab opens the selected row).
function M.launches_table(items: Items, opts: { selected: string?, max: number?, now: number?, buttons: boolean? }?): Node
	local now = if opts then opts.now else nil
	local buttons = not (opts and opts.buttons == false)
	local cols: { Col } = {
		{ id = "seq", head = "#", mono = true, align = "end" },
		{ id = "status", head = "Status" },
		{ id = "pass", head = "Pass rate", grow = 1 },
		{ id = "counts", head = "Passed / failed / skipped", mono = true, priority = -1 },
		{ id = "env", head = "Environment", priority = -2 },
		{ id = "branch", head = "Branch", mono = true, priority = -3, truncate = "middle" },
		{ id = "created", head = if now then "Age" else "Created", mono = true, priority = -1 },
	}
	if buttons then
		table.insert(cols, { id = "open", head = "" })
	end
	local rows: { TableRow } = {}
	local max = if opts and opts.max then opts.max else 200
	for i, l in items do
		if i > max then
			break
		end
		local total = num(l.totalCount)
		local passed = num(l.passedCount)
		local failed = M.failed(l)
		local rate = if total > 0 then passed / total else 0
		local cells: { Cell } = {
			"#" .. str(l.seq),
			M.badge(l.status),
			ui.meter_cell(rate),
			`{passed} / {failed} / {num(l.skippedCount)}`,
			str(l.environmentName),
			str(l.branch),
			if now then M.ago(l.createdAt, now) else M.when(l.createdAt),
		}
		if buttons then
			table.insert(cells, { button = { text = "", icon = "open", act = "launch=" .. str(l.seq) } })
		end
		table.insert(rows, { id = "launch=" .. str(l.seq), cells = cells })
	end
	local out = ui.table(cols, rows, {
		selectable = true,
		selected = if opts then opts.selected else nil,
		empty = "No launches yet. Upload results with qf <id> collect.",
	})
	if #items > max then
		return ui.col({ out, ui.overflow(#items - max) })
	end
	return out
end

-- `now` (Unix seconds) shows "Last seen" as an age instead of a date.
function M.clusters_table(items: Items, now: number?): Node
	local cols: { Col } = {
		{ id = "severity", head = "Severity" },
		{ id = "label", head = "Failure", grow = 1 },
		{ id = "count", head = "Failures", mono = true, align = "end" },
		{ id = "last", head = "Last seen", mono = true, priority = -1 },
		{ id = "open", head = "" },
	}
	local rows: { TableRow } = {}
	for _, c in items do
		table.insert(rows, {
			id = "cluster=" .. str(c.id),
			title = str(c.summary),
			cells = ({
				M.badge(c.severity),
				str(c.label),
				str(c.failureCount),
				if now then M.ago(c.lastSeenAt, now :: number) else M.when(c.lastSeenAt),
				{ button = { text = "", icon = "open", act = "cluster=" .. str(c.id) } },
			} :: { Cell }),
		})
	end
	return ui.table(cols, rows, { selectable = true, empty = "No failure clusters." })
end

function M.defects_table(items: Items): Node
	local cols: { Col } = {
		{ id = "seq", head = "#", mono = true, align = "end" },
		{ id = "severity", head = "Severity" },
		{ id = "title", head = "Title", grow = 1 },
		{ id = "status", head = "Status" },
		{ id = "open", head = "" },
	}
	local rows: { TableRow } = {}
	for _, d in items do
		table.insert(rows, {
			id = "defect=" .. str(d.seq),
			cells = ({
				"#" .. str(d.seq),
				M.badge(d.severity),
				str(d.title or d.name),
				M.badge(d.status),
				{ button = { text = "", icon = "open", act = "defect=" .. str(d.seq) } },
			} :: { Cell }),
		})
	end
	return ui.table(cols, rows, { selectable = true, empty = "No defects." })
end

return M
