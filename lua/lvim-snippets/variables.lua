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
-- The regex dialect is the spec's (JavaScript-ish), while Lua only has patterns. `to_lua_pattern`
-- translates the constructs that actually occur in snippet transforms — character classes, the
-- common quantifiers, anchors, groups — and gives up honestly on the rest (returning nil), in which
-- case the transform is skipped rather than silently producing wrong text.
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

--- Translate a JavaScript-flavoured snippet regex into a Lua pattern.
--- Returns nil when the source uses a construct Lua patterns cannot express, so the caller can skip
--- the transform rather than apply a wrong one.
---@param re string
---@return string?
function M.to_lua_pattern(re)
    -- Constructs with no Lua equivalent: alternation, non-greedy repetition, backreferences,
    -- lookaround, braced repetition. Detected up front so failure is honest.
    if re:find("[|]") or re:find("%*%?") or re:find("%+%?") or re:find("%(%?") or re:find("{%d") then
        return nil
    end
    local out, i = {}, 1
    while i <= #re do
        local c = re:sub(i, i)
        if c == "\\" then
            local nxt = re:sub(i + 1, i + 1)
            local map = { d = "%d", D = "%D", w = "%w", W = "%W", s = "%s", S = "%S" }
            if map[nxt] then
                out[#out + 1] = map[nxt]
            else
                out[#out + 1] = "%" .. nxt
            end
            i = i + 2
        elseif c == "%" then
            out[#out + 1] = "%%"
            i = i + 1
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out)
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
    -- ${n:/modifier} — a capture with a case modifier
    out = out:gsub("%${(%d+):/(%a+)}", function(n, mod)
        return apply_case(caps[tonumber(n)] or "", mod)
    end)
    -- ${n:default} — a capture with a fallback when it is empty
    out = out:gsub("%${(%d+):([^}]*)}", function(n, dflt)
        local v = caps[tonumber(n)]
        return (v and v ~= "") and v or dflt
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
    local pat = M.to_lua_pattern(node.regex or "")
    if not pat then
        return input
    end
    local global = (node.flags or ""):find("g") ~= nil
    local ok, res = pcall(function()
        local n = global and nil or 1
        return (
            input:gsub(pat, function(...)
                local caps = { ... }
                -- A pattern with no captures yields the whole match; treat it as capture 1 so
                -- `${1}` in the replacement means "what matched", as the spec expects.
                if #caps == 0 then
                    caps = { input }
                end
                return expand_replacement(node.replacement or "", caps)
            end, n)
        )
    end)
    if not ok then
        return input
    end
    return res
end

return M
