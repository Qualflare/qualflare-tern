--!strict
-- Decides which shell commands are test runs, and where their reports land.

local M = {}

-- Splits a command line into words (no quote handling; good enough to look
-- at the program and its first arguments).
function M.words(line: string): { string }
	local out = {}
	for w in string.gmatch(line, "%S+") do
		table.insert(out, w)
	end
	return out
end

-- Drops what comes before the real program: `VAR=value` assignments and
-- wrappers such as `npx`, `bunx`, `pnpm exec`, `env`, `time`.
function M.strip_wrappers(words: { string }): { string }
	local WRAPPERS = { npx = 1, bunx = 1, env = 1, time = 1, sudo = 1, dotenv = 1 }
	local MANAGERS = { pnpm = 1, yarn = 1, bun = 1, npm = 1 } -- `pnpm exec x`, `yarn x`
	local i = 1
	while i <= #words do
		local w = words[i]
		if string.match(w, "^[%a_][%w_]*=") or WRAPPERS[w] then
			i += 1
		elseif MANAGERS[w] and (words[i + 1] == "exec" or words[i + 1] == "dlx") then
			i += 2
		else
			break
		end
	end
	return table.move(words, i, #words, 1, {})
end

-- Runners that always mean a test run, whatever their arguments.
local ALWAYS: { [string]: boolean } = {
	jest = true,
	vitest = true,
	mocha = true,
	pytest = true,
	["py.test"] = true,
	detox = true,
	maestro = true,
	["cucumber-js"] = true,
	-- Qualflare's own wrappers for Go and Maestro
	["qualflare-go"] = true,
	["qualflare-maestro"] = true,
}

-- Tools where only one subcommand runs tests.
local SUBCOMMAND: { [string]: string } = {
	go = "test",
	flutter = "test",
	dart = "test",
	playwright = "test",
	cypress = "run",
	wdio = "run",
}

local PACKAGE_MANAGERS: { [string]: boolean } = { npm = true, pnpm = true, yarn = true, bun = true }

-- Script and target names that mean tests: `test`, `test:e2e`, `test-ci`, `e2e`, `e2e:ci`.
local function is_test_name(name: string): boolean
	return string.match(name, "^test") ~= nil or string.match(name, "^e2e") ~= nil
end

-- Whether any argument after the program (flags skipped) satisfies `pred`.
local function any_arg(words: { string }, pred: (string) -> boolean): boolean
	for i = 2, #words do
		local a = words[i]
		if string.sub(a, 1, 1) ~= "-" and pred(a) then
			return true
		end
	end
	return false
end

-- Is `line`, as typed at the prompt, a test run worth offering an upload for?
--
-- `words` is the command with wrappers and `VAR=` prefixes removed, so
-- `CI=1 npx playwright test --project=chromium` arrives as
-- {"playwright", "test", "--project=chromium"}. `words[1]` may still carry a
-- path (`./gradlew`, `node_modules/.bin/jest`).
--
-- Returning true only arms the check: nothing is suggested unless the command
-- also wrote a report file into one of `report_dirs` while it ran.
function M.is_test_command(line: string): boolean
	local words = M.strip_wrappers(M.words(line))
	if #words == 0 then
		return false
	end
	local program = string.match(words[1], "([^/]+)$") or words[1]
	local sub = words[2]

	-- Runners whose name alone means a test run.
	if ALWAYS[program] then
		return true
	end
	-- `python -m pytest`
	if (program == "python" or program == "python3") and sub == "-m" and words[3] == "pytest" then
		return true
	end
	-- `<tool> <subcommand>`: `go test` counts, `go build` doesn't.
	if sub ~= nil and SUBCOMMAND[program] == sub then
		return true
	end
	-- Gradle: any task ending in "test" (`test`, `connectedAndroidTest`, `:app:testDebugUnitTest`).
	if program == "gradle" or program == "gradlew" then
		return any_arg(words, function(a)
			local task = string.match(a, "([^:]+)$") or a
			return string.match(string.lower(task), "test$") ~= nil
		end)
	end
	if program == "mvn" or program == "mvnw" then
		return any_arg(words, function(a)
			return a == "test" or a == "verify" or a == "integration-test"
		end)
	end
	-- Package scripts: `npm test`, `npm t`, `npm run test:e2e`, `pnpm e2e`, `bun test`.
	if PACKAGE_MANAGERS[program] and sub ~= nil then
		if program == "npm" and sub == "t" then
			return true
		end
		local script = if sub == "run" or sub == "run-script" then words[3] else sub
		return script ~= nil and is_test_name(script)
	end
	-- `make test`, `make -j4 test-e2e`, `just e2e`
	if program == "make" or program == "just" then
		return any_arg(words, is_test_name)
	end
	return false
end

-- Whether a command that ended with `status` should still get the upload
-- prompt: passes and failures yes, a run interrupted with Ctrl-C or killed
-- by a signal (128 + signal, or negative) no, since its report may be partial.
function M.finished_normally(status: number): boolean
	return status >= 0 and status < 128
end

-- Where reports from a run in `project` can land, as absolute directories.
-- `/qf-run` writes under `.qualflare/results/`; the Qualflare reporters
-- default to `qualflare-results/` in the package; `extra` comes from the
-- `report_dirs` setting (paths relative to the package).
function M.report_dirs(root: string, package_path: string, extra: { string }?): { string }
	local pkg = if package_path == "" then root else root .. "/" .. package_path
	local dirs = {
		root .. "/.qualflare/results",
		pkg .. "/qualflare-results",
	}
	if pkg ~= root then
		table.insert(dirs, root .. "/qualflare-results")
	end
	local list: { string } = extra or {}
	for _, d in list do
		table.insert(dirs, if string.sub(d, 1, 1) == "/" then d else pkg .. "/" .. d)
	end
	local out = {}
	for _, d in dirs do
		if tern.fs.exists(d) then
			table.insert(out, d)
		end
	end
	return out
end

-- What to put after `qf <id> collect`: the files themselves when there are a
-- few, else the directory they share (qf merges a directory into one launch).
-- `p` relative to `cwd` when it is inside it, else unchanged.
function M.relative(p: string, cwd: string): string
	if string.sub(p, 1, #cwd + 1) == cwd .. "/" then
		return string.sub(p, #cwd + 2)
	end
	return p
end

function M.collect_targets(files: { string }, cwd: string): { string }
	local function rel(p: string): string
		return M.relative(p, cwd)
	end
	if #files <= 3 then
		local out = {}
		for _, f in files do
			table.insert(out, rel(f))
		end
		table.sort(out)
		return out
	end
	-- Longest common directory.
	local common = string.match(files[1], "^(.*)/[^/]*$") or files[1]
	for _, f in files do
		while string.sub(f, 1, #common + 1) ~= common .. "/" do
			common = string.match(common, "^(.*)/[^/]*$") or "/"
			if common == "/" then
				break
			end
		end
	end
	return { rel(common) }
end

return M
