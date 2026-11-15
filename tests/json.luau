-- Minimal JSON decoder for the test stub (the Luau CLI has no JSON).
local M = {}
M.null = setmetatable({}, { __tostring = function()
	return "null"
end })

function M.decode(s: string): any
	local i = 1
	local function ws()
		i = string.find(s, "[^ \t\r\n]", i) or (#s + 1)
	end
	local value
	local function str(): string
		local out = {}
		i += 1 -- opening quote
		while true do
			local c = string.sub(s, i, i)
			if c == "" then
				error("unterminated string")
			elseif c == '"' then
				i += 1
				return table.concat(out)
			elseif c == "\\" then
				local e = string.sub(s, i + 1, i + 1)
				local map = { n = "\n", t = "\t", r = "\r", b = "\b", f = "\f", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
				if e == "u" then
					table.insert(out, utf8.char(tonumber(string.sub(s, i + 2, i + 5), 16) :: number))
					i += 6
				else
					table.insert(out, map[e] or e)
					i += 2
				end
			else
				table.insert(out, c)
				i += 1
			end
		end
	end
	function value(): any
		ws()
		local c = string.sub(s, i, i)
		if c == "{" then
			local t = {}
			i += 1
			ws()
			if string.sub(s, i, i) == "}" then
				i += 1
				return t
			end
			while true do
				ws()
				local k = str()
				ws()
				assert(string.sub(s, i, i) == ":", "expected : at " .. i)
				i += 1
				local v = value()
				if v ~= M.null then
					t[k] = v
				end
				ws()
				local d = string.sub(s, i, i)
				i += 1
				if d == "}" then
					return t
				end
				assert(d == ",", "expected , or } at " .. i)
			end
		elseif c == "[" then
			local t = {}
			i += 1
			ws()
			if string.sub(s, i, i) == "]" then
				i += 1
				return t
			end
			while true do
				table.insert(t, value())
				ws()
				local d = string.sub(s, i, i)
				i += 1
				if d == "]" then
					return t
				end
				assert(d == ",", "expected , or ] at " .. i)
			end
		elseif c == '"' then
			return str()
		elseif string.sub(s, i, i + 3) == "true" then
			i += 4
			return true
		elseif string.sub(s, i, i + 4) == "false" then
			i += 5
			return false
		elseif string.sub(s, i, i + 3) == "null" then
			i += 4
			return M.null
		else
			local n = string.match(s, "^-?%d+%.?%d*[eE]?[-+]?%d*", i)
			assert(n and n ~= "", "unexpected character at " .. i .. ": " .. c)
			i += #n
			return tonumber(n)
		end
	end
	local v = value()
	ws()
	if i <= #s then
		error("trailing data at " .. i)
	end
	return v
end

return M
