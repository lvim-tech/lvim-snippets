-- The snippet grammar, parsed.
--
-- The parser's own header says it is "deliberately pure … so it can be tested on a body string
-- alone, which is exactly how the tricky cases (nesting, escapes, transforms) get proven". This is
-- that proof: every production of the LSP 3.17 snippet grammar, the escapes, and the two rules a
-- session depends on — every body ends at a `$0`, and the jump order puts `0` last with mirrors
-- collapsed.

local parser = require("lvim-snippets.parser")

--- The parsed node list with the implicit trailing `$0` dropped, so a case can state only what it
--- is about.
---@param body string
---@return table[]
local function nodes(body)
    local out = parser.parse(body)
    if #out > 0 then
        local last = out[#out]
        if last.type == "tabstop" and last.index == 0 and body:find("%$0") == nil and body:find("${0") == nil then
            table.remove(out)
        end
    end
    return out
end

---@param body string
---@return string[]
local function types(body)
    return vim.tbl_map(function(n)
        return n.type
    end, nodes(body))
end

describe("lvim-snippets.parser: text and tabstops")

it("reads plain text as one node", function()
    eq({ "text" }, types("hello world"))
    eq("hello world", nodes("hello world")[1].text)
end)

it("reads $1 and ${1} as the same tabstop", function()
    local bare, braced = nodes("$1")[1], nodes("${1}")[1]
    eq("tabstop", bare.type)
    eq(1, bare.index)
    eq(bare, braced, "the two spellings must parse identically")
end)

it("keeps the text around a tabstop", function()
    eq({ "text", "tabstop", "text" }, types("fn $1 end"))
end)

describe("lvim-snippets.parser: placeholders")

it("parses the default as its own node list", function()
    local n = nodes("${1:value}")[1]
    eq("placeholder", n.type)
    eq(1, n.index)
    eq("text", n.children[1].type)
    eq("value", n.children[1].text)
end)

it("nests a placeholder inside a placeholder", function()
    -- vim.snippet does not do this; the session needs it.
    local outer = nodes("${1:outer ${2:inner}}")[1]
    eq("placeholder", outer.type)
    eq(1, outer.index)
    local inner
    for _, child in ipairs(outer.children) do
        if child.type == "placeholder" then
            inner = child
        end
    end
    truthy(inner, "no nested placeholder in " .. vim.inspect(outer))
    eq(2, inner.index)
    eq("inner", inner.children[1].text)
end)

it("takes an empty default", function()
    local n = nodes("${1:}")[1]
    eq("placeholder", n.type)
    eq(1, n.index)
end)

describe("lvim-snippets.parser: choices")

it("lists the options in order", function()
    local n = nodes("${1|one,two,three|}")[1]
    eq("choice", n.type)
    eq(1, n.index)
    eq({ "one", "two", "three" }, n.items)
end)

it("takes an escaped comma inside an option", function()
    local n = nodes("${1|a\\,b,c|}")[1]
    eq({ "a,b", "c" }, n.items)
end)

describe("lvim-snippets.parser: variables")

it("reads $VAR and ${VAR}", function()
    eq("variable", nodes("$TM_FILENAME")[1].type)
    eq("TM_FILENAME", nodes("$TM_FILENAME")[1].name)
    eq("TM_FILENAME", nodes("${TM_FILENAME}")[1].name)
end)

it("carries a fallback for an empty variable", function()
    local n = nodes("${TM_FILENAME:untitled}")[1]
    eq("variable", n.type)
    eq("TM_FILENAME", n.name)
    eq("untitled", n.children[1].text)
end)

describe("lvim-snippets.parser: transforms")

it("keeps the regex, the replacement and the flags apart", function()
    local n = nodes("${1/foo/bar/g}")[1]
    eq("transform", n.type)
    eq(1, n.index)
    eq("foo", n.regex)
    eq("bar", n.replacement)
    eq("g", n.flags)
end)

it("takes a transform with no flags", function()
    local n = nodes("${1/foo/bar/}")[1]
    eq("transform", n.type)
    eq("foo", n.regex)
    eq("bar", n.replacement)
end)

describe("lvim-snippets.parser: escapes")

it("takes an escaped dollar, brace and backslash as literal text", function()
    eq({ "text" }, types("\\$1"), "an escaped dollar is not a tabstop")
    eq("$1", nodes("\\$1")[1].text)
    eq("}", nodes("\\}")[1].text)
    eq("\\", nodes("\\\\")[1].text)
end)

describe("lvim-snippets.parser: the exit stop")

it("appends a $0 to a body that has none", function()
    local out = parser.parse("just text")
    local last = out[#out]
    eq("tabstop", last.type)
    eq(0, last.index, "every snippet must have a defined end")
end)

it("leaves a body that already ends somewhere alone", function()
    local out = parser.parse("a $0 b")
    local zeros = 0
    for _, n in ipairs(out) do
        if n.index == 0 then
            zeros = zeros + 1
        end
    end
    eq(1, zeros, "no second exit stop appended")
end)

it("counts a $0 nested in a placeholder as the exit stop", function()
    local out = parser.parse("${1:x $0}")
    local zeros = 0
    local function walk(list)
        for _, n in ipairs(list) do
            if n.index == 0 and n.type ~= "transform" then
                zeros = zeros + 1
            end
            if n.children then
                walk(n.children)
            end
        end
    end
    walk(out)
    eq(1, zeros)
end)

describe("lvim-snippets.parser.stops")

it("lists the stops in jump order, with 0 last", function()
    eq({ 1, 2, 3, 0 }, parser.stops(parser.parse("${1:a} $3 ${2:b}")))
end)

it("collapses mirrors of the same stop", function()
    eq({ 1, 0 }, parser.stops(parser.parse("$1 and $1 again")))
end)

it("ignores a transform's index, which is not a stop of its own", function()
    eq({ 1, 0 }, parser.stops(parser.parse("${1:x}${1/a/b/}")))
end)

it("answers for a body with nothing but text", function()
    eq({ 0 }, parser.stops(parser.parse("plain")))
end)
