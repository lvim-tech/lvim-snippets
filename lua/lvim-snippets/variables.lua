-- lvim-snippets.variables: LSP snippet VARIABLES and TRANSFORMS.
--
-- The two pieces of the grammar `vim.snippet` leaves out, and the reason a `.lua` snippet collection
-- (and therefore LuaSnip) used to be the only way to get a computed value into a snippet:
--
--   variables   $TM_FILENAME, $CURRENT_YEAR, $CLIPBOARD, $RANDOM …  — resolved at expansion
--   transforms  ${1/(.*)/${1:/upcase}/g}                            — applied as the source is typed
--
-- Both are pure functions of the buffer state and the matched text, so they live apart from the
-- session and can be exercised on their own.
--
-- The regex dialect is the spec's (JavaScript-ish). `to_vim_pattern` translates it to a VIM regex
-- rather than a Lua pattern, because Lua has no alternation and alternation is what these regexes
-- are mostly made of. It still gives up honestly (returning nil) on what Vim cannot express either —
-- `\b`, lookaround, more than nine groups — in which case the transform is skipped rather than
-- silently producing wrong text.
--
---@module "lvim-snippets.variables"

local api = vim.api
local M = {}

-- ── variables ─────────────────────────────────────────────────────────────────────────────────────

--- The context a variable resolves against: captured once per expansion so every variable in one
--- snippet sees the same instant (two `$CURRENT_SECOND`s in one body must not disagree).
---@param extra? table  caller-supplied overrides, e.g. regex captures for a postfix snippet
---@return table
function M.context(extra)
    local buf = api.nvim_get_current_buf()
    local win = api.nvim_get_current_win()
    local row, col = unpack(api.nvim_win_get_cursor(win))
    local path = api.nvim_buf_get_name(buf)
    local ctx = {
        buf = buf,
        path = path,
        row = row,
        col = col,
        line = api.nvim_get_current_line(),
        time = os.time(),
        captures = (extra and extra.captures) or {},
    }
    for k, v in pairs(extra or {}) do
        if k ~= "captures" then
            ctx[k] = v
        end
    end
    return ctx
end

---@type table<string, fun(ctx: table): string?>
local RESOLVERS = {
    -- files and paths
    TM_FILENAME = function(ctx)
        return vim.fn.fnamemodify(ctx.path, ":t")
    end,
    TM_FILENAME_BASE = function(ctx)
        return vim.fn.fnamemodify(ctx.path, ":t:r")
    end,
    TM_DIRECTORY = function(ctx)
        return vim.fn.fnamemodify(ctx.path, ":h")
    end,
    TM_FILEPATH = function(ctx)
        return ctx.path
    end,
    RELATIVE_FILEPATH = function(ctx)
        return vim.fn.fnamemodify(ctx.path, ":.")
    end,
    WORKSPACE_FOLDER = function()
        return vim.uv.cwd()
    end,
    WORKSPACE_NAME = function()
        return vim.fn.fnamemodify(vim.uv.cwd() or "", ":t")
    end,

    -- buffer content
    TM_LINE_INDEX = function(ctx)
        return tostring(ctx.row - 1)
    end,
    TM_LINE_NUMBER = function(ctx)
        return tostring(ctx.row)
    end,
    TM_CURRENT_LINE = function(ctx)
        return ctx.line
    end,
    TM_CURRENT_WORD = function(ctx)
        return ctx.line:sub(1, ctx.col):match("[%w_]+$") or ""
    end,
    TM_SELECTED_TEXT = function(ctx)
        return ctx.selected or ""
    end,
    CLIPBOARD = function()
        return vim.fn.getreg("+")
    end,

    -- comments, from the buffer's commentstring
    LINE_COMMENT = function()
        local cs = (vim.bo.commentstring or "%s"):gsub("%s*%%s.*$", "")
        return cs
    end,

    -- dates and times — the whole reason a computed value used to need LuaSnip
    CURRENT_YEAR = function(ctx)
        return tostring(os.date("%Y", ctx.time))
    end,
    CURRENT_YEAR_SHORT = function(ctx)
        return tostring(os.date("%y", ctx.time))
    end,
    CURRENT_MONTH = function(ctx)
        return tostring(os.date("%m", ctx.time))
    end,
    CURRENT_MONTH_NAME = function(ctx)
        return tostring(os.date("%B", ctx.time))
    end,
    CURRENT_MONTH_NAME_SHORT = function(ctx)
        return tostring(os.date("%b", ctx.time))
    end,
    CURRENT_DATE = function(ctx)
        return tostring(os.date("%d", ctx.time))
    end,
    CURRENT_DAY_NAME = function(ctx)
        return tostring(os.date("%A", ctx.time))
    end,
    CURRENT_DAY_NAME_SHORT = function(ctx)
        return tostring(os.date("%a", ctx.time))
    end,
    CURRENT_HOUR = function(ctx)
        return tostring(os.date("%H", ctx.time))
    end,
    CURRENT_MINUTE = function(ctx)
        return tostring(os.date("%M", ctx.time))
    end,
    CURRENT_SECOND = function(ctx)
        return tostring(os.date("%S", ctx.time))
    end,
    CURRENT_SECONDS_UNIX = function(ctx)
        return tostring(ctx.time)
    end,
    CURRENT_TIMEZONE_OFFSET = function(ctx)
        return tostring(os.date("%z", ctx.time))
    end,

    -- randomness
    RANDOM = function()
        return ("%06d"):format(math.random(0, 999999))
    end,
    RANDOM_HEX = function()
        return ("%06x"):format(math.random(0, 0xFFFFFF))
    end,
    UUID = function()
        -- v4, from Lua's PRNG: good enough for a scaffolded identifier, not for cryptography.
        local t = {}
        for i = 1, 32 do
            t[i] = ("%x"):format(i == 13 and 4 or math.random(0, 15))
        end
        return table.concat(t, "", 1, 8)
            .. "-"
            .. table.concat(t, "", 9, 12)
            .. "-"
            .. table.concat(t, "", 13, 16)
            .. "-"
            .. table.concat(t, "", 17, 20)
            .. "-"
            .. table.concat(t, "", 21, 32)
    end,
}

