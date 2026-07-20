-- lvim-snippets.cmp: the lvim-cmp adapter — a thin LvimCmpSource over the neutral engine,
-- registered through lvim-cmp's PUBLIC `register_source` API on setup() (when lvim-cmp is
-- installed), so the engine stays completion-agnostic and lvim-cmp carries no built-in
-- snippet knowledge. Each record maps to one LSP-shaped completion item: prefix →
-- label/filter_text, body → insertText (insertTextFormat = 2, the same path LSP snippet
-- items take), the format-priority rank → the sort_text prefix ("<rank>:<prefix>") so
-- snippets with an EQUAL fuzzy score tiebreak by format, and a LuaSnip record's `expand`
-- closure rides on the item (lvim-cmp's accept honours a custom `expand` instead of
-- the session engine). Documentation (description + fenced body / LuaSnip docstring) feeds the
-- docs float. Items are cached per filetype and rebuilt when the engine caches reset
-- (generation stamp).
--
---@module "lvim-snippets.cmp"

local config = require("lvim-snippets.config")
local engine = require("lvim-snippets.engine")

local M = {}

-- LSP CompletionItemKind.Snippet / InsertTextFormat.Snippet
local KIND_SNIPPET = 15
local FORMAT_SNIPPET = 2

---@type boolean  the source has been registered into lvim-cmp (health)
local registered = false

---@type table<string, table[]>  filetype → built completion items (derived from the engine records)
local items_by_ft = {}

---@type integer  the engine generation the item cache was built against
local cache_generation = 0

--- Map one neutral record to an lvim-cmp completion item (LvimCmpItem shape).
---@param r LvimSnippetsRecord
---@return table
local function to_item(r)
    local raw
    local expand
    if r.kind == "luasnip" then
        raw = {
            label = r.prefix,
            insertText = r.prefix, -- fallback text; ignored when `expand` runs
            insertTextFormat = FORMAT_SNIPPET,
            detail = r.description,
            documentation = r.docstring
                    and { kind = "markdown", value = "```" .. r.ft .. "\n" .. r.docstring .. "\n```" }
                or nil,
        }
        expand = r.expand
    else
        local doc = (r.description and r.description ~= "" and (r.description .. "\n\n") or "")
            .. "```"
            .. r.ft
            .. "\n"
            .. r.body
            .. "\n```"
        raw = {
            label = r.prefix,
            insertText = r.body,
            insertTextFormat = FORMAT_SNIPPET,
            detail = r.name,
            documentation = { kind = "markdown", value = doc },
        }
    end
    return {
        raw = raw,
        source_name = "snippets",
        label = r.prefix,
        filter_text = r.prefix,
        sort_text = ("%d:"):format(r.rank) .. r.prefix,
        kind = KIND_SNIPPET,
        expand = expand,
    }
end

--- The (cached) completion items for `ft` — rebuilt when the engine caches reset.
---@param ft string
---@return table[]
local function items_for(ft)
    local gen = engine.generation()
    if gen ~= cache_generation then
        items_by_ft = {}
        cache_generation = gen
    end
    if ft == "" then
        ft = "all"
    end
    local cached = items_by_ft[ft]
    if cached then
        return cached
    end
    local out = {}
    for _, r in ipairs(engine.get(ft)) do
        out[#out + 1] = to_item(r)
    end
    items_by_ft[ft] = out
    return out
end

--- The LvimCmpSource contract (name / enabled / get) lvim-cmp fans out to.
local source = {
    name = "snippets",

    --- Whether the source serves the context — the live `cmp.enabled` switch.
    ---@param ctx table  LvimCmpContext
    ---@return boolean
    enabled = function(ctx)
        local _ = ctx
        return config.cmp.enabled
    end,

    --- Emit the context filetype's snippet items.
    ---@param ctx table  LvimCmpContext
    ---@param cb fun(items: table[], incomplete: boolean)
    ---@return fun()? cancel
    get = function(ctx, cb)
        local items = items_for(vim.bo[ctx.bufnr].filetype)
        vim.schedule(function()
            cb(items, false)
        end)
        return nil
    end,
}

--- Register the source into lvim-cmp through its public `register_source` API (the
--- per-source opts — priority / keyword floor — come from `config.cmp`). A no-op when
--- lvim-cmp is not installed; safe to call again (re-registering the same name replaces
--- the source in place).
---@return boolean registered
function M.register()
    local ok, cmp = pcall(require, "lvim-cmp")
    if not ok or type(cmp.register_source) ~= "function" then
        return false
    end
    cmp.register_source(source, {
        enabled = true,
        priority = config.cmp.priority,
        min_keyword_length = config.cmp.min_keyword_length,
    })
    registered = true
    return true
end

--- Whether the source has been registered into lvim-cmp this session (:checkhealth).
---@return boolean
function M.registered()
    return registered
end

return M
