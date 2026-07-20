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
---@field postfix { enabled: boolean, rules: LvimSnippetsPostfixRule[] }  pattern-triggered snippets that fire as you type
local M = {
    -- snippet folders (configurable, not hardcoded); the default is the standard
    -- location — override to point at your own dirs (a clean array replace)
    paths = { vim.fn.stdpath("config") .. "/snippets" },
    -- All three formats are handled by this plugin alone. `.lua` collections are read through
    -- `luasnip_shim` — the file's own `require("luasnip")` resolves to a set of data constructors, so
    -- no LuaSnip installation is involved; regex-triggered entries in them become postfix rules.
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
    -- POSTFIX rules: snippets whose trigger is a PATTERN and which fire as you type, with no menu and
    -- no accept key — `foo.par` becoming `(foo)` the moment the `r` lands. A trigger's captures are
    -- addressable as `$1`, `$2`… in the body; `body` may also be a function receiving them, for the
    -- rare rule that needs real logic. This is the shape that used to require a LuaSnip `.lua`
    -- collection (regex trigger + autosnippet + a function node reading the capture).
    postfix = {
        enabled = true,
        -- Empty by default: a `.lua` collection's regex-triggered snippets are registered here
        -- automatically as they load, so the rules live with the snippets rather than being
        -- duplicated in configuration. Add your own here to define one without a collection file.
        ---@type LvimSnippetsPostfixRule[]
        rules = {},
    },
}

return M