--- Resolve a variable name against `ctx`, or nil when it is unknown/empty.
--- A numeric name (`$1` inside a transform replacement) reads a regex capture instead.
---@param name string
---@param ctx table
---@return string?
function M.resolve(name, ctx)
    local n = tonumber(name)
    if n then
        return ctx.captures and ctx.captures[n] or nil
    end
    local fn = RESOLVERS[name]
    if not fn then
        return nil
    end
    local ok, v = pcall(fn, ctx)
    if not ok or v == nil then
        return nil
    end
    return tostring(v)
end

-- ── transforms ────────────────────────────────────────────────────────────────────────────────────

--- Translate a JavaScript-flavoured snippet regex into a VIM regex.
---
--- Vim's own engine is the target rather than Lua patterns, because Lua has no ALTERNATION — and
--- alternation is what snippet transforms are mostly made of. Measured against the installed
--- collections, 13 of the 18 distinct transform regexes use `|`; the idiom is `(T)|.*`, "match this
--- or match anything", which is how a transform expresses a conditional replacement. A Lua-pattern
--- translator can only reject those, and a rejected transform passes its input through unchanged, so
--- the raw source text lands where the snippet meant a computed or empty value.
---
--- The translation targets Vim's "very magic" mode (`\v`), where the syntax is very nearly
--- JavaScript's already: `(` groups, `|` alternates, `+`/`?`/`{n,m}` quantify, `\d`/`\w`/`\s` hold.
--- What differs is handled explicitly below.
---@param re string
---@return string? pattern, integer? groups  nil when a construct has no Vim equivalent
function M.to_vim_pattern(re)
    -- `\C` forces case-sensitivity: Vim's match functions otherwise honour the user's 'ignorecase',
    -- which would silently change what a snippet's transform matches.
    local out, groups, i, in_class = { "\\C\\v" }, 0, 1, false
    while i <= #re do
        local c = re:sub(i, i)
        local nxt = re:sub(i + 1, i + 1)
        if in_class then
            -- Inside `[...]` the very-magic rules do not apply; pass through until it closes.
            out[#out + 1] = c
            if c == "\\" then
                out[#out + 1] = nxt
                i = i + 1
            elseif c == "]" then
                in_class = false
            end
            i = i + 1
        elseif c == "[" then
            in_class = true
            out[#out + 1] = c
            i = i + 1
        elseif c == "\\" then
            if nxt == "b" then
                return nil -- word boundary: JS's `\b` has no single very-magic equivalent
            end
            -- The character classes and control escapes carry over unchanged; anything else is an
            -- escaped literal and stays escaped.
            out[#out + 1] = "\\" .. nxt
            i = i + 2
        elseif c == "(" and re:sub(i + 1, i + 2) == "?:" then
            out[#out + 1] = "%(" -- non-capturing group
            i = i + 3
        elseif c == "(" and nxt == "?" then
            return nil -- lookahead / lookbehind
        elseif c == "(" then
            groups = groups + 1
            out[#out + 1] = c
            i = i + 1
        elseif (c == "*" or c == "+") and nxt == "?" then
            out[#out + 1] = (c == "*") and "{-}" or "{-1,}" -- non-greedy
            i = i + 2
        elseif c:match("[=@%%&<>~]") then
            -- Literal in JS, special in very magic: escape so it matches itself.
            out[#out + 1] = "\\" .. c
            i = i + 1
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    -- Vim caps captures at 9; a pattern needing more cannot be represented.
    if groups > 9 then
        return nil
    end
    return table.concat(out), groups
end

--- Apply a case modifier from a transform replacement.
---@param s string
---@param modifier string?
---@return string
local function apply_case(s, modifier)
    if not modifier or s == "" then
        return s
    end
    if modifier == "upcase" then
        return s:upper()
    elseif modifier == "downcase" then
        return s:lower()
    elseif modifier == "capitalize" then
        return s:sub(1, 1):upper() .. s:sub(2)
    elseif modifier == "pascalcase" then
        return (s:gsub("[-_%s]+(%w)", string.upper):gsub("^%l", string.upper))
    elseif modifier == "camelcase" then
        return (s:gsub("[-_%s]+(%w)", string.upper):gsub("^%u", string.lower))
    end
    return s
end

--- Build the replacement text for one match.
---@param replacement string   the replacement template, e.g. "${1:/upcase}-$2"
---@param caps string[]        the captures of this match
---@return string
local function expand_replacement(replacement, caps)
    local out = replacement
    local function got(n)
        local v = caps[tonumber(n)]
        return v ~= nil and v ~= ""
    end
    -- ${n:/modifier} — a capture with a case modifier
    out = out:gsub("%${(%d+):/(%a+)}", function(n, mod)
        return apply_case(caps[tonumber(n)] or "", mod)
    end)
    -- ${n:?if:else} — ternary on whether the group matched
    out = out:gsub("%${(%d+):%?([^:}]*):([^}]*)}", function(n, yes, no)
        return got(n) and yes or no
    end)
    -- ${n:+text} — insert `text` ONLY when the group matched. The conditional form alternation makes
    -- possible: `(a)|(b)` sets exactly one group, and `${2:+_}` turns that into a separator.
    out = out:gsub("%${(%d+):%+([^}]*)}", function(n, yes)
        return got(n) and yes or ""
    end)
    -- ${n:-default} and ${n:default} — a fallback when the group did not match
    out = out:gsub("%${(%d+):%-([^}]*)}", function(n, dflt)
        return got(n) and caps[tonumber(n)] or dflt
    end)
    out = out:gsub("%${(%d+):([^}]*)}", function(n, dflt)
        return got(n) and caps[tonumber(n)] or dflt
    end)
    -- ${n} and $n — a plain capture
    out = out:gsub("%${(%d+)}", function(n)
        return caps[tonumber(n)] or ""
    end)
    out = out:gsub("%$(%d+)", function(n)
        return caps[tonumber(n)] or ""
    end)
    return out
end

--- Apply a transform node to `input`.
--- Returns the transformed text, or the input unchanged when the pattern cannot be translated.
---@param input string
---@param node LvimSnippetsNode  a `transform` node
---@return string
function M.transform(input, node)
    local pat, groups = M.to_vim_pattern(node.regex or "")
    if not pat or not groups then
        return input
    end
    local flags = node.flags or ""
    if flags:find("i") then
        pat = pat:gsub("^\\C", "\\c", 1)
    end
    local global = flags:find("g") ~= nil

    -- Walked by hand rather than handed to `substitute()`: the replacement is the SNIPPET's template
    -- language (`${1:/upcase}`, `${2:+_}`), not Vim's, so each match's captures have to come back to
    -- Lua to be expanded.
    local out, pos = {}, 0
    while pos <= #input do
        local ok, from = pcall(vim.fn.match, input, pat, pos)
        if not ok or from < 0 then
            break
        end
        local to = vim.fn.matchend(input, pat, pos)
        local list = vim.fn.matchlist(input, pat, pos)
        local caps = {}
        if groups > 0 then
            for g = 1, groups do
                caps[g] = list[g + 1] or ""
            end
        else
            -- A pattern with no captures yields the whole match; treat it as capture 1 so `${1}` in
            -- the replacement means "what matched", as the spec expects.
            caps[1] = list[1] or ""
        end

        out[#out + 1] = input:sub(pos + 1, from)
        out[#out + 1] = expand_replacement(node.replacement or "", caps)
        if to > from then
            pos = to
        else
            -- An empty match — `(T)|.*` matches nothing at the end of the input — would otherwise
            -- spin here forever. Carry the character across and step over it.
            out[#out + 1] = input:sub(to + 1, to + 1)
            pos = to + 1
        end
        if not global then
            break
        end
    end
    out[#out + 1] = input:sub(pos + 1)
    return table.concat(out)
end

return M
