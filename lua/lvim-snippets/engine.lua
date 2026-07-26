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
-- `M.get(ft)`; expansion goes through `M.expand` — the plugin's own session engine for every
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
---@field expand fun()?                   custom expander (LuaSnip records) — replaces the default

---@type table<string, LvimSnippetsFile[]>?  language → snippet-file entries (nil until discovery ran)
local files_by_lang = nil

---@type table<string, LvimSnippetsRecord[]>  filetype → built records (parsed lazily, kept per session)
local records_by_ft = {}

---@type string[]  files that failed to parse (reported by :checkhealth)
local broken_files = {}

---@type string[]  `.lua` files the shim loaded but could not translate in full
local partial_files = {}

---@type integer  bumped on every reset() so consumers can invalidate their derived caches
local generation = 1

---@type string[]  collection roots REGISTERED at runtime by another plugin (see M.register_paths)
local registered = {}

--- Every collection root, in priority order: the user's `config.paths` first, the roots a plugin
--- REGISTERED after them. That order is the whole point of keeping the two lists apart — a plugin's
--- own collection must never outrank (or replace) what the user configured, and `config.paths` is a
--- clean array REPLACE on merge, so a plugin writing into it would silently drop the user's folders.
---@return string[]
function M.roots()
    local out = {}
    for _, p in ipairs(config.paths or {}) do
        out[#out + 1] = p
    end
    for _, p in ipairs(registered) do
        out[#out + 1] = p
    end
    return out
end

--- Register extra collection roots owned by a PLUGIN (its own shipped snippets), appended after the
--- user's `config.paths`. Idempotent: a root already registered — or already configured — is ignored,
--- so calling it from a plugin's `setup()` on every reload is safe. A NEW root drops the discovery
--- caches so it is picked up immediately, whatever the load order was.
---@param paths string|string[]
---@return integer  how many roots were added by this call
function M.register_paths(paths)
    local list = type(paths) == "table" and paths or { paths }
    local known = {}
    for _, p in ipairs(M.roots()) do
        known[vim.fs.normalize(vim.fn.expand(p))] = true
    end
    local added = 0
    for _, p in ipairs(list) do
        if type(p) == "string" and p ~= "" then
            local root = vim.fs.normalize(vim.fn.expand(p))
            if not known[root] then
                known[root] = true
                registered[#registered + 1] = root
                added = added + 1
            end
        end
    end
    if added > 0 then
        M.reset()
    end
    return added
end

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
            -- The same FILE must never be registered twice for one language. Configured roots can
            -- NEST — a vendored pack inside the main folder is the obvious layout — and the walker
            -- descends each root fully, so every file under an inner root was found once through it
            -- and once through the outer one. That doubled the discovered count (576 for 296 files
            -- here) and, worse, listed every one of those snippets twice in the completion menu. The
            -- dedupe lives at the file level rather than the root level because the outer/inner pair
            -- are both legitimate roots — neither should be dropped, only the second sighting.
            -- Compared by REAL path, not by the string we arrived on: with symlinks followed, one
            -- file is legitimately reachable under several names (a linked file AND a linked parent
            -- directory both lead to it), and a string compare would register each sighting as its
            -- own collection — the same snippets listed twice in the menu.
            local real = uv.fs_realpath(path) or path
            local dup = false
            for _, existing in ipairs(map[l]) do
                if existing.path == real then
                    dup = true
                    break
                end
            end
            if not dup then
                map[l][#map[l] + 1] = { path = real, kind = kind }
            end
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
        -- A SYMLINK is reported by `fs_scandir_next` as type "link", never as "file"/"directory", so a
        -- symlinked collection (the usual dotfiles arrangement — one real tree, linked into the
        -- snippets root) was skipped without a word. Resolve it with `fs_stat`, which FOLLOWS the link;
        -- the depth cap above is what keeps a symlink cycle finite, exactly as documented.
        if entry_type == "link" then
            entry_type = (uv.fs_stat(full) or {}).type
        end
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

--- Discover every collection once: each root (`config.paths`, then the registered ones), walked
--- recursively. The folders are fully config-driven — no path is hardcoded here.
---@return table<string, LvimSnippetsFile[]>
local function discover()
    if files_by_lang then
        return files_by_lang
    end
    local map = {}
    local roots = {}
    local seen = {}
    for _, p in ipairs(M.roots()) do
        local root = vim.fs.normalize(p)
        if not seen[root] then -- a duplicate root would register every collection under it twice
            seen[root] = true
            roots[#roots + 1] = root
        end
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
--- evaluated — they pass through literally.
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

--- Load a `.lua` (LuaSnip-style) collection. Uses the plugin's OWN shim rather than LuaSnip: the file
--- is run with its `require("luasnip")` resolved to a set of pure data constructors, and the snippets
--- it builds are flattened into ordinary LSP bodies the session engine expands like any other format.
--- A `regTrig` snippet is registered as a POSTFIX rule instead — that is precisely what it is.
---@param path string
---@param ft string
---@param out table[]
---@param rank integer
local function load_luasnip(path, ft, out, rank)
    local shim = require("lvim-snippets.luasnip_shim")
    local snips, postfix, err = shim.load(path)
    if err or not snips then
        broken_files[#broken_files + 1] = path
        return
    end
    for _, sp in ipairs(snips) do
        -- The shim flags a snippet whose nodes it could not fully translate (a dynamic node has no
        -- static form). It still expands and jumps — it just may be missing a computed piece — so it
        -- is listed, and the file is surfaced in :checkhealth rather than failing silently.
        if sp.complete == false and not vim.tbl_contains(partial_files, path) then
            partial_files[#partial_files + 1] = path
        end
        out[#out + 1] = {
            prefix = sp.prefix,
            body = sp.body,
            description = sp.description,
            ft = ft,
            kind = "luasnip",
            rank = rank or 1,
            docstring = sp.body,
        }
    end
    -- Regex-triggered entries are auto-expanding rules, not completion items: hand them to the
    -- postfix engine, which owns that behaviour, rather than listing them in a menu they can never
    -- be selected from.
    if postfix and #postfix > 0 then
        local cfgmod = require("lvim-snippets.config")
        cfgmod.postfix = cfgmod.postfix or { enabled = true, rules = {} }
        cfgmod.postfix.rules = cfgmod.postfix.rules or {}
        for _, rule in ipairs(postfix) do
            local dup = false
            for _, existing in ipairs(cfgmod.postfix.rules) do
                if existing.trigger == rule.trigger then
                    dup = true
                end
            end
            if not dup then
                rule.ft = ft ~= "all" and ft or nil
                cfgmod.postfix.rules[#cfgmod.postfix.rules + 1] = rule
            end
        end
    end
end

--- The (lazily built, session-cached) ranked records for a filetype: its own files + "all".
--- Two priorities apply, outer to inner: the ROOT order in `config.paths` (your own folder first, a
--- vendored collection after it), then the FORMAT order in `config.formats`. Every record carries the
--- format's rank for consumer-side tiebreaks; the root decides emission order.
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
    -- ROOT order is the outer priority, FORMAT order the inner one. The root list is already a
    -- ranked list — the first root is the one whose snippets should win — so a collection dropped in
    -- a later root (a vendored pack of a few hundred files, or a plugin's own registered folder) can
    -- never outrank your own, whatever format each happens to use. Ranking by format alone could not
    -- express that: your `.json` and a vendor `.json` were indistinguishable once parsed.
    local roots = M.roots()
    -- LONGEST matching root wins, not the first: roots legitimately nest (a vendored collection
    -- dropped inside the main folder is the obvious layout), and a plain first-match test assigns
    -- every nested file to the outer root, silently collapsing the priority it was configured for.
    local function root_rank(path)
        local best, best_len = #roots + 1, -1
        for i, root in ipairs(roots) do
            local dir = vim.fn.expand(root)
            if path:sub(1, #dir) == dir and #dir > best_len then
                best, best_len = i, #dir
            end
        end
        return best
    end
    for r = 1, math.max(#roots, 1) + 1 do
        for rank, fmt in ipairs(formats) do
            for _, list in ipairs(lists) do
                for _, entry in ipairs(list) do
                    if entry.kind == fmt and root_rank(entry.path) == r then
                        -- The rank a record carries stays the FORMAT's, so an existing consumer's
                        -- tiebreak keeps its meaning; the root only decides emission order, which is
                        -- what the picker and the equal-score case actually read.
                        dispatch(entry, rank)
                    end
                end
            end
        end
    end
    records_by_ft[ft] = out
    return out
end

--- Expand a record at the cursor through the plugin's OWN session engine (parser + session), which
--- implements the whole LSP snippet grammar — nested placeholders, mirrors, choices, transforms and
--- date/file variables. `vim.snippet` covers only part of that, which is why a computed value used to
--- require a LuaSnip `.lua` collection; it no longer does.
---
--- A record carrying its own `expand` closure (a LuaSnip collection, when one is installed) still
--- runs it: that code builds LuaSnip nodes directly and only LuaSnip can drive them.
---@param record LvimSnippetsRecord
function M.expand(record)
    if type(record) ~= "table" then
        return
    end
    if type(record.expand) == "function" then
        record.expand()
    else
        require("lvim-snippets.session").expand(record.body or "")
    end
end

--- Registry statistics for :checkhealth.
---@return { languages: integer, files: integer, broken: string[], partial: string[], by_kind: table<string, integer> }
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
        partial = partial_files,
        by_kind = by_kind,
    }
end

--- Drop the discovery + record caches (config `paths`/`formats` changed / new files on
--- disk) and bump the generation so consumers rebuild their derived caches. Roots REGISTERED by a
--- plugin survive: they are a registration, not a cache — dropping them would need every plugin to
--- re-register whenever the user re-ran setup().
function M.reset()
    files_by_lang = nil
    records_by_ft = {}
    broken_files = {}
    partial_files = {}
    generation = generation + 1
end

--- The current cache generation — bumped by every reset(). Consumers key their derived
--- caches (e.g. the lvim-cmp adapter's completion items) on it.
---@return integer
function M.generation()
    return generation
end

return M
