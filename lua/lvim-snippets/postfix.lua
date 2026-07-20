-- lvim-snippets.postfix: REGEX-triggered snippets that fire as you type.
--
-- The last thing a `.lua` (LuaSnip) collection was needed for. A postfix rule is a snippet whose
-- trigger is a PATTERN rather than a word, and whose body can use what the pattern captured:
--
--     { trigger = "([%w_]+)%.par", body = "($1)$0" }        foo.par  ->  (foo)
--     { trigger = "(.+)%.r",       body = "return $1$0" }   x + 1.r  ->  return x + 1
--
-- Two things make this different from an ordinary snippet, and both are why it could not be expressed
-- in VS Code JSON or SnipMate:
--
--   * the trigger is a Lua pattern, and its captures are addressable as `$1`, `$2`… in the body;
--   * it AUTO-EXPANDS — there is no completion menu and no accept keystroke, the rule fires the
--     moment the typed text matches, which is the whole point of a postfix operator.
--
-- Rules are matched against the text BEFORE the cursor on the current line, longest trigger first, so
-- a specific rule (`([%w_]+)%.par`) is not shadowed by a looser one (`(.+)%.r`).
--
-- `body` may also be a FUNCTION receiving the captures and returning the body string, for the rare
-- case that needs real logic rather than substitution — the escape hatch that keeps this at parity
-- with what a LuaSnip function node could do.
--
---@module "lvim-snippets.postfix"

local config = require("lvim-snippets.config")

local api = vim.api
local M = {}

---@class LvimSnippetsPostfixRule
---@field trigger string                            a Lua pattern matched against the text before the cursor
---@field body string|fun(caps: string[]): string   the snippet body; `$1`… are the trigger's captures
---@field desc? string                              shown in :checkhealth and the picker
---@field ft? string|string[]                       filetypes this rule applies to (default: all)

---@type integer?  the augroup, when watching is installed
local augroup = nil

--- Does `rule` apply to filetype `ft`?
---@param rule LvimSnippetsPostfixRule
---@param ft string
---@return boolean
local function applies(rule, ft)
    if not rule.ft then
        return true
    end
    ---@type string[]
    local list = type(rule.ft) == "table" and rule.ft or { rule.ft }
    for _, f in ipairs(list) do
        if f == ft or f == "all" then
            return true
        end
    end
    return false
end

--- Substitute `$1`, `$2`… (and `${1}` …) in a body with the trigger's captures.
--- Tabstops the rule declares itself (`$0`, or any index beyond the capture count) are left alone, so
--- a postfix body can still place the cursor.
---@param body string
---@param caps string[]
---@return string
local function substitute(body, caps)
    local function sub(n)
        local v = caps[tonumber(n)]
        -- Only capture indices are substituted; `$0` and out-of-range indices stay as tabstops for
        -- the session to pick up. Escaping the result matters: a capture containing `$` or `}` would
        -- otherwise be re-parsed as snippet syntax.
        if v == nil then
            return nil
        end
        return (v:gsub("([%$}\\])", "\\%1"))
    end
    local out = body:gsub("%${(%d+)}", function(n)
        return sub(n) or ("${" .. n .. "}")
    end)
    out = out:gsub("%$(%d+)", function(n)
        return sub(n) or ("$" .. n)
    end)
    return out
end

--- The rule matching the text before the cursor, if any.
--- Anchored to the END of the line prefix (`pattern .. "$"`), so a rule fires on what was just typed
--- rather than on something further back.
---@param prefix string  the text before the cursor
---@param ft string
---@return LvimSnippetsPostfixRule? rule, integer? from, string[]? caps
function M.match(prefix, ft)
    local rules = config.postfix and config.postfix.rules or {}
    local best, best_from, best_caps, best_len = nil, nil, nil, -1
    for _, rule in ipairs(rules) do
        if type(rule.trigger) == "string" and applies(rule, ft) then
            local ok, res = pcall(function()
                return { prefix:find("(" .. rule.trigger .. ")$") }
            end)
            if ok and res[1] then
                local from, _, whole = res[1], res[2], res[3]
                local caps = { unpack(res, 4) }
                -- `find` returns the whole match as the first capture (we wrapped the pattern), then
                -- the rule's own captures. A rule with no captures of its own gets the match itself.
                if #caps == 0 then
                    caps = { whole }
                end
                -- Longest trigger wins, so a specific rule is never shadowed by a looser one.
                if #rule.trigger > best_len then
                    best, best_from, best_caps, best_len = rule, from, caps, #rule.trigger
                end
            end
        end
    end
    return best, best_from, best_caps
end

--- Try to expand a postfix rule at the cursor. Returns true when one fired.
---@return boolean
function M.try_expand()
    if not (config.postfix and config.postfix.enabled) then
        return false
    end
    local win = api.nvim_get_current_win()
    local row, col = unpack(api.nvim_win_get_cursor(win))
    local line = api.nvim_get_current_line()
    local prefix = line:sub(1, col)
    local rule, from, caps = M.match(prefix, vim.bo.filetype)
    if not rule then
        return false
    end

    local body = rule.body
    if type(body) == "function" then
        local ok, res = pcall(body, caps)
        if not ok or type(res) ~= "string" then
            return false
        end
        body = res
    else
        body = substitute(body, caps or {})
    end

    -- Remove the trigger text, then expand in its place. Done in this order so the session's extmarks
    -- are created against the final text; deleting afterwards would move them.
    api.nvim_buf_set_text(0, row - 1, from - 1, row - 1, col, { "" })
    api.nvim_win_set_cursor(win, { row, from - 1 })
    require("lvim-snippets.session").expand(body)
    return true
end

--- Install the auto-expand watcher (idempotent). Rules fire on `InsertCharPre`-adjacent changes; we
--- use `TextChangedI` because the trigger's LAST character must already be in the buffer for the
--- pattern to match it.
function M.attach()
    if augroup then
        return
    end
    augroup = api.nvim_create_augroup("LvimSnippetsPostfix", { clear = true })
    -- Rules that live in a `.lua` collection are registered as that collection loads, and collections
    -- load lazily (on the first request for a filetype). Without priming, a postfix rule would not
    -- exist until something else — a completion menu, the picker — happened to pull its filetype in
    -- first, which is not a dependency a typing trigger should have.
    api.nvim_create_autocmd("FileType", {
        group = augroup,
        callback = function(args)
            pcall(function()
                require("lvim-snippets.engine").get(args.match or vim.bo.filetype)
            end)
        end,
    })
    api.nvim_create_autocmd("TextChangedI", {
        group = augroup,
        callback = function()
            -- Never fire while a session is live: the text being typed belongs to a tabstop, and a
            -- rule matching inside it would expand a snippet within a snippet.
            if require("lvim-snippets.session").active() then
                return
            end
            M.try_expand()
        end,
    })
end

--- Remove the watcher.
function M.detach()
    if augroup then
        pcall(api.nvim_del_augroup_by_id, augroup)
        augroup = nil
    end
end

return M
