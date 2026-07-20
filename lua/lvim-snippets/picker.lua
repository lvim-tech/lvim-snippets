-- lvim-snippets.picker: the :LvimSnippets picker — the current buffer's snippet records in
-- the canonical lvim-ui items-list panel (one tab named after the filetype), with a live
-- BODY preview beside the list (lvim-ui.preview scratch render: treesitter by language,
-- never a filetype — no LSP attach) and insert-at-cursor on confirm through the engine's
-- `expand` (the plugin's own session engine — tabstops jump as usual).
-- Labels are column-aligned: prefix padded to the widest prefix, description after it.
-- Layout resolves per-command token → `config.picker.layout` → "float"; a per-command
-- token is sticky for the session (the panels canon).
--
---@module "lvim-snippets.picker"

local config = require("lvim-snippets.config")
local engine = require("lvim-snippets.engine")

local api = vim.api

local M = {}

---@type { layout: string? }  session state: the sticky per-command layout override
local state = { layout = nil }

--- The preview text of a record: the LuaSnip docstring when present (the expanded form —
--- the raw file is Lua code, not what gets inserted), else the snippet body itself.
---@param rec LvimSnippetsRecord
---@return string[]
local function preview_lines(rec)
    local text = rec.docstring or rec.body or ""
    return vim.split(text, "\n", { plain = true })
end

--- Open the picker over the current buffer's snippets. `args` may carry a layout token
--- ("float" | "area" | "bottom") anywhere — it overrides the config default and sticks
--- for the session.
---@param args? string[]
function M.open(args)
    for _, a in ipairs(args or {}) do
        if a == "float" or a == "area" or a == "bottom" then
            state.layout = a
        end
    end
    local layout = state.layout or config.picker.layout or "float"

    local ft = vim.bo.filetype
    local records = engine.get(ft)
    if #records == 0 then
        vim.notify(
            ("lvim-snippets: no snippets for filetype %q (paths: %s)"):format(
                ft ~= "" and ft or "all",
                table.concat(config.paths or {}, ", ")
            ),
            vim.log.levels.INFO
        )
        return
    end
    local ok_ui, ui = pcall(require, "lvim-ui")
    if not ok_ui then
        vim.notify("lvim-snippets: lvim-ui is required for the picker", vim.log.levels.ERROR)
        return
    end
    local ok_prev, uipreview = pcall(require, "lvim-ui.preview")

    -- Column-aligned rows: the prefix padded to the widest prefix, the description (first
    -- line only — labels are single-line) after a 2-space gap.
    local wide = 0
    for _, r in ipairs(records) do
        wide = math.max(wide, vim.fn.strdisplaywidth(r.prefix))
    end
    local items = {}
    for _, r in ipairs(records) do
        local desc = (r.description or r.name or ""):match("[^\n]*") or ""
        local label = r.prefix
        if desc ~= "" then
            label = r.prefix .. string.rep(" ", wide - vim.fn.strdisplaywidth(r.prefix)) .. "  " .. desc
        end
        items[#items + 1] = { label = label, icon = "󰩫", _record = r }
    end

    local opener = api.nvim_get_current_win()
    ---@type LvimSnippetsRecord?  the focused record (drives the preview; rows all carry one)
    local current = records[1]
    local pan_ref -- the live preview panel (captured in the provider's keys hook)

    -- The body-preview block (opt-in via config.picker.preview; needs lvim-ui.preview):
    -- a scratch render per focused record — treesitter keyed by the snippet's language.
    local preview
    if config.picker.preview and ok_prev then
        preview = {
            size = function()
                return math.max(40, math.floor(vim.o.columns * 0.4)), 12
            end,
            update = function(pan)
                if not (pan and pan.win and api.nvim_win_is_valid(pan.win)) then
                    return
                end
                if current then
                    local lang = (current.ft ~= "" and current.ft ~= "all") and current.ft or ft
                    uipreview.render_file(pan, preview_lines(current), lang)
                else
                    uipreview.render_file(pan, { "" }, nil) -- a header-only row → the blank placeholder
                end
            end,
            keys = function(_, pan)
                pan_ref = pan
            end,
            on_close = function()
                pan_ref = nil
            end,
        }
    end

    ui.tabs({
        title = "󰩫 Snippets",
        title_pos = "center",
        layout = layout,
        position = "editor",
        pad = 1,
        footer_hints = true,
        tabs = { { label = ft ~= "" and ft or "all", items = items } },
        preview = preview,
        preview_side = config.picker.preview_side,
        on_item_change = function(item)
            current = item and item._record or nil
            if pan_ref and pan_ref.refresh then
                pan_ref.refresh()
            end
        end,
        callback = function(confirmed, result)
            if not (confirmed and type(result) == "table" and type(result.item) == "table" and result.item._record) then
                return
            end
            local rec = result.item._record
            -- Expand back in the opener window, after the panel has fully closed and focus
            -- is restored — expand inserts at the cursor and enters the first
            -- tabstop (insert/select mode); LuaSnip records go through their own closure.
            vim.schedule(function()
                if api.nvim_win_is_valid(opener) and api.nvim_get_current_win() ~= opener then
                    api.nvim_set_current_win(opener)
                end
                engine.expand(rec)
            end)
        end,
    })
end

return M
