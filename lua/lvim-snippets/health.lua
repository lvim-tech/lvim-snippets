-- lvim-snippets: :checkhealth lvim-snippets.
-- Diagnoses what makes a snippet registry misbehave invisibly: the required runtime
-- (vim.snippet), the shared dependencies (lvim-utils merge, lvim-ui for the picker), an
-- internally inconsistent config (paths / formats / cmp numbers), the collections actually
-- discovered (per-format counts, the active priority order, unparsable files), LuaSnip
-- `.lua` files present without LuaSnip installed (orphans — silently skipped), and whether
-- the "snippets" source really registered into lvim-cmp. Read-only.
--
---@module "lvim-snippets.health"

local config = require("lvim-snippets.config")

local M = {}

---@type table<string, boolean>  the valid `formats` entries
local KNOWN_FORMATS = { vscode = true, snipmate = true, luasnip = true }

--- Validate the live config; error on each violation, ok when clean.
---@param health table  the vim.health reporter
local function check_config(health)
    local problems = 0

    if type(config.paths) ~= "table" then
        health.error(("paths must be a list of directories (got %s)"):format(type(config.paths)))
        problems = problems + 1
    else
        for _, p in ipairs(config.paths) do
            if type(p) ~= "string" then
                health.error(("paths entries must be strings (got %s)"):format(vim.inspect(p)))
                problems = problems + 1
            end
        end
    end
    if type(config.formats) ~= "table" or #config.formats == 0 then
        health.error("formats must be a non-empty list (order = priority)")
        problems = problems + 1
    else
        local seen = {}
        for _, f in ipairs(config.formats) do
            if not KNOWN_FORMATS[f] then
                health.error(
                    ('formats entries must be "vscode" | "snipmate" | "luasnip" (got %s)'):format(vim.inspect(f))
                )
                problems = problems + 1
            elseif seen[f] then
                health.error(("formats lists %s twice"):format(f))
                problems = problems + 1
            end
            seen[f] = true
        end
    end
    if type(config.cmp.enabled) ~= "boolean" then
        health.error("cmp.enabled must be a boolean")
        problems = problems + 1
    end
    if type(config.cmp.priority) ~= "number" then
        health.error("cmp.priority must be a number")
        problems = problems + 1
    end
    if type(config.cmp.min_keyword_length) ~= "number" or config.cmp.min_keyword_length < 0 then
        health.error("cmp.min_keyword_length must be a number >= 0")
        problems = problems + 1
    end
    local layout = config.picker.layout
    if layout ~= "float" and layout ~= "area" and layout ~= "bottom" then
        health.error(('picker.layout must be "float" | "area" | "bottom" (got %s)'):format(vim.inspect(layout)))
        problems = problems + 1
    end
    local side = config.picker.preview_side
    if side ~= "right" and side ~= "left" and side ~= "above" and side ~= "below" then
        health.error(
            ('picker.preview_side must be "right" | "left" | "above" | "below" (got %s)'):format(vim.inspect(side))
        )
        problems = problems + 1
    end
    if problems == 0 then
        health.ok("config valid")
    end
end

--- Run the health report.
function M.check()
    local health = vim.health
    health.start("lvim-snippets")

    if vim.fn.has("nvim-0.11") == 1 then
        health.ok("Neovim >= 0.11")
    else
        health.error("Neovim >= 0.11 is required (vim.snippet expansion)")
    end

    -- shared dependencies
    local ok_utils = pcall(require, "lvim-utils.utils")
    if ok_utils then
        health.ok("lvim-utils found (setup() merge)")
    else
        health.warn("lvim-utils not found — setup() option merging degrades")
    end
    local ok_ui, ui = pcall(require, "lvim-ui")
    if ok_ui and type(ui.tabs) == "function" then
        health.ok("lvim-ui found (:LvimSnippets picker available)")
    else
        health.warn("lvim-ui not found — :LvimSnippets cannot open (completion is unaffected)")
    end

    -- the discovered collections
    local stats = require("lvim-snippets.engine").stats()
    if stats.files > 0 then
        local k = stats.by_kind
        health.ok(
            ("%d file(s) across %d language(s) — vscode:%d snipmate:%d luasnip:%d (priority: %s)"):format(
                stats.files,
                stats.languages,
                k.vscode,
                k.snipmate,
                k.luasnip,
                table.concat(config.formats or {}, " > ")
            )
        )
    else
        health.info(
            ("no collection found under: %s (<ft>.json / <ft>.snippets / <ft>.lua, recursive)"):format(
                table.concat(config.paths or {}, ", ")
            )
        )
    end
    if stats.luasnip_available then
        health.ok("LuaSnip installed — `.lua` snippet files load and expand through it")
    elseif stats.by_kind.luasnip > 0 then
        health.warn("LuaSnip `.lua` files found but LuaSnip is not installed — they are skipped")
    end
    for _, path in ipairs(stats.broken) do
        health.warn(("unparsable file skipped: %s"):format(path))
    end

    -- the lvim-cmp registration
    if config.cmp.enabled then
        local ok_cmp = pcall(require, "lvim-cmp")
        if not ok_cmp then
            health.info("lvim-cmp not installed — engine + picker only (no completion source)")
        elseif require("lvim-snippets.cmp").registered() then
            health.ok(
                ('registered into lvim-cmp as source "snippets" (priority %d, min_keyword_length %d)'):format(
                    config.cmp.priority,
                    config.cmp.min_keyword_length
                )
            )
        else
            health.warn("lvim-cmp is installed but the source is not registered — was setup() called?")
        end
    else
        health.info("cmp registration disabled (cmp.enabled = false)")
    end

    check_config(health)
end

return M
