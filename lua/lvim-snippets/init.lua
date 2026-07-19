-- lvim-snippets: snippet collections for the lvim-tech set — VS Code JSON, SnipMate and
-- LuaSnip formats behind ONE neutral engine (discovery by file extension under configurable
-- roots, recursive, lazily parsed per filetype), a completion source for lvim-cmp
-- (registered through its public `register_source` API — lvim-cmp itself carries no snippet
-- code), and the :LvimSnippets picker (list + live body preview + insert at the cursor).
--
-- Public API:
--   M.setup(opts)    – merge options into the live config, register the lvim-cmp source,
--                      install the :LvimSnippets command
--   M.get(ft)        – the ranked NEUTRAL snippet records for a filetype (see engine)
--   M.expand(record) – expand a record at the cursor (vim.snippet / LuaSnip)
--   M.reset()        – drop the discovery + parse caches (paths/formats changed, new files)
--   M.stats()        – registry statistics (per-format counts; :checkhealth)
--
---@module "lvim-snippets"

local config = require("lvim-snippets.config")
local engine = require("lvim-snippets.engine")
local cmp = require("lvim-snippets.cmp")
local merge = require("lvim-utils.utils").merge

local M = {}

--- Merge user options into the LIVE config (in place), drop the engine caches (the paths /
--- formats may have changed — discovery re-runs lazily), register the "snippets" source
--- into lvim-cmp (when installed and `cmp.enabled`), and install :LvimSnippets. Safe to
--- call again at runtime to re-point the collection roots.
---@param opts? LvimSnippetsConfig  any subset of the defaults (see lvim-snippets.config)
function M.setup(opts)
    if opts then
        merge(config, opts)
    end
    engine.reset()
    if config.cmp.enabled then
        cmp.register()
    end
    vim.api.nvim_create_user_command("LvimSnippets", function(c)
        require("lvim-snippets.picker").open(c.fargs)
    end, {
        nargs = "*",
        complete = function()
            return { "float", "area", "bottom" }
        end,
        desc = "Snippet picker: list + body preview + insert at the cursor",
    })
end

--- The ranked neutral snippet records for a filetype (the buffer's own + "all"), in
--- format-priority order (`config.formats`). Each record: `{ prefix, body, description?,
--- name?, ft, kind, rank, docstring?, expand? }`.
---@param ft? string  the filetype (default: the current buffer's)
---@return LvimSnippetsRecord[]
function M.get(ft)
    return engine.get(ft)
end

--- Expand a record at the cursor: native vim.snippet for vscode/snipmate records (tabstops
--- jump as usual), the record's own LuaSnip closure otherwise.
---@param record LvimSnippetsRecord
function M.expand(record)
    engine.expand(record)
end

--- Drop the discovery + parse caches (config `paths`/`formats` changed / new files on disk).
function M.reset()
    engine.reset()
end

--- Registry statistics: file/language counts per format, unparsable files, LuaSnip
--- availability (:checkhealth consumes this).
---@return { languages: integer, files: integer, broken: string[], by_kind: table<string, integer>, luasnip_available: boolean }
function M.stats()
    return engine.stats()
end

return M
