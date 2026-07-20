-- lvim-snippets.luasnip_shim: run a LuaSnip-style `.lua` collection WITHOUT LuaSnip.
--
-- A `.lua` snippet file is Lua code that calls LuaSnip's node builders:
--
--     local ls = require("luasnip")
--     return { ls.s("trig", { ls.t("text"), ls.i(1, "arg"), ls.i(0) }) }
--
-- The plugin used to load these by requiring LuaSnip and handing the resulting objects back to it to
-- expand — which is why LuaSnip was a dependency for this one format. That is not support, it is
-- delegation: nothing in this plugin understood the file.
--
-- This module makes the file's own API available instead. It provides the node builders as pure data
-- constructors, runs the collection in a sandbox whose `require("luasnip")` resolves HERE, and then
-- flattens the returned snippets into ordinary LSP snippet bodies — the same `${1:arg}` strings every
-- other format produces, which the plugin's session engine already expands in full.
--
-- What translates, and what cannot:
--
--   t, i, s          text, insert nodes, snippets            -> tabstops and literal text
--   c                choice node                             -> ${n|a,b,c|}
--   f                function node                           -> evaluated ONCE at load, against the
--                                                              trigger's captures (the common case:
--                                                              a postfix rule reading `captures[1]`)
--   d, sn, r         dynamic / snippet / restore nodes       -> their static text where derivable,
--                                                              else skipped, and the file is reported
--                                                              in :checkhealth rather than half-working
--
-- A `regTrig` snippet becomes a POSTFIX RULE (config.postfix), because that is exactly what it is: a
-- pattern trigger whose captures feed the body.
--
---@module "lvim-snippets.luasnip_shim"

local M = {}

-- ── node constructors ─────────────────────────────────────────────────────────────────────────────
-- Each returns a plain table tagged with its kind; nothing is evaluated here, so a collection file
-- can be loaded without any of the surrounding machinery being live.

---@param text string|string[]
---@return table
local function t(text)
    return { kind = "text", text = type(text) == "table" and table.concat(text, "\n") or tostring(text) }
end

---@param pos integer
---@param default? string|string[]
---@return table
local function i(pos, default)
    return {
        kind = "insert",
        pos = pos,
        default = type(default) == "table" and table.concat(default, "\n") or default,
    }
end

---@param fn fun(args: table, parent: table): string|string[]
---@return table
local function f(fn)
    return { kind = "func", fn = fn }
end

---@param pos integer
---@param choices table[]
---@return table
local function c(pos, choices)
    return { kind = "choice", pos = pos, choices = choices or {} }
end

---@param nodes table[]
---@return table
local function sn(_, nodes)
    return { kind = "snippet_node", nodes = nodes or {} }
end

---@param pos integer
---@return table
local function d(pos)
    return { kind = "dynamic", pos = pos }
end

--- `ls.s(trigger, nodes, opts)` — a snippet. `trigger` may be a string or the option table form
--- (`{ trig = …, regTrig = true, snippetType = "autosnippet" }`).
---@param trigger string|table
---@param nodes table|table[]
---@param opts? table
---@return table
local function s(trigger, nodes, opts)
    local spec = type(trigger) == "table" and trigger or { trig = trigger }
    return {
        kind = "snippet",
        trig = spec.trig,
        regTrig = spec.regTrig == true,
        auto = spec.snippetType == "autosnippet",
        wordTrig = spec.wordTrig,
        nodes = type(nodes) == "table" and (nodes.kind and { nodes } or nodes) or {},
        desc = (opts and (opts.desc or opts.dscr)) or spec.desc or spec.dscr,
    }
end

--- The table a collection sees as `require("luasnip")`.
--- Only the surface a snippet file touches is provided; anything else is nil, and calling it raises
--- inside the pcall that loads the file, so the file is reported broken instead of failing silently.
---@type table
M.api = {
    s = s,
    snippet = s,
    t = t,
    text_node = t,
    i = i,
    insert_node = i,
    f = f,
    function_node = f,
    c = c,
    choice_node = c,
    sn = sn,
    snippet_node = sn,
    d = d,
    dynamic_node = d,
    -- `r`/`rep` (restore/repeat) map to a mirror of the referenced stop.
    r = function(pos)
        return { kind = "mirror", pos = pos }
    end,
    rep = function(pos)
        return { kind = "mirror", pos = pos }
    end,
    parser = {
        parse_snippet = function(trig, body)
            return { kind = "snippet", trig = trig, nodes = { t(body) } }
        end,
    },
    -- Collections commonly call these at load time; they are no-ops here.
    add_snippets = function() end,
    setup = function() end,
    filetype_extend = function() end,
}

