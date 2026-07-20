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
---@field initial? string               the text this stop rendered as (to tell a rewrite from an edit)
---@field nested_in? table<integer, boolean>  indices of the stops this one sits INSIDE

---@class LvimSnippetsSession
---@field buf integer
---@field stops LvimSnippetsStop[]      in jump order (ascending, 0 last)
---@field current integer               index into `stops`
---@field augroup integer
---@field entered? boolean          has the cursor been inside the snippet yet (see the CursorMoved teardown)

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

    -- The stack of placeholder indices we are currently INSIDE. Nesting cannot be recovered from the
    -- rendered spans afterwards: `${1:${2:inner}}` gives both stops the exact same range, so a
    -- containment test sees no parent at all. The tree knows, so it is recorded while walking it.
    local stack = {}

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
                if n.name then
                    -- A transform on a VARIABLE (`${TM_FILENAME/(.*)/${1:/upcase}/}`) has no tabstop
                    -- behind it — its input is fixed the moment the snippet expands, so it is applied
                    -- here and emitted as plain text. Treating it like a tabstop transform was a
                    -- crash: the range carried `index = nil`, which is not a usable table key.
                    emit(variables.transform(variables.resolve(n.name, ctx) or "", n))
                elseif n.index then
                    -- Rendered empty; the value arrives when its source stop is edited.
                    ranges[#ranges + 1] = { index = n.index, from = len, to = len, transform = n }
                end
            elseif n.type == "tabstop" or n.type == "placeholder" or n.type == "choice" then
                local from = len
                -- Where this node's own output starts in `out`, so the mirror seed below can be
                -- concatenated from here rather than from the whole buffer of emitted pieces.
                local mark = #out
                local enclosing = nil
                if #stack > 0 then
                    enclosing = {}
                    for _, idx in ipairs(stack) do
                        enclosing[idx] = true
                    end
                end
                if n.type == "placeholder" and n.children then
                    stack[#stack + 1] = n.index
                    walk(n.children)
                    stack[#stack] = nil
                    -- Remember what this index renders as, so a bare `$1` MIRROR of it starts out
                    -- showing the same text. Without this the mirror renders empty and only catches
                    -- up on the first keystroke — `local ${1:name} = require("$1")` expanded to
                    -- `require("")`, which reads as a bug even though typing would fix it.
                    seed[n.index] = table.concat(out, "", mark + 1)
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
                    nested_in = enclosing,
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
    -- Everything below is fed as ONE key sequence rather than driven with `nvim_win_set_cursor` and
    -- `:normal!`. Both of those are undone here: a Lua callback that runs while the editor is in
    -- insert mode has its mode changes REVERTED when it returns (the editor's real state wins), and
    -- `:stopinsert` is documented as leaving insert "as soon as possible" — i.e. after this function,
    -- straight into the selection it just built. Measuring inside the function showed correct columns
    -- every time; the damage happened after it returned, which is why the placeholder came back a
    -- character wide or a character short. Queued keys are executed by the main loop in order, so the
    -- mode they end in is the mode that sticks.
    --
    -- Motions count CHARACTERS, so the byte columns the extmarks carry are converted first — `l`
    -- moves by character, and for anything multi-byte the two disagree.
    local lines = api.nvim_buf_get_lines(sess.buf, sr, er + 1, false)
    local function chars_before(text, byte_col)
        return vim.fn.strchars(string.sub(text or "", 1, byte_col))
    end
    local start_col = chars_before(lines[1], sc)

    local keys = { "\28\14" } -- <C-\><C-n>: leave whatever mode we are in

    --- Move to (`line1`, `col_chars`), and report whether that column was actually REACHABLE.
    ---
    --- Positioning by motion has to respect what normal mode can reach: the column one past the last
    --- character does not exist there. `l` does not simply stop at the end — with `l` in 'whichwrap'
    --- (which this config and many others set) it wraps to the NEXT LINE, which silently moved every
    --- stop sitting at end-of-line, `$0` above all. `$` names the last character exactly and is
    --- immune to both 'whichwrap' and 'virtualedit'.
    ---@param line1 integer     1-based line
    ---@param col_chars integer target column, in CHARACTERS
    ---@param text string?      that line's text, to know how far it reaches
    ---@return boolean exact    false when the cursor stopped ON the last character instead
    local function go(line1, col_chars, text)
        keys[#keys + 1] = tostring(line1) .. "G"
        if col_chars <= 0 then
            keys[#keys + 1] = "0"
            return true
        end
        if col_chars >= vim.fn.strchars(text or "") then
            keys[#keys + 1] = "$"
            return false
        end
        keys[#keys + 1] = "0" .. tostring(col_chars) .. "l"
        return true
    end

    local exact = go(sr + 1, start_col, lines[1])

    if sr == er and sc == ec then
        -- Empty stop: nothing to select, just land there and insert. `i` inserts BEFORE the cursor
        -- and `a` AFTER it — and "after the last character" is precisely the position `go` could not
        -- reach, so the unreachable case is not an approximation, it is the same point named the
        -- other way round.
        keys[#keys + 1] = exact and "i" or "a"
    else
        keys[#keys + 1] = "v"
        -- Where the cursor has to sit for the selection to cover the range depends on 'selection':
        -- the default (inclusive) takes the character under the cursor, so the cursor goes on the
        -- LAST character; with `exclusive` it does not, so the cursor goes one PAST it. Getting this
        -- wrong drops or keeps one character of every placeholder.
        local end_line = lines[er - sr + 1]
        local end_col = chars_before(end_line, ec)
        if vim.o.selection ~= "exclusive" then
            end_col = math.max(end_col - 1, 0)
        end
        go(er + 1, end_col, end_line)
        keys[#keys + 1] = "\7" -- Ctrl-G: visual -> select, so typing REPLACES the placeholder
    end

    api.nvim_feedkeys(table.concat(keys), "n", false)
end

--- Has `stop` been swallowed by a rewrite of a stop it sits inside?
---
--- `${1:${2:inner}}` puts two stops over the same text. Replacing the outer one removes the inner
--- one's content wholesale, so the inner stop no longer refers to anything the user wrote — every
--- editor drops it from the jump order at that point rather than selecting the remains of its range.
---@param sess LvimSnippetsSession
---@param stop LvimSnippetsStop
---@return boolean
local function dropped(sess, stop)
    if not stop.nested_in then
        return false
    end
    for _, other in ipairs(sess.stops) do
        if stop.nested_in[other.index] and mark_text(sess.buf, other.marks[1]) ~= other.initial then
            return true
        end
    end
    return false
end

--- The index of the stop `direction` away from the active one, skipping dropped stops, or nil when
--- there is none left that way.
---@param sess LvimSnippetsSession
---@param direction integer
---@return integer?
local function next_stop(sess, direction)
    local n = sess.current + direction
    while sess.stops[n] and dropped(sess, sess.stops[n]) do
        n = n + direction
    end
    if n < 1 or n > #sess.stops then
        return nil
    end
    return n
end

--- Is a session active for the current buffer, and can it move `direction`?
---
--- Asked by the `<Tab>` keymap to decide whether to jump or fall through. It must apply the same
--- skipping `jump` does: reporting a jump that then turns out to be to a dropped stop would swallow
--- the key and do nothing.
---@param opts? { direction?: integer }
---@return boolean
function M.active_jumpable(opts)
    local sess = M.active()
    if not sess then
        return false
    end
    return next_stop(sess, (opts and opts.direction) or 1) ~= nil
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
    local n = next_stop(sess, direction or 1)
    if not n then
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

    -- Record what each stop rendered as, so a later rewrite can be told from the original text, and
    -- carry over the nesting the renderer observed. `${1:${2:inner}}` puts two stops over the same
    -- text: rewriting the outer one replaces the inner one's content wholesale, so the inner stop no
    -- longer refers to anything the user wrote and every editor drops it from the jump order there.
    for _, stop in ipairs(stops) do
        stop.initial = mark_text(buf, stop.marks[1])
    end
    for _, rg in ipairs(ranges) do
        if rg.nested_in then
            for _, stop in ipairs(stops) do
                if stop.index == rg.index then
                    stop.nested_in = stop.nested_in or {}
                    for parent in pairs(rg.nested_in) do
                        stop.nested_in[parent] = true
                    end
                end
            end
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
        entered = false,
        augroup = api.nvim_create_augroup("LvimSnippetsSession" .. buf, { clear = true }),
    }
    sessions[buf] = sess

    api.nvim_create_autocmd({ "TextChangedI", "TextChangedP" }, {
        group = sess.augroup,
        buffer = buf,
        callback = function()
            -- SCHEDULED, not inline. Replacing a selected placeholder is one operation to the user
            -- but two to the editor — delete the selection, then begin the insert — and this fires
            -- BETWEEN them. Doing anything at that moment disturbs the pending half: the placeholder
            -- came back with its last character still in the buffer, worse for multi-byte text where
            -- a whole letter survived. Deferring lets the change complete, then mirrors and
            -- transforms catch up on a settled buffer.
            vim.schedule(function()
                if sessions[buf] then
                    sync(sess)
                    apply_transforms(sess)
                end
            end)
        end,
    })
    -- A session belongs to its buffer, and unloading it ends it.
    api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
        group = sess.augroup,
        buffer = buf,
        callback = function()
            teardown(buf)
        end,
    })
    -- ...and it ends when the cursor leaves the text the snippet occupies. Without this the session
    -- outlives the snippet: `<Tab>` stays bound to "jump" for the rest of the buffer's life, and a
    -- mirror can still rewrite text the user has long since moved away from. The bound is recomputed
    -- from the live extmarks each time, so it follows the snippet as it grows.
    api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
        group = sess.augroup,
        buffer = buf,
        callback = function()
            if not sessions[buf] then
                return
            end
            local top, bot
            for _, stop in ipairs(sess.stops) do
                for _, pair in ipairs(stop.marks) do
                    local sr, _, er = mark_range(buf, pair)
                    if sr then
                        top = (top == nil or sr < top) and sr or top
                        bot = (bot == nil or er > bot) and er or bot
                    end
                end
            end
            if top == nil then
                return
            end
            -- Line granularity on purpose: an exit stop at the end of a line is legitimately one
            -- column past the last mark, and a column test would tear the session down there.
            local row = api.nvim_win_get_cursor(0)[1] - 1
            if row >= top and row <= bot then
                -- Leaving presupposes having arrived. Inserting a multi-line body leaves the cursor
                -- at the END of the inserted text — outside the region — and this autocmd fires there
                -- BEFORE the keys that jump to the first stop have been processed, which tore every
                -- multi-line snippet down the instant it expanded.
                sess.entered = true
            elseif sess.entered then
                teardown(buf)
            end
        end,
    })

    goto_stop(sess, 1)
end

return M
