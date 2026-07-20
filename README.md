# lvim-snippets

The snippet engine of the **lvim-tech** set. Collections in **three formats** — VS Code JSON, SnipMate
and LuaSnip syntax — behind one neutral engine: discovery by file extension under fully configurable roots
(recursive, nested subfolders welcome), lazy parsing per filetype, and format **priority** you control.
It plugs into [lvim-cmp](https://github.com/lvim-tech/lvim-cmp) as a completion source through the
public `register_source` API (no wiring — `setup()` does it), and ships the `:LvimSnippets` picker:
the current buffer's snippets in the canonical lvim-ui panel with a live body preview,
insert-at-the-cursor on confirm.

## Highlights

- **Three formats, one engine** — discovered by file **extension** in every folder you configure (and
  their nested subfolders):

  | Format | Files | Expansion |
  | --- | --- | --- |
  | **VS Code** | a `package.json` manifest (`contributes.snippets`), or loose `<ft>.json` | native `vim.snippet` |
  | **SnipMate** | loose `<ft>.snippets` (parsed here — no dependency) | native `vim.snippet` |
  | **LuaSnip syntax** | loose `<ft>.lua` | the plugin's own shim — no LuaSnip installation |

  `<ft>` is the filetype (`lua.json`, `python.snippets`, …); the language `all` applies everywhere. So
  `friendly-snippets` and any VS Code / SnipMate collection work directly — no snippet engine required.
- **Folders, not hardcoded** — `paths` is the list of roots to scan; the default is just
  `{ stdpath("config")/snippets }`, and setting your own **replaces** it (a clean array merge), so you
  decide exactly which folders are read. Each root is walked **recursively**: organise snippets into
  nested subfolders by type/purpose (`languages/lua.json`, `frameworks/web/react.snippets`,
  `custom/mine.lua`) — the directory names are yours; the **filename** sets the filetype. A directory
  with a `package.json` manifest is a self-contained VS Code collection (the manifest owns its layout).
- **Format priority** — `formats` lists the enabled formats **in priority order**: omit one to disable
  it, reorder to change which wins. The rank is a tiebreak — among snippets with an equal fuzzy score in
  lvim-cmp, the earlier-listed format ranks first.
- **A neutral public API** — the engine emits plain records (`prefix`, `body`, `description`, `ft`,
  `kind`, …), not completion items: `get(ft)`, `expand(record)`, `reset()`, `stats()` work with or
  without lvim-cmp.
- **Self-registering completion source** — when lvim-cmp is installed, `setup()` registers a
  `snippets` source through `require("lvim-cmp").register_source()` (prefix → label, body → snippet
  insert text; the format rank encodes into the sort text).
- **`:LvimSnippets`** — the current buffer's snippets in the canonical lvim-ui panel: column-aligned
  prefix + description rows, a live **body preview** beside the list (treesitter-highlighted by
  language), and on confirm the snippet expands at the cursor — tabstops jump as usual.

## Requirements

Requires **Neovim >= 0.11** (`vim.snippet`) and [lvim-utils](https://github.com/lvim-tech/lvim-utils).
[lvim-ui](https://github.com/lvim-tech/lvim-ui) is optional (the `:LvimSnippets` picker),
[lvim-cmp](https://github.com/lvim-tech/lvim-cmp) is optional (completion)
(only for `.lua` snippet files — VS Code / SnipMate need nothing).

## Installation

### lvim-installer (recommended)

Open the **Plugins** tab and install / update / pin it:

```vim
:LvimInstaller plugins
```

### Native (vim.pack)

```lua
vim.pack.add({
    { src = "https://github.com/lvim-tech/lvim-utils" },
    { src = "https://github.com/lvim-tech/lvim-ui" },
    { src = "https://github.com/lvim-tech/lvim-snippets" },
})
require("lvim-snippets").setup({})
```

Call `setup()` **after** lvim-cmp is available so the source registration lands (any order works for
the engine and the picker themselves).

## Usage

### Completion (through lvim-cmp)

Nothing to do — with lvim-cmp installed, `setup()` registers the `snippets` source and your snippets
complete as you type, ranked with everything else. Accepting expands the snippet (`vim.snippet`, or
`<Tab>` / `<S-Tab>` jump the tabstops (lvim-cmp's keys).

### The picker

```vim
:LvimSnippets                 " float (the default); a layout token is accepted anywhere
:LvimSnippets area            " the minibuffer / cmdline zone
:LvimSnippets bottom          " a bottom dock
```

Lists the current buffer's snippets (its filetype + `all`): `j`/`k` move (the body preview follows),
`<C-l>`/`<C-h>` and `<Tab>` reach/toggle the preview panel, `<CR>` inserts the focused snippet at the
cursor and enters its first tabstop, `q`/`<Esc>` close. A layout token given on the command is sticky
for the session; `picker.layout` is the cross-session default.

### The API

```lua
local snippets = require("lvim-snippets")

snippets.get("lua") -- ranked neutral records for a filetype:
-- { prefix, body, description?, name?, ft, kind, rank, docstring?, expand? }
snippets.expand(record) -- expand a record at the cursor (the plugin's own session engine)
snippets.reset() -- drop the discovery + parse caches (new files on disk)
snippets.stats() -- per-format counts, broken files
```

## Configuration

`setup()` merges your options into the live config in place — every reader
(`require("lvim-snippets.config")`) sees the effective values. The full default config:

```lua
require("lvim-snippets").setup({
    -- snippet collection ROOTS (each walked recursively). Setting your own REPLACES the
    -- default (a clean array merge) — you control exactly which folders are scanned.
    paths = { vim.fn.stdpath("config") .. "/snippets" },
    -- enabled formats in PRIORITY order: "vscode" | "snipmate" | "luasnip". Omit one to
    -- disable it; earlier = higher priority (the equal-fuzzy tiebreak in lvim-cmp).
    formats = { "vscode", "snipmate", "luasnip" },
    cmp = {
        enabled = true, -- register the "snippets" source into lvim-cmp on setup()
        priority = 80, -- the source's merge rank among lvim-cmp sources
        min_keyword_length = 1, -- per-source keyword floor inside lvim-cmp
    },
    picker = {
        layout = "float", -- :LvimSnippets default: "float" | "area" | "bottom"
        preview = true, -- show the body preview panel beside the list
        preview_side = "right", -- initial preview placement: "right" | "left" | "above" | "below"
    },
})
```

```lua
-- example: your own roots, .lua collections win ties, SnipMate disabled
require("lvim-snippets").setup({
    paths = { vim.fn.stdpath("config") .. "/snippets", "~/dev/snippets" },
    formats = { "luasnip", "vscode" },
})
```

## Health

`:checkhealth lvim-snippets` reports the runtime requirement, the shared dependencies, the discovered
collections (per-format file counts and the active priority order), unparsable files, whether the
source registered into
lvim-cmp, and validates the live config.

## License

BSD 3-Clause — see [LICENSE](LICENSE).
