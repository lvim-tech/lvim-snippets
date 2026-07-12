-- lvim-snippets.engine: snippet discovery + parsing — the format-neutral core. Collections
-- in THREE formats are discovered by file extension under each configured root
-- (`config.paths`), recursing into subdirectories:
--   • VS Code JSON  — a package.json manifest maps files per `contributes.snippets`
--     (language → path), else loose `<filetype>.json` by basename;
--   • SnipMate      — loose `<filetype>.snippets` (parsed here, no dependency);
--   • LuaSnip       — loose `<filetype>.lua` (OPTIONAL: only when LuaSnip is installed,
--     which reads its own format and drives expansion).
-- The language "all" applies to every filetype. Which formats are active AND their relative
-- PRIORITY is `config.formats` (list order = priority; an omitted format is off) — stamped
-- into each record's `rank` so consumers can tiebreak equal matches by format. Files parse
-- LAZILY, once per filetype per session. The engine emits NEUTRAL records (no completion-item
-- shape): the lvim-cmp adapter (lvim-snippets.cmp) and the :LvimSnippets picker both consume
-- `M.get(ft)`; expansion goes through `M.expand` — native vim.snippet for vscode/snipmate
-- records, the record's own `expand` closure (LuaSnip) otherwise.
--
---@module "lvim-snippets.engine"

local config = require("lvim-snippets.config")

local uv = vim.uv

local M = {}

---@class LvimSnippetsRecord              one neutral snippet record
---@field prefix string                   the completable trigger word
---@field body string                     the snippet body (LSP snippet syntax; the trigger itself for LuaSnip records)
---@field description string?             the snippet's declared description
---@field name string?                    the snippet's declared name (VS Code / SnipMate)
---@field ft string                       the filetype the record was built for (fence language)
---@field kind "vscode"|"snipmate"|"luasnip"
---@field rank integer                    the format's priority index (1 = highest; `config.formats` order)
---@field docstring string?               LuaSnip docstring — the expanded form, for previews/documentation
---@field expand fun()?                   custom expander (LuaSnip records) — replaces vim.snippet.expand

---@type table<string, LvimSnippetsFile[]>?  language → snippet-file entries (nil until discovery ran)
local files_by_lang = nil

---@type table<string, LvimSnippetsRecord[]>  filetype → built records (parsed lazily, kept per session)
local records_by_ft = {}

---@type string[]  files that failed to parse (reported by :checkhealth)
local broken_files = {}

---@type boolean  LuaSnip `.lua` files were found but LuaSnip is not installed (health note)
local luasnip_seen = false

---@type integer  bumped on every reset() so consumers can invalidate their derived caches
local generation = 1

