--!strict
-- Finds the Qualflare project a directory belongs to, from the
-- `.qualflare/test-state.md` that `/qf-init` (Claude Code or omp) writes.

local M = {}

export type Package = {
	path: string, -- relative to root; "" for the root package
	identifier: string, -- the `qf <identifier>` alias
}

export type Project = {
	root: string, -- absolute directory holding `.qualflare/`
	package: Package, -- the package `cwd` falls in
	packages: { Package },
}

local function parent(dir: string): string?
	local p = string.match(dir, "^(.*)/[^/]+/?$")
	if p == nil then
		return nil
	end
	return if p == "" then "/" else p
end

local function trim(s: string): string
	return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

-- Reads the `## Packages` table: `| Path | Identifier |` rows.
function M.parse_packages(text: string): { Package }
	local out: { Package } = {}
	local in_table = false
	for line in string.gmatch(text .. "\n", "([^\n]*)\n") do
		if string.match(line, "^##%s") then
			in_table = string.match(line, "^##%s+Packages%s*$") ~= nil
		elseif in_table then
			local a, b = string.match(line, "^%s*|([^|]*)|([^|]*)|")
			if a and b then
				local path, ident = trim(a), trim(b)
				local is_header = path == "Path" or string.match(path, "^%-+$") ~= nil
				if not is_header and string.match(ident, "^[a-z0-9][a-z0-9_-]*$") then
					if path == "(root)" or path == "." then
						path = ""
					end
					path = (string.gsub(path, "/+$", ""))
					table.insert(out, { path = path, identifier = ident })
				end
			end
		end
	end
	return out
end

-- Walks up from `cwd` to the nearest directory with `.qualflare/test-state.md`.
function M.find(cwd: string): Project?
	local dir: string? = cwd
	while dir do
		local state = dir .. "/.qualflare/test-state.md"
		if tern.fs.exists(state) then
			local ok, text = pcall(tern.fs.read, state, 256 * 1024)
			if not ok then
				return nil
			end
			local packages = M.parse_packages(text)
			if #packages == 0 then
				return nil
			end
			-- The package whose path is the longest prefix of cwd.
			local rel = if cwd == dir then "" else string.sub(cwd, #dir + 2)
			local best: Package? = nil
			for _, p in packages do
				local inside = p.path == "" or rel == p.path or string.sub(rel, 1, #p.path + 1) == p.path .. "/"
				if inside and (best == nil or #p.path > #best.path) then
					best = p
				end
			end
			if best == nil then
				best = packages[1]
			end
			return { root = dir, package = best :: Package, packages = packages }
		end
		if dir == "/" then
			break
		end
		dir = parent(dir)
	end
	return nil
end

-- `find`, remembered for a while per directory: the window calls it from
-- formatters with a 4 ms budget, where walking up the tree each time is too slow.
local CACHE_MS = 15000
local cache: { [string]: { at: number, project: Project? } } = {}

function M.find_cached(cwd: string): Project?
	local now = tern.now()
	local hit = cache[cwd]
	if hit and now - hit.at < CACHE_MS then
		return hit.project
	end
	local p = M.find(cwd)
	cache[cwd] = { at = now, project = p }
	return p
end

return M
