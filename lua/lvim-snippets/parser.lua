-- lvim-snippets.parser: LSP snippet syntax -> a node tree the session can render and track.
--
-- This is the front half of the plugin's own snippet engine. `vim.snippet` parses the same grammar
-- but keeps the result private and implements only part of it (no transforms, no nested placeholders,
-- no date variables), so the pieces a real session needs — where each tabstop is, which ones mirror
-- each other, what a choice offers — are not reachable. Parsing here is what makes them reachable.
--
-- Grammar (LSP 3.17 `snippet` syntax), all of it:
--
--   $1  ${1}                     tabstop
--   ${1:default}                 placeholder — `default` is itself a node list (nesting allowed)
--   ${1|one,two,three|}          choice
--   $VAR  ${VAR}  ${VAR:default} variable, with a fallback when the variable is empty
--   ${1/regex/replacement/flags} transform, applied to whatever the tabstop holds
--   \$  \}  \\  \,  \|           escapes
--
-- `$0` is the exit stop: where the cursor lands when the snippet is done. A body with no `$0` gets
-- one appended, so every snippet has a defined end.
--
-- The parser is deliberately pure — no buffer, no cursor, no side effects — so it can be tested on a
-- body string alone, which is exactly how the tricky cases (nesting, escapes, transforms) get proven.
--
---@module "lvim-snippets.parser"

local M = {}

---@class LvimSnippetsNode
---@field type "text"|"tabstop"|"placeholder"|"choice"|"variable"|"transform"
---@field text? string                 text nodes: the literal text
---@field index? integer               tabstop / placeholder / choice / transform: the stop number
---@field children? LvimSnippetsNode[] placeholder: the default value, itself parsed
---@field items? string[]              choice: the options, in order
---@field name? string                 variable: its name
---@field regex? string                transform: the pattern
---@field replacement? string          transform: the replacement template
---@field flags? string                transform: the regex flags

-- ── scanner ───────────────────────────────────────────────────────────────────────────────────────

---@class LvimSnippetsScanner
---@field s string
---@field i integer

---@param sc LvimSnippetsScanner
---@return string?
local function peek(sc)
    return sc.s:sub(sc.i, sc.i)
end

---@param sc LvimSnippetsScanner
---@return string?
local function take(sc)
    local c = sc.s:sub(sc.i, sc.i)
    sc.i = sc.i + 1
    return c
end