--- Read + JSON-decode a file; nil (and a health note) on failure.
---@param path string
---@return table?
local function read_json(path)
    local fd = io.open(path, "r")
    if not fd then
        return nil
    end
    local text = fd:read("*a")
    fd:close()
    local ok, decoded = pcall(vim.json.decode, text)
    if not ok or type(decoded) ~= "table" then
        broken_files[#broken_files + 1] = path
        return nil
    end
    return decoded
end

---@class LvimSnippetsFile               one discovered snippet file
---@field path string
---@field kind "vscode"|"snipmate"|"luasnip"

--- Register `path` (of `kind`) for one language (or a list of languages) in `map`.
---@param map table<string, LvimSnippetsFile[]>
---@param lang string|string[]
---@param path string
---@param kind "vscode"|"snipmate"|"luasnip"
local function register(map, lang, path, kind)
    local langs = type(lang) == "table" and lang or { lang }
    for _, l in ipairs(langs) do
        if type(l) == "string" and l ~= "" then
            map[l] = map[l] or {}
            map[l][#map[l] + 1] = { path = path, kind = kind }
        end
    end
end

--- Register one collection directory, RECURSING into subdirectories so a root can be
--- organised into nested folders by type/purpose (e.g. `languages/lua.json`,
--- `frameworks/web/react.json`, `custom/mine.snippets`). A dir WITH a package.json
--- manifest is a self-contained VS Code collection — its manifest owns the layout, so it
--- is mapped by `contributes.snippets` and NOT descended further. Otherwise loose files are
--- mapped by basename + EXTENSION at every depth — `<ft>.json` (VS Code), `<ft>.snippets`
--- (SnipMate), `<ft>.lua` (LuaSnip); the directory names are purely organisational (the
--- FILENAME sets the filetype). `depth` guards against symlink cycles.
---@param map table<string, LvimSnippetsFile[]>
---@param dir string
---@param depth integer  0 at a root; recursion stops past a sane cap
local function register_dir(map, dir, depth)
    if depth > 16 then
        return
    end
    local manifest = read_json(dir .. "/package.json")
    local contributes = manifest and manifest.contributes and manifest.contributes.snippets
    if type(contributes) == "table" then
        for _, entry in ipairs(contributes) do
            if type(entry) == "table" and type(entry.path) == "string" and entry.language then
                local path = vim.fs.normalize(dir .. "/" .. entry.path)
                if uv.fs_stat(path) then
                    register(map, entry.language, path, "vscode")
                end
            end
        end
        return -- a manifest-defined collection owns its own layout; do not also descend
    end
    local handle = uv.fs_scandir(dir)
    while handle do
        local name, entry_type = uv.fs_scandir_next(handle)
        if not name then
            break
        end
        local full = dir .. "/" .. name
        if entry_type == "file" then
            if name:sub(-5) == ".json" and name ~= "package.json" then
                register(map, name:sub(1, -6), full, "vscode")
            elseif name:sub(-9) == ".snippets" then
                register(map, name:sub(1, -10), full, "snipmate")
            elseif name:sub(-4) == ".lua" then
                register(map, name:sub(1, -5), full, "luasnip")
            end
        elseif entry_type == "directory" then
            register_dir(map, full, depth + 1) -- descend — arbitrary nesting for organisation
        end
    end
end

--- Discover every collection once: each configured root (`config.paths`), walked
--- recursively. The folders are fully config-driven — no path is hardcoded here.
---@return table<string, LvimSnippetsFile[]>
local function discover()
    if files_by_lang then
        return files_by_lang
    end
    local map = {}
    local roots = {}
    for _, p in ipairs(config.paths or {}) do
        roots[#roots + 1] = vim.fs.normalize(p)
    end
    for _, root in ipairs(roots) do
        if uv.fs_stat(root) then
            register_dir(map, root, 0) -- recurses the whole tree under the root
        end
    end
    files_by_lang = map
    return map
end

--- Build the records of ONE parsed snippet file for `ft`. A snippet may declare several
--- prefixes — each becomes its own record (same body). `rank` (the format's priority index,
--- lower = higher priority) rides on the record so consumers can tiebreak equal matches by
--- format (see `config.formats`).
---@param snippets table   the decoded file: name → { prefix, body, description }
---@param ft string        the filetype the records serve (fence language for previews)
---@param kind "vscode"|"snipmate"
---@param out LvimSnippetsRecord[]
---@param rank integer     the format's priority index (1 = highest)
local function build_records(snippets, ft, kind, out, rank)
    for name, snip in pairs(snippets) do
        if type(snip) == "table" and snip.prefix and snip.body then
            local body = type(snip.body) == "table" and table.concat(snip.body, "\n") or tostring(snip.body)
            local desc = snip.description
            if type(desc) == "table" then
                desc = table.concat(desc, "\n")
            end
            local prefixes = type(snip.prefix) == "table" and snip.prefix or { snip.prefix }
            for _, prefix in ipairs(prefixes) do
                if type(prefix) == "string" and prefix ~= "" then
                    out[#out + 1] = {
                        prefix = prefix,
                        body = body,
                        description = type(desc) == "string" and desc or nil,
                        name = type(name) == "string" and name or nil,
                        ft = ft,
                        kind = kind,
                        rank = rank or 1,
                    }
                end
            end
        end
    end
end

--- Parse a SnipMate `.snippets` file into the same `{ name → { prefix, body, description } }`
--- shape `build_records` consumes. Format: a `snippet <trigger> [description]` line starts a
--- snippet; the following TAB- (or space-) indented lines are its body, one indent level
--- stripped; `# …` are comments and `extends …` directives end the current snippet (cross-
--- file inheritance is not expanded here). Bodies use LSP-compatible `${1:…}` / `$0` tabstops
--- (expanded natively); backtick `` `…` `` / python `` `!p …` `` interpolations are NOT
--- evaluated (vim.snippet cannot) — they pass through literally.
---@param path string
---@return table  name → { prefix, body, description }
local function parse_snipmate(path)
    local fd = io.open(path, "r")
    if not fd then
        return {}
    end
    local out, n = {}, 0
    ---@type { prefix: string, description: string?, body: string[] }?
    local cur
    local function flush()
        if cur then
            while #cur.body > 0 and cur.body[#cur.body]:match("^%s*$") do
                cur.body[#cur.body] = nil -- trim trailing blank lines
            end
            if #cur.body > 0 then
                n = n + 1
                out["s" .. n] =
                    { prefix = cur.prefix, body = table.concat(cur.body, "\n"), description = cur.description }
            end
        end
        cur = nil
    end
    for raw_line in fd:lines() do
        local trig, rest = raw_line:match("^snippet%s+(%S+)%s*(.*)$")
        if trig then
            flush()
            cur = { prefix = trig, description = (rest ~= "" and rest) or nil, body = {} }
        elseif cur and raw_line:match("^[\t ]") then
            cur.body[#cur.body + 1] = raw_line:gsub("^\t", "", 1):gsub("^    ", "", 1) -- strip ONE indent level
        elseif cur and raw_line:match("^%s*$") then
            cur.body[#cur.body + 1] = "" -- a blank line inside a body is part of it
        else
            flush() -- a non-indented line (extends / comment / next block start) ends this one
        end
    end
    flush()
    fd:close()
    return out
end

--- Load a LuaSnip `.lua` snippet file. These are LuaSnip's own code (they `require`
--- "luasnip" and can use function/dynamic nodes only LuaSnip can expand), so this is
--- OPTIONAL: it is a no-op unless LuaSnip is installed. Each STRING-trigger snippet becomes
--- a record whose `expand` delegates to `luasnip.snip_expand` (pattern/function triggers are
--- skipped — they are not completable prefixes). Best-effort for the standard
--- `return { s(…), … }` file shape; guarded so a bad file never breaks the registry.
---@param path string
---@param ft string
---@param out LvimSnippetsRecord[]
---@param rank integer   the format's priority index (1 = highest)
local function load_luasnip(path, ft, out, rank)
    local ok_ls = pcall(require, "luasnip")
    if not ok_ls then
        luasnip_seen = true -- files exist but no engine → :checkhealth note
        return
    end
    local ok, snips = pcall(dofile, path)
    if not ok or type(snips) ~= "table" then
        broken_files[#broken_files + 1] = path
        return
    end
    for _, snip in ipairs(snips) do
        local trig = type(snip) == "table" and snip.trigger or nil
        if type(trig) == "string" and trig ~= "" and not snip.regTrig then
            local doc
            local ok_doc, ds = pcall(function()
                return snip:get_docstring()
            end)
            if ok_doc and ds then
                doc = type(ds) == "table" and table.concat(ds, "\n") or tostring(ds)
            end
            local desc = snip.dscr
                    and (type(snip.dscr) == "table" and table.concat(snip.dscr, " ") or tostring(snip.dscr))
                or (type(snip.name) == "string" and snip.name or nil)
            out[#out + 1] = {
                prefix = trig,
                body = trig, -- fallback text; the `expand` closure does the real insertion
                description = desc,
                ft = ft,
                kind = "luasnip",
                rank = rank or 1,
                docstring = doc,
                expand = function()
                    pcall(function()
                        require("luasnip").snip_expand(snip)
                    end)
                end,
            }
        end
    end
end

--- The (lazily built, session-cached) ranked records for a filetype: its own files + "all".
--- Enabled formats run in the configured PRIORITY order (list index = rank; an omitted
--- format is off) — formats OUTER and files inner, so higher-priority formats emit first
--- and every record carries its rank for consumer-side tiebreaks.
---@param ft? string  the filetype (default: the current buffer's); "" maps to "all"
---@return LvimSnippetsRecord[]
function M.get(ft)
    ft = ft or vim.bo.filetype
    if ft == "" then
        ft = "all"
    end
    local cached = records_by_ft[ft]
    if cached then
        return cached
    end
    local map = discover()
    local out = {}
    local formats = config.formats or { "vscode", "snipmate", "luasnip" }
    ---@param entry LvimSnippetsFile
    ---@param rank integer
    local function dispatch(entry, rank)
        if entry.kind == "vscode" then
            local decoded = read_json(entry.path)
            if decoded then
                build_records(decoded, ft, "vscode", out, rank)
            end
        elseif entry.kind == "snipmate" then
            build_records(parse_snipmate(entry.path), ft, "snipmate", out, rank)
        elseif entry.kind == "luasnip" then
            load_luasnip(entry.path, ft, out, rank)
        end
    end
    local lists = { map[ft] or {} }
    if ft ~= "all" then
        lists[#lists + 1] = map.all or {}
    end
    for rank, fmt in ipairs(formats) do
        for _, list in ipairs(lists) do
            for _, entry in ipairs(list) do
                if entry.kind == fmt then
                    dispatch(entry, rank)
                end
            end
        end
    end
    records_by_ft[ft] = out
    return out
end

--- Expand a record at the cursor: a LuaSnip record runs its own `expand` closure
--- (function/dynamic nodes only LuaSnip can drive); everything else expands through
--- native vim.snippet — tabstops jump with vim.snippet.jump / the consumer's keys.
---@param record LvimSnippetsRecord
function M.expand(record)
    if type(record) ~= "table" then
        return
    end
    if type(record.expand) == "function" then
        record.expand()
    else
        vim.snippet.expand(record.body or "")
    end
end

--- Registry statistics for :checkhealth.
---@return { languages: integer, files: integer, broken: string[], by_kind: table<string, integer>, luasnip_available: boolean, luasnip_orphan: boolean }
function M.stats()
    local map = discover()
    local languages, files = 0, 0
    local by_kind = { vscode = 0, snipmate = 0, luasnip = 0 }
    for _, entries in pairs(map) do
        languages = languages + 1
        for _, e in ipairs(entries) do
            files = files + 1
            by_kind[e.kind] = (by_kind[e.kind] or 0) + 1
        end
    end
    return {
        languages = languages,
        files = files,
        broken = broken_files,
        by_kind = by_kind,
        luasnip_available = pcall(require, "luasnip"),
        -- LuaSnip `.lua` files exist but no engine loaded them (only set once a ft has been built)
        luasnip_orphan = luasnip_seen,
    }
end

--- Drop the discovery + record caches (config `paths`/`formats` changed / new files on
--- disk) and bump the generation so consumers rebuild their derived caches.
function M.reset()
    files_by_lang = nil
    records_by_ft = {}
    broken_files = {}
    luasnip_seen = false
    generation = generation + 1
end

--- The current cache generation — bumped by every reset(). Consumers key their derived
--- caches (e.g. the lvim-cmp adapter's completion items) on it.
---@return integer
function M.generation()
    return generation
end

return M
