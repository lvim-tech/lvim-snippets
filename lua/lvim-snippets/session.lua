-- lvim-snippets.session: the live snippet session — render, track, jump, mirror, transform.
--
-- The back half of the plugin's own engine (the front half is `parser`). `vim.snippet` does the same
-- job but implements a subset: no transforms, no nested placeholders, no date variables, and its
-- state is private, so a consumer cannot ask where the stops are or drive a choice menu. This module
-- owns the whole lifecycle instead, which is what lets those work.
--
-- How the tracking works, and why this way:
--
-- Every tabstop is an EXTMARK PAIR (start/end) rather than a line/column pair. Extmarks are moved by
-- Neovim itself as text is inserted or deleted, so a stop that sits after the one being typed into
-- stays correct without any recomputation on our side — the naive approach (store offsets, shift them
-- on every keystroke) gets the arithmetic wrong the moment an edit spans a line break.
--
-- MIRRORS (the same index used twice) and TRANSFORMS are the reason a `TextChangedI` hook exists at
-- all: when the active stop's text changes, every other node bound to that index is rewritten from
-- it. The hook is scoped to the session's buffer and torn down with the session.
--
-- The session is deliberately NOT global: `M.active()` reports the session for the current buffer, so
-- two buffers can each have one, and closing a buffer cannot leave a stale session behind.
--
---@module "lvim-snippets.session"

local parser = require("lvim-snippets.parser")
local variables = require("lvim-snippets.variables")

local api = vim.api
local M = {}

local NS = api.nvim_create_namespace("LvimSnippetsSession")

---@class LvimSnippetsStop
---@field index integer                 the tabstop number (0 = the exit stop)
---@field marks integer[][]             one { start_id, end_id } extmark pair per occurrence
---@field choice? string[]              choice options, when this stop is a choice
---@field transforms table[]            transform nodes bound to this index

---@class LvimSnippetsSession
---@field buf integer
---@field stops LvimSnippetsStop[]      in jump order (ascending, 0 last)
---@field current integer               index into `stops`
---@field augroup integer

---@type table<integer, LvimSnippetsSession>  buffer -> its session
local sessions = {}

-- ── rendering ─────────────────────────────────────────────────────────────────────────────────────

