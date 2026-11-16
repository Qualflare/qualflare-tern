-- A stand-in for Tern's `tern` global, enough to load host.luau and
-- window.luau outside Tern and drive their handlers.
local json = require("./json")

local S = {
	files = {} :: { [string]: string },
	kv = {} :: { [string]: any },
	lenses = {} :: { [string]: any },
	blocks = {} :: { [string]: any },
	hooks = {} :: { [string]: { any } },
	widgets = {} :: { [string]: any },
	commands = {} :: { [string]: any },
	exports = {} :: { [string]: any },
	routes = {} :: { any },
	writes = {} :: { { pane: number, text: string } },
	toasts = {} :: { { string } },
	opened = {} :: { string },
	runs = {} :: { { string } },
	panes = {} :: { any },
	-- argv[1]..argv[n] joined by spaces -> ProcessResult
	process = {} :: { [string]: any },
	clock = 0,
}

local function node(k: string, p: any?, c: any?)
	return { k = k, p = p, c = c }
end

local ui = {
	node = function(k, p, c)
		return node(k, p, c)
	end,
	span = function(t, s)
		return { t = t, s = s }
	end,
	link = function(t, href, s)
		return { t = t, s = s, href = href }
	end,
	path = function(p, _cwd)
		return { t = p, s = "path" }
	end,
	text = function(spans)
		return node("text", { spans = spans })
	end,
	col = function(c)
		return node("col", nil, c)
	end,
	lines = function(c)
		return node("lines", nil, c)
	end,
	row = function(c)
		return node("row", nil, c)
	end,
	card = function(head, c, p)
		return node("card", { head = head, props = p }, c)
	end,
	section = function(head, c)
		return node("section", { head = head }, c)
	end,
	rule = function(label)
		return node("rule", { label = label })
	end,
	badge = function(t, tone)
		return node("badge", { t = t, tone = tone })
	end,
	button = function(text, p)
		return node("button", { text = text, props = p })
	end,
	stats = function(items)
		return node("stats", { items = items })
	end,
	kv = function(items)
		return node("kv", { items = items })
	end,
	table = function(cols, rows, opts)
		return node("table", { cols = cols, rows = rows, opts = opts })
	end,
	meter_cell = function(v)
		return { meter = { value = v } }
	end,
	progress = function(v, label)
		return node("progress", { value = v, label = label })
	end,
	overflow = function(n)
		return node("overflow", { n = n })
	end,
	test_summary = function(p, f, s, t)
		return node("test_summary", { p, f, s, t })
	end,
	list = function(items)
		return node("list", { items = items })
	end,
	md = function(t)
		return node("md", { t = t })
	end,
}

local function effect_cx(extra: any?)
	local cx = extra or {}
	function cx:toast(level, text, sub)
		table.insert(S.toasts, { level, text, sub })
	end
	function cx:open(target)
		table.insert(S.opened, target)
	end
	function cx:copy(_t) end
	return cx
end
S.effect_cx = effect_cx

local function block_cx(pane: number, cwd: string?)
	local cx = effect_cx({ pane = pane, cwd = cwd, cols = 100, rows = 30, renders = 0 })
	function cx:render()
		self.renders += 1
	end
	function cx:save() end
	function cx:exit(_c) end
	return cx
end
S.block_cx = block_cx

local function window_cx(focused: number?)
	local cx = effect_cx({ blocks = {} })
	cx.session = {
		focused = function(_)
			return focused
		end,
		panes = function(_)
			return S.panes
		end,
		pane = function(_, p)
			for _, info in S.panes do
				if info.pane == p then
					return info
				end
			end
			return nil
		end,
	}
	cx.agents = {
		start = function(_, opts)
			table.insert(S.runs, { "agent", opts.prompt, opts.cwd })
			return 99
		end,
	}
	function cx:new_block(kind, args, how)
		table.insert(self.blocks, { kind, args, how })
		return 77
	end
	function cx:run(pane, text)
		table.insert(S.writes, { pane = pane, text = text })
	end
	return cx
