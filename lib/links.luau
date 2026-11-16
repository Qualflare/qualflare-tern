--!strict
-- Qualflare dashboard links, and the plugin's own `qualflare-tern:` links:
-- a host block can't start an agent or type into a terminal, so it opens one
-- of these and the window's link route does the work.

local views = require("./views")

local M = {}

local APP = "https://app.qualflare.com/project/"
local SCHEME = "qualflare-tern:"

-- The project slug and launch number of a dashboard launch link, or nil for
-- anything else (only links to one launch are claimed).
function M.launch_from_url(url: string): { slug: string, seq: number }?
	if string.sub(url, 1, #APP) ~= APP then
		return nil
	end
	local slug, query = string.match(string.sub(url, #APP + 1), "^([^/?#]+)/launches%?([^#]*)")
	if slug == nil or query == nil then
		return nil
	end
	local seq = string.match("&" .. query, "&p%.seq=(%d+)")
	if seq == nil then
		return nil
	end
	return { slug = slug, seq = tonumber(seq) :: number }
end

-- The identifier among `known` whose dashboard slug is `slug`.
function M.identifier_for(slug: string, known: { string }): string?
	for _, id in known do
		if views.slug(id) == slug then
			return id
		end
	end
	return nil
end

local function encode(s: string): string
	return (string.gsub(s, "[^%w%-%._~]", function(c: string): string
		return string.format("%%%02X", string.byte(c))
	end))
end

local function decode(s: string): string
	return (string.gsub(s, "%%(%x%x)", function(h: string): string
		return string.char(tonumber(h, 16) :: number)
	end))
end

-- `qualflare-tern:<action>?k=v&…`, keys sorted, values percent-encoded.
function M.bridge(action: string, params: { [string]: string }): string
	local keys: { string } = {}
	for k in params do
		table.insert(keys, k)
	end
	table.sort(keys)
	local parts: { string } = {}
	for _, k in keys do
		table.insert(parts, `{k}={encode(params[k])}`)
	end
	return SCHEME .. action .. (if #parts > 0 then "?" .. table.concat(parts, "&") else "")
end

-- The action and parameters of a `qualflare-tern:` link; nil for any other URL.
function M.parse_bridge(url: string): (string?, { [string]: string })
	local params: { [string]: string } = {}
	if string.sub(url, 1, #SCHEME) ~= SCHEME then
		return nil, params
	end
	local action, query = string.match(string.sub(url, #SCHEME + 1), "^([%w_]+)%??(.*)$")
	if action == nil then
		return nil, params
	end
	for k, v in string.gmatch(query :: string, "([^&=]+)=([^&]*)") do
		params[decode(k)] = decode(v)
	end
	return action, params
end

return M
