--!strict
-- Runs the `qf` CLI. The plugin never handles tokens: `qf login` keeps them in
-- the user's config, and every call here goes through the CLI.

local M = {}

-- Tern started from the Dock gets a short PATH, so look in the usual places.
local CANDIDATES = {
	"/opt/homebrew/bin/qf",
	"/usr/local/bin/qf",
	"/home/linuxbrew/.linuxbrew/bin/qf",
}

local cached: string? = nil

-- The `qf` executable: the `qf_path` setting, then QF_BIN, then known
-- install locations, then a plain PATH lookup.
function M.bin(): string
	if cached then
		return cached
	end
	local configured = tern.kv.get("qf_path")
	if type(configured) == "string" and configured ~= "" then
		cached = configured
		return configured
	end
	local env = tern.getenv("QF_BIN")
	if env and env ~= "" then
		cached = env
		return env
	end
	local home = tern.getenv("HOME")
	local list = table.clone(CANDIDATES)
	if home then
		table.insert(list, home .. "/.local/bin/qf")
		table.insert(list, home .. "/go/bin/qf")
	end
	for _, p in list do
		if tern.fs.exists(p) then
			cached = p
			return p
		end
	end
	cached = "qf"
	return "qf"
end

function M.reset()
	cached = nil
end

-- What a `qf` exit status means (qualflare-cli cmd/main.go).
function M.explain(status: number): (string, string)
	if status == 0 then
		return "Uploaded", "success"
	elseif status == 3 then
		return "Not logged in", "bad"
	elseif status == 4 then
		return "Forbidden or plan limit", "bad"
	elseif status == 5 then
		return "Not found", "bad"
	elseif status == 7 then
		return "Server busy, retry", "warn"
	elseif status == -1 then
		return "Timed out", "warn"
	end
	return "Failed", "bad"
end

-- `out` is the start of stdout when it wasn't JSON, so a caller can tell a
-- help page from, say, a proxy's login page.
export type Result = { ok: boolean, data: any?, status: number, err: string?, out: string? }

-- Runs `qf <args>`; spawn failures (almost always `qf` missing) come back as
-- status 127 with an install hint.
local function spawn(args: { string }, cwd: string?, cb: (ProcessResult?, string?) -> ())
	local argv = { M.bin() }
	for _, a in args do
		table.insert(argv, a)
	end
	local ok, err = pcall(function()
		tern.process.run(argv, { cwd = cwd, timeout_ms = 20000 }, function(res: ProcessResult)
			cb(res, nil)
		end)
	end)
	if not ok then
		cb(nil, "Can't run qf (" .. tostring(err) .. "). Install it with `brew install qualflare/tap/qf`.")
	end
end

local function first_error_line(res: ProcessResult): string
	return string.match(res.stderr, "[^\n]+") or ("exit " .. res.status)
end

-- Runs a read command (`qf <id> launches list`, …) and decodes its JSON.
function M.read(args: { string }, cwd: string?, cb: (Result) -> ())
	spawn(args, cwd, function(res, spawn_err)
		if res == nil then
			cb({ ok = false, status = 127, err = spawn_err })
			return
		end
		if res.status ~= 0 then
			cb({ ok = false, status = res.status, err = first_error_line(res) })
			return
		end
		local dok, data = pcall(tern.json.decode, res.stdout)
		if not dok then
			cb({ ok = false, status = 0, err = "qf printed something that isn't JSON", out = string.sub(res.stdout, 1, 2000) })
			return
		end
		cb({ ok = true, status = 0, data = data })
	end)
end

export type Lines = { ok: boolean, lines: { string }, status: number, err: string? }

-- Runs a command that prints plain lines (`qf projects`): its non-empty
-- lines, trimmed.
function M.lines(args: { string }, cwd: string?, cb: (Lines) -> ())
	spawn(args, cwd, function(res, spawn_err)
		if res == nil then
			cb({ ok = false, lines = {}, status = 127, err = spawn_err })
			return
		end
		if res.status ~= 0 then
			cb({ ok = false, lines = {}, status = res.status, err = first_error_line(res) })
			return
		end
		local out: { string } = {}
		for line in string.gmatch(res.stdout, "[^\n]+") do
			local t = string.match(line, "^%s*(.-)%s*$")
			if t and t ~= "" then
				table.insert(out, t)
			end
		end
		cb({ ok = true, lines = out, status = 0 })
	end)
end

-- Quotes `s` for a POSIX shell.
function M.quote(s: string): string
	if string.match(s, "^[%w%._/:@%-+=]+$") then
		return s
	end
	return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

return M