end
S.window_cx = window_cx

tern = {
	context = "host",
	plugin = { id = "qualflare", name = "Qualflare", dir = "/plugin", data = "/data" },
	log = { info = print, warn = print, error = print, debug = function() end },
	json = { decode = json.decode, null = json.null, encode = function()
		return "{}"
	end },
	now = function()
		return S.clock
	end,
	getenv = function(name)
		return if name == "HOME" then "/home/u" else nil
	end,
	timer = function(_ms, _fn)
		return { cancel = function() end }
	end,
	kv = {
		get = function(k)
			return S.kv[k]
		end,
		set = function(k, v)
			S.kv[k] = v
		end,
	},
	fs = {
		exists = function(p)
			if S.files[p] ~= nil then
				return true
			end
			for f in S.files do
				if string.sub(f, 1, #p + 1) == p .. "/" then
					return true
				end
			end
			return false
		end,
		read = function(p, _max)
			return S.files[p] or error("no such file: " .. p)
		end,
		write = function(p, t)
			S.files[p] = t
		end,
		mkdir = function(_p) end,
		list = function(_p)
			return {}
		end,
		remove = function(p)
			S.files[p] = nil
		end,
	},
	process = {
		run = function(argv, _opts, cb)
			table.insert(S.runs, argv)
			local key = table.concat(argv, " ")
			local res = S.process[key]
			if res == nil then
				for pat, r in S.process do
					if string.find(key, pat, 1, true) then
						res = r
					end
				end
			end
			cb(res or { status = 1, stdout = "", stderr = "no stub for " .. key, timed_out = false }, nil)
		end,
	},
	ui = ui,
	pane = {
		write = function(pane, text)
			table.insert(S.writes, { pane = pane, text = text })
		end,
		list = function()
			return S.panes
		end,
	},
	on = function(name, fn)
		S.hooks[name] = S.hooks[name] or {}
		table.insert(S.hooks[name], fn)
	end,
	lens = { define = function(id, def)
		S.lenses[id] = def
	end },
	block = { define = function(id, def)
		S.blocks[id] = def
	end },
	chrome = {
		widget = function(id, spec)
			S.widgets[id] = spec
		end,
		refresh = function() end,
		status = function() end,
	},
	route = {
		link = function(fn)
			table.insert(S.routes, fn)
		end,
		open = function(_fn) end,
	},
	command = function(def)
		S.commands[def.id] = def
	end,
	carly = {
		export = function(name, spec, fn)
			S.exports[name] = { spec = spec, fn = fn }
		end,
		context = function(fn)
			S.exports["@context"] = { fn = fn }
		end,
	},
}

function S.fire(name: string, ev: any, cx: any?)
	for _, fn in S.hooks[name] or {} do
		fn(ev, cx or effect_cx())
	end
end

-- Every string in a view tree, joined, for "does it show X" checks.
function S.text(n: any): string
	local out = {}
	local function walk(x)
		if type(x) == "string" then
			table.insert(out, x)
		elseif type(x) == "number" then
			table.insert(out, tostring(x))
		elseif type(x) == "table" then
			for k, v in x do
				if k ~= "tone" and k ~= "s" and k ~= "k" then
					walk(v)
				end
			end
		end
	end
	walk(n)
	return table.concat(out, " | ")
end

-- Every node kind in a view tree, space-separated, for "has a skeleton" checks.
function S.kind_list(n: any): string
	local out = {}
	local function walk(x)
		if type(x) == "table" then
			if type(x.k) == "string" then
				table.insert(out, x.k)
			end
			for _, v in x do
				walk(v)
			end
		end
	end
	walk(n)
	return table.concat(out, " ")
end

function S.reset()
	S.writes, S.toasts, S.opened, S.runs = {}, {}, {}, {}
end

return S