--- Flatten a node tree into the text to insert plus the byte ranges each tabstop occupies.
--- Nested placeholders contribute their default text AND their own ranges, which is what makes
--- `${1:outer ${2:inner}}` land two independently jumpable stops.
---@param nodes LvimSnippetsNode[]
---@param ctx table  variable-resolution context
---@return string text, table[] ranges  { index, from, to, choice?, transform? }
local function render(nodes, ctx)
    local out, ranges = {}, {}
    local len = 0
    -- index -> the text that index first rendered as, so later bare `$n` occurrences mirror it
    local seed = {}

    local function emit(s)
        if s and s ~= "" then
            out[#out + 1] = s
            len = len + #s
        end
    end

    local function walk(list)
        for _, n in ipairs(list) do
            if n.type == "text" then
                emit(n.text)
            elseif n.type == "variable" then
                local v = variables.resolve(n.name, ctx)
                if v and v ~= "" then
                    emit(v)
                else
                    -- Unset variable: fall back to its default when it has one, else drop it. The
                    -- LSP spec says an unknown variable becomes its NAME as text, but that leaks
                    -- `$FOO` into the buffer for a typo, which is worse than nothing.
                    if n.children then
                        walk(n.children)
                    end
                end
            elseif n.type == "transform" then
                -- Rendered empty; the value arrives when its source stop is edited.
                ranges[#ranges + 1] = { index = n.index, from = len, to = len, transform = n }
            elseif n.type == "tabstop" or n.type == "placeholder" or n.type == "choice" then
                local from = len
                if n.type == "placeholder" and n.children then
                    walk(n.children)
                    -- Remember what this index renders as, so a bare `$1` MIRROR of it starts out
                    -- showing the same text. Without this the mirror renders empty and only catches
                    -- up on the first keystroke — `local ${1:name} = require("$1")` expanded to
                    -- `require("")`, which reads as a bug even though typing would fix it.
                    seed[n.index] = table.concat(out):sub(from + 1)
                elseif n.type == "choice" and n.items and n.items[1] then
                    emit(n.items[1])
                    seed[n.index] = n.items[1]
                elseif n.type == "tabstop" and seed[n.index] then
                    emit(seed[n.index])
                end
                ranges[#ranges + 1] = {
                    index = n.index,
                    from = from,
                    to = len,
                    choice = n.type == "choice" and n.items or nil,
                }
            end
        end
    end

    walk(nodes)
    return table.concat(out), ranges
end

--- Split a rendered string into lines and translate a byte offset into (row, col) within them.
---@param text string
---@return string[] lines
local function to_lines(text)
    return vim.split(text, "\n", { plain = true })
end

--- (row, col) of a byte offset inside `lines`, relative to the insertion point.
---@param lines string[]
---@param off integer
---@return integer row, integer col
local function pos_of(lines, off)
    local row, seen = 0, 0
    for i, l in ipairs(lines) do
        local line_end = seen + #l
        if off <= line_end then
            return row, off - seen
        end
        seen = line_end + 1 -- the newline
        row = i
    end
    return row, off - seen
end

-- ── session ───────────────────────────────────────────────────────────────────────────────────────

--- The session for `buf` (default: the current buffer), or nil.
---@param buf? integer
---@return LvimSnippetsSession?
function M.active(buf)
    buf = buf or api.nvim_get_current_buf()
    local s = sessions[buf]
    if s and not api.nvim_buf_is_valid(buf) then
        sessions[buf] = nil
        return nil
    end
    return s
end

--- The byte range an extmark pair currently spans.
---@param buf integer
---@param pair integer[]  { start_id, end_id }
---@return integer? srow, integer? scol, integer? erow, integer? ecol
local function mark_range(buf, pair)
    local s = api.nvim_buf_get_extmark_by_id(buf, NS, pair[1], {})
    local e = api.nvim_buf_get_extmark_by_id(buf, NS, pair[2], {})
    return s[1], s[2], e[1], e[2]
end

--- The text currently inside an extmark pair.
---@param buf integer
---@param pair integer[]  { start_id, end_id }
---@return string
local function mark_text(buf, pair)
    local sr, sc, er, ec = mark_range(buf, pair)
    if sr == nil or er == nil then
        return ""
    end
    local lines = api.nvim_buf_get_text(buf, sr, sc, er, ec, {})
    return table.concat(lines, "\n")
end

--- Write `text` into an extmark pair, leaving the marks around the new text.
---@param buf integer
---@param pair integer[]  { start_id, end_id }
---@param text string
local function set_mark_text(buf, pair, text)
    local sr, sc, er, ec = mark_range(buf, pair)
    if sr == nil or er == nil then
        return
    end
    api.nvim_buf_set_text(buf, sr, sc, er, ec, vim.split(text, "\n", { plain = true }))
end

--- Propagate the active stop's text to its mirrors and transforms.
---@param sess LvimSnippetsSession
local function sync(sess)
    local stop = sess.stops[sess.current]
    if not stop or #stop.marks < 2 then
        return
    end
    local src = mark_text(sess.buf, stop.marks[1])
    -- Mirrors: every further occurrence of this index gets the same text.
    for i = 2, #stop.marks do
        if mark_text(sess.buf, stop.marks[i]) ~= src then
            set_mark_text(sess.buf, stop.marks[i], src)
        end
    end
end

--- Apply the transforms bound to the active stop.
---@param sess LvimSnippetsSession
local function apply_transforms(sess)
    local stop = sess.stops[sess.current]
    if not stop or #stop.transforms == 0 then
        return
    end
    local src = mark_text(sess.buf, stop.marks[1])
    for _, t in ipairs(stop.transforms) do
        local ok, res = pcall(variables.transform, src, t.node)
        if ok and res ~= nil and mark_text(sess.buf, t.pair) ~= res then
            set_mark_text(sess.buf, t.pair, res)
        end
    end
end

--- Tear the session down: drop its extmarks, autocmds and registration.
---@param buf integer
local function teardown(buf)
    local sess = sessions[buf]
    if not sess then
        return
    end
    sessions[buf] = nil
    pcall(api.nvim_del_augroup_by_id, sess.augroup)
    if api.nvim_buf_is_valid(buf) then
        pcall(api.nvim_buf_clear_namespace, buf, NS, 0, -1)
    end
end

--- End the session for `buf` (default: current). Safe to call when there is none.
---@param buf? integer
function M.stop(buf)
    teardown(buf or api.nvim_get_current_buf())
end

--- Select the stop at `n` (an index into `sess.stops`): place the cursor, and select its text when
--- it has any, so typing replaces the placeholder — the behaviour every snippet engine has.
---@param sess LvimSnippetsSession
---@param n integer
local function goto_stop(sess, n)
    local stop = sess.stops[n]
    if not stop then
        return
    end
    sess.current = n
    local sr, sc, er, ec = mark_range(sess.buf, stop.marks[1])
    if sr == nil then
        return
    end
    local win = api.nvim_get_current_win()
    if sr == er and sc == ec then
        -- Empty stop: just put the cursor there, in insert mode.
        api.nvim_win_set_cursor(win, { sr + 1, sc })
        if api.nvim_get_mode().mode ~= "i" then
            vim.cmd("startinsert")
        end
    else
        -- Non-empty: select it so the next keystroke replaces it.
        api.nvim_win_set_cursor(win, { sr + 1, sc })
        vim.cmd("normal! v")
        api.nvim_win_set_cursor(win, { er + 1, math.max(ec - 1, 0) })
        vim.cmd("normal! o\\<C-g>")
        vim.api.nvim_feedkeys(api.nvim_replace_termcodes("<C-g>", true, false, true), "n", false)
    end
end

--- Is a session active for the current buffer, and can it move `direction`?
---@param opts? { direction?: integer }
---@return boolean
function M.active_jumpable(opts)
    local sess = M.active()
    if not sess then
        return false
    end
    local dir = (opts and opts.direction) or 1
    local n = sess.current + dir
    return n >= 1 and n <= #sess.stops
end

--- Jump to the next (1) or previous (-1) stop. Ends the session when it moves past the exit stop.
---@param direction integer
---@return boolean moved
function M.jump(direction)
    local sess = M.active()
    if not sess then
        return false
    end
    sync(sess)
    apply_transforms(sess)
    local n = sess.current + (direction or 1)
    if n < 1 or n > #sess.stops then
        return false
    end
    goto_stop(sess, n)
    -- Landing on the exit stop means the snippet is done; leave the cursor there and release.
    if sess.stops[n].index == 0 then
        teardown(sess.buf)
    end
    return true
end

--- The choice options at the active stop, or nil when it is not a choice.
---@return string[]?
function M.choices()
    local sess = M.active()
    if not sess then
        return nil
    end
    local stop = sess.stops[sess.current]
    return stop and stop.choice or nil
end

--- Replace the active stop's text with `value` (used by the choice menu).
---@param value string
function M.set_choice(value)
    local sess = M.active()
    if not sess then
        return
    end
    local stop = sess.stops[sess.current]
    if not stop then
        return
    end
    set_mark_text(sess.buf, stop.marks[1], value)
    sync(sess)
    apply_transforms(sess)
end

--- Expand `body` at the cursor and start a session when it has stops worth tracking.
---
--- A body whose only stop is the implicit `$0` needs no session — the text is inserted, the cursor
--- goes to the exit position, and nothing has to be tracked. Starting one anyway would leave a live
--- TextChangedI hook on the buffer for a plain text snippet.
---@param body string
---@param opts? { ctx?: table }
function M.expand(body, opts)
    opts = opts or {}
    local buf = api.nvim_get_current_buf()
    teardown(buf) -- one session per buffer; a new expansion replaces any previous

    local nodes = parser.parse(body)
    local ctx = variables.context(opts.ctx)
    local text, ranges = render(nodes, ctx)
    local lines = to_lines(text)

    -- Insert at the cursor, re-indenting continuation lines to the current indent (a snippet body is
    -- written flush-left; without this every line after the first lands at column 0).
    local win = api.nvim_get_current_win()
    local row, col = unpack(api.nvim_win_get_cursor(win))
    row = row - 1
    local indent = api.nvim_get_current_line():match("^%s*") or ""
    for i = 2, #lines do
        lines[i] = indent .. lines[i]
    end
    api.nvim_buf_set_text(buf, row, col, row, col, lines)

    -- Byte offsets from `render` are relative to the rendered text; translate them into buffer
    -- positions, accounting for the insertion point and the indent added to continuation lines.
    local function buf_pos(off)
        local r, c = pos_of(to_lines(text), off)
        if r == 0 then
            return row, col + c
        end
        return row + r, #indent + c
    end

    -- One extmark pair per range, so Neovim moves them for us as the text changes.
    local by_index = {}
    for _, rg in ipairs(ranges) do
        local sr, sc = buf_pos(rg.from)
        local er, ec = buf_pos(rg.to)
        local m1 = api.nvim_buf_set_extmark(buf, NS, sr, sc, { right_gravity = false })
        local m2 = api.nvim_buf_set_extmark(buf, NS, er, ec, { right_gravity = true })
        local e = by_index[rg.index]
        if not e then
            e = { index = rg.index, marks = {}, transforms = {}, choice = rg.choice }
            by_index[rg.index] = e
        end
        if rg.transform then
            e.transforms[#e.transforms + 1] = { node = rg.transform, pair = { m1, m2 } }
        else
            e.marks[#e.marks + 1] = { m1, m2 }
            e.choice = e.choice or rg.choice
        end
    end

    local order = parser.stops(nodes)
    local stops = {}
    for _, idx in ipairs(order) do
        local e = by_index[idx]
        if e and #e.marks > 0 then
            stops[#stops + 1] = e
        end
    end

    -- Nothing to track: place the cursor at the exit stop and stay out of the way.
    if #stops <= 1 then
        local only = stops[1]
        if only then
            local sr, sc = mark_range(buf, only.marks[1])
            if sr then
                api.nvim_win_set_cursor(win, { sr + 1, sc })
            end
        end
        pcall(api.nvim_buf_clear_namespace, buf, NS, 0, -1)
        return
    end

    local sess = {
        buf = buf,
        stops = stops,
        current = 0,
        augroup = api.nvim_create_augroup("LvimSnippetsSession" .. buf, { clear = true }),
    }
    sessions[buf] = sess

    api.nvim_create_autocmd({ "TextChangedI", "TextChangedP" }, {
        group = sess.augroup,
        buffer = buf,
        callback = function()
            if sessions[buf] then
                sync(sess)
                apply_transforms(sess)
            end
        end,
    })
    -- A session belongs to its buffer: unloading it, or leaving insert mode at the exit stop, ends it.
    api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
        group = sess.augroup,
        buffer = buf,
        callback = function()
            teardown(buf)
        end,
    })

    goto_stop(sess, 1)
end

return M
