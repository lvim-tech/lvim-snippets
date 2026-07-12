-- lvim-snippets.config: the LIVE config — setup() merges user options into this table in
-- place (lvim-utils.utils.merge), so every module `require("lvim-snippets.config")` and
-- sees the effective values. `paths` is a clean array REPLACE on override (no hardcoded
-- root survives a user list), and `formats` order IS the format priority.
--
---@module "lvim-snippets.config"

---@class LvimSnippetsCmpConfig
---@field enabled boolean             register the "snippets" source into lvim-cmp on setup() (needs lvim-cmp installed)
---@field priority integer            the source's merge rank among lvim-cmp sources (higher lists first among equal scores)
---@field min_keyword_length integer  per-source keyword floor inside lvim-cmp (bypassed by a manual trigger)

---@class LvimSnippetsPickerConfig
---@field layout string               ":LvimSnippets" layout default: "float" | "area" | "bottom" (a per-command token overrides it, sticky for the session)
---@field preview boolean             show the body preview panel beside the list
---@field preview_side string         initial preview placement: "right" | "left" | "above" | "below"

---@class LvimSnippetsConfig
---@field paths string[]              snippet collection ROOTS to scan (each walked recursively); fully configurable, NOT hardcoded — the default is just `{ stdpath("config")/snippets }`, and setting your own REPLACES it (clean array merge), so you control exactly which folders are scanned
---@field formats string[]            enabled snippet FORMATS in PRIORITY order — any of "vscode" (VS Code JSON, package.json manifest or loose <ft>.json), "snipmate" (<ft>.snippets), "luasnip" (<ft>.lua, needs LuaSnip installed); a format omitted from the list is disabled; earlier = higher priority (tiebreak among equal-fuzzy snippets)
---@field cmp LvimSnippetsCmpConfig
---@field picker LvimSnippetsPickerConfig
local M = {
    -- snippet folders (configurable, not hardcoded); the default is the standard
    -- location — override to point at your own dirs (a clean array replace)
    paths = { vim.fn.stdpath("config") .. "/snippets" },
    formats = { "vscode", "snipmate", "luasnip" },
    cmp = {
        enabled = true,
        priority = 80,
        min_keyword_length = 1,
    },
    picker = {
        layout = "float",
        preview = true,
        preview_side = "right",
    },
}

return M
