-- lvim-snippets: :checkhealth lvim-snippets.
-- Diagnoses what makes a snippet registry misbehave invisibly: the required runtime
-- the shared dependencies (lvim-utils merge, lvim-ui for the picker), an
-- internally inconsistent config (paths / formats / cmp numbers), the collections actually
-- discovered (per-format counts, the active priority order, unparsable files), `.lua`
-- collections the built-in shim could translate only in part, and whether
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

    if vim.fn.has("nvim-0.12") == 1 then
        health.ok("Neovim >= 0.12")
    else
        health.error("Neovim >= 0.12 is required (the lvim-tech set targets 0.12; lvim-utils requires it)")
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
    local engine = require("lvim-snippets.engine")
    local stats = engine.stats()
    -- Roots a plugin registered are reported separately from the configured ones: "where did these
    -- snippets come from" has a different answer for each, and only the configured list is the user's.
    local plugin_roots = {}
    for _, root in ipairs(engine.roots()) do
        if not vim.tbl_contains(config.paths or {}, root) then
            plugin_roots[#plugin_roots + 1] = root
        end
    end
    if #plugin_roots > 0 then
        health.ok(
            ("%d collection root(s) registered by a plugin: %s"):format(#plugin_roots, table.concat(plugin_roots, ", "))
        )
    end
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
    if stats.by_kind.luasnip > 0 then
        health.ok(
            ("%d `.lua` collection(s) read by the built-in shim — LuaSnip is not required"):format(
                stats.by_kind.luasnip
            )
        )
    end
    for _, path in ipairs(stats.partial or {}) do
        health.warn(("`.lua` file translated only in part (a node has no static form): %s"):format(path))
    end
    for _, path in ipairs(stats.broken) do
        health.warn(("unparsable file skipped: %s"):format(path))
    end

    -- the postfix engine: rules only fire while it is enabled, and a rule carrying a `when`
    -- predicate is CONDITIONAL — worth naming, because "my abbreviation did not expand" is the same
    -- symptom whether the engine is off or the predicate said no.
    local postfix = config.postfix or {}
    local rules = postfix.rules or {}
    local conditional = 0
    for _, rule in ipairs(rules) do
        if type(rule.when) == "function" then
            conditional = conditional + 1
        end
    end
    if postfix.enabled then
        health.ok(("postfix engine on — %d rule(s), %d conditional (`when`)"):format(#rules, conditional))
    elseif #rules > 0 then
        health.warn(
            ("postfix engine off (postfix.enabled = false) — %d registered rule(s) cannot fire"):format(#rules)
        )
    else
        health.info("postfix engine off (postfix.enabled = false)")
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