---@param sc LvimSnippetsScanner
---@param lit string
---@return boolean
local function eat(sc, lit)
    if sc.s:sub(sc.i, sc.i + #lit - 1) == lit then
        sc.i = sc.i + #lit
        return true
    end
    return false
end

--- Read an integer at the cursor, or nil when there is none.
---@param sc LvimSnippetsScanner
---@return integer?
local function read_int(sc)
    local start = sc.i
    while peek(sc):match("%d") do
        sc.i = sc.i + 1
    end
    if sc.i == start then
        return nil
    end
    return tonumber(sc.s:sub(start, sc.i - 1))
end

--- Read a variable name (`[%a_][%w_]*`) at the cursor, or nil.
---@param sc LvimSnippetsScanner
---@return string?
local function read_name(sc)
    local start = sc.i
    if not peek(sc):match("[%a_]") then
        return nil
    end
    while peek(sc):match("[%w_]") do
        sc.i = sc.i + 1
    end
    return sc.s:sub(start, sc.i - 1)
end

--- Read a transform's REPLACEMENT: raw text up to the unescaped `/` that closes it, but not one
--- nested inside a `${…}` form. The replacement may itself contain `${1:/upcase}`-style case
--- modifiers, whose `/` would otherwise end the read halfway and leave the rest as stray text.
---@param sc LvimSnippetsScanner
---@return string
local function read_replacement(sc)
    local out, depth = {}, 0
    while sc.i <= #sc.s do
        local c = peek(sc)
        if c == "\\" then
            sc.i = sc.i + 1
            local nxt = take(sc)
            if nxt and nxt:match("[%$}\\,|/]") then
                out[#out + 1] = nxt
            else
                out[#out + 1] = "\\" .. (nxt or "")
            end
        elseif c == "$" and sc.s:sub(sc.i + 1, sc.i + 1) == "{" then
            depth = depth + 1
            out[#out + 1] = take(sc)
            out[#out + 1] = take(sc)
        elseif c == "}" and depth > 0 then
            depth = depth - 1
            out[#out + 1] = take(sc)
        elseif c == "/" and depth == 0 then
            break
        else
            out[#out + 1] = take(sc)
        end
    end
    return table.concat(out)
end

--- Read raw text up to any unescaped delimiter in `stops`, honouring backslash escapes.
--- Returns the text with escapes resolved.
---@param sc LvimSnippetsScanner
---@param stops string  a Lua character class body, e.g. "%$}"
---@return string
local function read_text(sc, stops)
    local out = {}
    while sc.i <= #sc.s do
        local c = peek(sc)
        if c == "\\" then
            sc.i = sc.i + 1
            local nxt = take(sc)
            -- Only the grammar's own metacharacters are escapable; anything else keeps the
            -- backslash, so a Lua pattern or a Windows path inside a snippet survives intact.
            if nxt and nxt:match("[%$}\\,|/]") then
                out[#out + 1] = nxt
            else
                out[#out + 1] = "\\" .. (nxt or "")
            end
        elseif c ~= "" and c:match("[" .. stops .. "]") then
            break
        else
            out[#out + 1] = take(sc)
        end
    end
    return table.concat(out)
end

-- ── parser ────────────────────────────────────────────────────────────────────────────────────────

local parse_nodes

--- Parse the inside of a `${…}` form, the scanner sitting just after the brace.
---@param sc LvimSnippetsScanner
---@return LvimSnippetsNode?
local function parse_braced(sc)
    local idx = read_int(sc)
    if idx then
        if eat(sc, "}") then
            return { type = "tabstop", index = idx }
        end
        if eat(sc, ":") then
            -- ${1:default} — the default is a node list, so `${1:${2:inner}}` nests correctly.
            local children = parse_nodes(sc, "}")
            eat(sc, "}")
            return { type = "placeholder", index = idx, children = children }
        end
        if eat(sc, "|") then
            local items, cur = {}, {}
            while sc.i <= #sc.s do
                local c = peek(sc)
                if c == "\\" then
                    sc.i = sc.i + 1
                    cur[#cur + 1] = take(sc)
                elseif c == "," then
                    sc.i = sc.i + 1
                    items[#items + 1] = table.concat(cur)
                    cur = {}
                elseif c == "|" then
                    sc.i = sc.i + 1
                    break
                else
                    cur[#cur + 1] = take(sc)
                end
            end
            items[#items + 1] = table.concat(cur)
            eat(sc, "}")
            return { type = "choice", index = idx, items = items }
        end
        if eat(sc, "/") then
            local regex = read_text(sc, "/")
            eat(sc, "/")
            local replacement = read_replacement(sc)
            eat(sc, "/")
            local flags = read_text(sc, "}")
            eat(sc, "}")
            return {
                type = "transform",
                index = idx,
                regex = regex,
                replacement = replacement,
                flags = flags,
            }
        end
        -- Malformed: consume to the closing brace so one bad form cannot swallow the rest.
        read_text(sc, "}")
        eat(sc, "}")
        return { type = "tabstop", index = idx }
    end

    local name = read_name(sc)
    if name then
        if eat(sc, "}") then
            return { type = "variable", name = name }
        end
        if eat(sc, ":") then
            local children = parse_nodes(sc, "}")
            eat(sc, "}")
            return { type = "variable", name = name, children = children }
        end
        if eat(sc, "/") then
            local regex = read_text(sc, "/")
            eat(sc, "/")
            local replacement = read_replacement(sc)
            eat(sc, "/")
            local flags = read_text(sc, "}")
            eat(sc, "}")
            return {
                type = "transform",
                name = name,
                regex = regex,
                replacement = replacement,
                flags = flags,
            }
        end
        read_text(sc, "}")
        eat(sc, "}")
        return { type = "variable", name = name }
    end

    -- `${` followed by nothing meaningful: treat it as literal text.
    return { type = "text", text = "${" }
end

--- Parse a node list until `stop` (an unescaped character) or the end of the input.
---@param sc LvimSnippetsScanner
---@param stop string?  a single character that ends this list (nil = end of input)
---@return LvimSnippetsNode[]
parse_nodes = function(sc, stop)
    local nodes = {}
    local stops = "%$" .. (stop and ("%" .. stop) or "")
    while sc.i <= #sc.s do
        if stop and peek(sc) == stop then
            break
        end
        if peek(sc) == "$" then
            sc.i = sc.i + 1
            if eat(sc, "{") then
                nodes[#nodes + 1] = parse_braced(sc)
            else
                local idx = read_int(sc)
                if idx then
                    nodes[#nodes + 1] = { type = "tabstop", index = idx }
                else
                    local name = read_name(sc)
                    if name then
                        nodes[#nodes + 1] = { type = "variable", name = name }
                    else
                        nodes[#nodes + 1] = { type = "text", text = "$" }
                    end
                end
            end
        else
            local text = read_text(sc, stops)
            if text ~= "" then
                nodes[#nodes + 1] = { type = "text", text = text }
            elseif not (stop and peek(sc) == stop) and peek(sc) ~= "$" then
                -- No progress and not at a delimiter: consume one char so we cannot spin.
                local c = take(sc)
                if c and c ~= "" then
                    nodes[#nodes + 1] = { type = "text", text = c }
                end
            end
        end
    end
    return nodes
end

--- Parse a snippet body into a node tree.
---
--- Guarantees an exit stop: a body without `$0` gets one appended, so the session always knows where
--- the cursor ends up and when the snippet is over.
---@param body string
---@return LvimSnippetsNode[]
function M.parse(body)
    local sc = { s = body or "", i = 1 }
    local nodes = parse_nodes(sc, nil)

    local function has_zero(list)
        for _, n in ipairs(list) do
            if (n.type == "tabstop" or n.type == "placeholder" or n.type == "choice") and n.index == 0 then
                return true
            end
            if n.children and has_zero(n.children) then
                return true
            end
        end
        return false
    end
    if not has_zero(nodes) then
        nodes[#nodes + 1] = { type = "tabstop", index = 0 }
    end
    return nodes
end

--- The tabstop indices present in a node tree, ascending, with `0` last — the order a session jumps
--- through. Mirrors (the same index more than once) collapse to a single entry.
---@param nodes LvimSnippetsNode[]
---@return integer[]
function M.stops(nodes)
    local seen, out = {}, {}
    local function walk(list)
        for _, n in ipairs(list) do
            if n.index and n.type ~= "transform" and not seen[n.index] then
                seen[n.index] = true
                out[#out + 1] = n.index
            end
            if n.children then
                walk(n.children)
            end
        end
    end
    walk(nodes)
    table.sort(out, function(a, b)
        if a == 0 then
            return false
        end
        if b == 0 then
            return true
        end
        return a < b
    end)
    return out
end

return M
