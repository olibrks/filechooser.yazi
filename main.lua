-- Add file chooser management
local M = {}

local get_state = ya.sync(function(state)
	return {
		cfg			= state.cfg,
		home		= state.home,
		path		= state.path,
		method		= state.method,
		directory	= state.directory,
		multiple	= state.multiple,
	}
end)

local get_context = ya.sync(function(use_hovered)
	local h = use_hovered and cx.active.current.hovered or cx.active.selected[1]
	return {
		active_url = h and tostring(h.url),
		active_is_dir = h and h.cha.is_dir,
		active_len	= h and h.cha.len or 0,
		nb_selected	= #cx.active.selected,
	}
end)

local get_selected_list = ya.sync(function()
	local selected = cx.active.selected
	local t = {}
	for _, file in pairs(selected) do
		table.insert(t, tostring(file.url))
	end
	return t
end)

local confirm_selected = function(state)
	local CONFIRM_LINES = 11
	local selected_urls = get_selected_list()
	local total = #selected_urls
	local shown = total > CONFIRM_LINES and CONFIRM_LINES - 1 or total

	local body_lines = {}
	for i = 1, shown do
		local url = ya.readable_path(selected_urls[i], state.home)
		table.insert(body_lines, ui.Line(url):align(ui.Align.LEFT))
	end
	if total > shown then
		local more = total - shown
		table.insert(body_lines, ui.Line(string.format("and %d more item%s", more, more == 1 and "" or "s")):align(ui.Align.LEFT))
	end

	return ya.confirm {
		pos = { "center", w = 60, h = CONFIRM_LINES + 4 },
		title = string.format("Open %d item%s?", total, total == 1 and "" or "s"),
		body = ui.Text(body_lines),
	}
end

local choose_file = function (state, ctx)
	local prompt = string.format("Please choose one%s %s%s",
		state.multiple and " or more" or "",
		state.directory == nil and "item" or state.directory and "folder" or "file",
		state.multiple and "s" or ""
	)

	-- multiple check
	if not state.hovered and ctx.nb_selected > 1 and state.multiple == false then
		ya.notify { title = "filechooser", content = prompt, timeout = 6.5, level = "warn" }
		return false
	end

	-- directory lazy check
	if (ctx.active_is_dir and state.directory == false) or (not ctx.active_is_dir and state.directory == true) then
		ya.notify { title = "filechooser", content = prompt, timeout = 6.5, level = "warn" }
		return false
	end

	if state.method == "OpenFile" then
		return true
	end

	-- SAVE methods
	-- check if active file is empty
	local is_empty = ctx.active_len == 0
	if ctx.active_is_dir then
		local files, err = fs.read_dir(Url(ctx.active_url), { limit = 1 })
		if not files then
			ya.dbg(string.format("filechooser - io error: %s", err))
		end
		is_empty = files and #files == 0 or false
	end

	-- overwrite dialog
	if state.cfg.overwrite_dialog and not is_empty then
		local path = ya.readable_path(ctx.active_url, state.home)
		return ya.confirm {
			pos = { "center", w = 60, h = 8 },
			title   = string.format("Overwrite %s?", ctx.active_is_dir and "folder content" or "file"),
			body    = ui.Line(path):align(ui.Align.LEFT),
		}
	end
	return true
end

local get_style = function()
	local m, s = th.mode, ui.Style():fg("reset"):bg("reset")
	if m.chooser_main and m.chooser_alt then
		return { main = s:patch(m.chooser_main), alt = s:patch(m.chooser_alt) }
	else
		return { main = s:patch(m.normal_main), alt = s:patch(m.normal_alt) }
	end
end

local add_header = function(opts, title)

	Header:children_add(function(self)
        local style = get_style()

    	return ui.Line {
            ui.Span(th.status.sep_right.open):fg(style.alt:bg()),
            ui.Span(" "..title .. " "):style(style.alt),
            ui.Span(th.status.sep_right.open):fg(style.main:bg()):bg(style.alt:bg()),
            ui.Span(" CHOOSER "):style(style.main),
            ui.Span(th.status.sep_right.close):fg(style.main:bg()):bg(App.bg()),
        }
	end, 3000, Header.RIGHT)
end

local ttypicker_meta = function(path)
	local f, e = io.open(tostring(path), "rb")
	if not f then
		return nil, string.format("failed to open TTYPICKER meta: %s", e)
	end
	local content = f:read("*a")
	f:close()

	local meta, err = ya.json_decode(content)
	if type(meta) ~= "table" then
		return nil, string.format("failed to get TTYPICKER meta: %s", err)
	end
	return meta
end

function M:setup(opts)
	opts = opts or {}
	self.cfg = {
        overwrite_dialog    = opts.overwrite_dialog == nil or opts.overwrite_dialog,
        open_multi_dialog   = type(opts.open_multi_dialog) == "number" and opts.open_multi_dialog >= 0 and opts.open_multi_dialog or 0,
    }
	self.home = os.getenv("HOME") or "/"

    -- DEFAULT mode
	if not rt.args.chooser_file then
		return
	end

	-- FILE CHOOSER mode
	if not rt.args.entries or #rt.args.entries < 1 then
		ya.err("filechooser - no path present")
        return
	end
	local path = tostring(rt.args.entries[1])
	self.path = path:match("%S") and path or self.home

	local cha = fs.cha(Url(self.path))

	-- TTYPICKER integration
	local ttypicker_req = os.getenv("TTYPICKER_REQ")
	if ttypicker_req then
		self.method = os.getenv("TTYPICKER_METHOD")
		if self.method ~= "OpenFile" and self.method ~= "SaveFile" and self.method ~= "SaveFiles" then
			ya.err("filechooser - invalid TTYPICKER_METHOD")
			return
		end
		local meta, err = ttypicker_meta(ttypicker_req)
		if not meta then
			ya.err(string.format("filechooser - %s", err))
			return
		end
		self.multiple = meta.options and meta.options.multiple
		self.directory = meta.options and meta.options.directory

	else
		-- using suggested path to infer file chooser method
		self.method = cha and cha.is_dir and "OpenFile" or "SaveFile"
	end

	-- Show header
	if opts.header == nil or opts.header then
		add_header(opts, string.sub(self.method, 1, 4))
	end

	if self.method == "OpenFile" then
		return
	end

	-- SAVE methods
	self.multiple = false
	self.directory = self.method == "SaveFiles"

	if not cha then
		ya.dbg("filechooser - no placeholder created for suggested path")
		return
	end

   local init_done = false

    ps.sub("cd", function()
        if init_done then return end
        init_done = true
        -- Reveal suggested path
        ya.emit("reveal", { tostring(self.path), no_dummy = false, raw = true })
        -- Yank the placeholder file in cut mode
        if opts.yank_save_dummy and cha.len == 0 then
            ya.emit("yank", { cut = true })
        end

    end)

    if cha and cha.is_hidden then
        ya.emit("hidden", { "show" })
	end

end

function M:entry(job)
	local state = get_state()
	local smart = job.args.smart or false
	state.hovered = smart or job.args.hovered or false

	local ctx = get_context(state.hovered)

	-- smart enter - enter directory
	if smart and ctx.active_is_dir then
		ya.emit("enter", { hovered = true })
		return
	end

	if not rt.args.chooser_file or choose_file(state, ctx) then
		-- confirm multiple selection
		if not state.hovered and state.cfg.open_multi_dialog > 0 and ctx.nb_selected > state.cfg.open_multi_dialog and not confirm_selected(state) then
			return
		end
		ya.emit("open", { hovered = state.hovered})
	end
end

return M