-- ── flattening ────────────────────────────────────────────────────────────────────────────────────

--- Escape text so it survives being placed in an LSP snippet body.
---@param str string
---@return string
local function esc(str)
    return (tostring(str):gsub("([%$}\\])", "\\%1"))
end

--- Turn a node list into an LSP snippet body.
---@param nodes table[]
---@param caps string[]  the trigger's captures, for function nodes
---@return string body, boolean complete  `complete` is false when a node could not be translated
local function flatten(nodes, caps)
    local out, complete = {}, true
    for _, n in ipairs(nodes or {}) do
        if type(n) ~= "table" then
            complete = false
        elseif n.kind == "text" then
            out[#out + 1] = esc(n.text)
        elseif n.kind == "insert" then
            if n.default and n.default ~= "" then
                out[#out + 1] = ("${%d:%s}"):format(n.pos, esc(n.default))
            else
                out[#out + 1] = ("$%d"):format(n.pos)
            end
        elseif n.kind == "mirror" then
            out[#out + 1] = ("$%d"):format(n.pos)
        elseif n.kind == "choice" then
            local items = {}
            for _, ch in ipairs(n.choices) do
                -- Choice options are usually text nodes; anything else has no textual form.
                if type(ch) == "table" and ch.kind == "text" then
                    items[#items + 1] = (ch.text:gsub("[,|]", "\\%0"))
                else
                    complete = false
                end
            end
            if #items > 0 then
                out[#out + 1] = ("${%d|%s|}"):format(n.pos, table.concat(items, ","))
            end
        elseif n.kind == "func" then
            -- A function node is evaluated ONCE, here, with the trigger's captures in the shape
            -- LuaSnip passes them (`parent.captures`). That covers the postfix idiom — reading a
            -- capture and returning text — which is what these nodes are almost always for. A
            -- function reading OTHER STOPS' live text cannot work this way and is reported.
            local ok, res = pcall(n.fn, {}, { captures = caps or {} })
            if ok and res ~= nil then
                out[#out + 1] = esc(type(res) == "table" and table.concat(res, "\n") or tostring(res))
            else
                complete = false
            end
        elseif n.kind == "snippet_node" then
            local body, ok = flatten(n.nodes, caps)
            out[#out + 1] = body
            complete = complete and ok
        elseif n.kind == "dynamic" then
            -- A dynamic node rebuilds itself from another stop's live text as you type; there is no
            -- static form. Left as a plain tabstop so the snippet still expands and jumps.
            out[#out + 1] = ("$%d"):format(n.pos or 1)
            complete = false
        else
            complete = false
        end
    end
    return table.concat(out), complete
end

--- Load a `.lua` snippet collection without LuaSnip.
---
--- The file is run with its `require("luasnip")` pointing at `M.api`, so it builds plain tables. The
--- result is split into ordinary records and postfix rules — a `regTrig` snippet IS a postfix rule.
---@param path string
---@return table[]? snippets, table[]? postfix, string? err
function M.load(path)
    local chunk, err = loadfile(path)
    if not chunk then
        return nil, nil, err
    end

    -- Sandbox `require` so the collection resolves "luasnip" to this shim while everything else it
    -- may legitimately need (vim, string helpers) still works.
    local env = setmetatable({
        require = function(name)
            if name == "luasnip" or name:match("^luasnip%.") then
                return M.api
            end
            return require(name)
        end,
    }, { __index = _G })
    if setfenv then
        setfenv(chunk, env) -- LuaJIT
    else
        chunk = load(string.dump(chunk), "@" .. path, "b", env) or chunk
    end

    local ok, res = pcall(chunk)
    if not ok or type(res) ~= "table" then
        return nil, nil, tostring(res)
    end

    local snippets, postfix = {}, {}
    for _, sp in ipairs(res) do
        if type(sp) == "table" and sp.kind == "snippet" and type(sp.trig) == "string" then
            if sp.regTrig then
                -- A regex trigger becomes a postfix rule: the body is produced per match, since its
                -- function nodes read the captures of THAT match.
                postfix[#postfix + 1] = {
                    trigger = sp.trig,
                    desc = sp.desc,
                    body = function(caps)
                        local body = flatten(sp.nodes, caps)
                        return body
                    end,
                }
            else
                local body, complete = flatten(sp.nodes, {})
                snippets[#snippets + 1] = {
                    prefix = sp.trig,
                    body = body,
                    description = sp.desc,
                    complete = complete,
                }
            end
        end
    end
    return snippets, postfix, nil
end

return M
