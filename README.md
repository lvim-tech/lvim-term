# lvim-term

Persistent, named, toggleable terminals for the **lvim-tech** set — a drop-down terminal with a
**betterTerm-style tab bar**. Distinct from
[lvim-shell](https://github.com/lvim-tech/lvim-shell) (one-shot TUI-app launchers with a result
callback): here a terminal is a long-lived shell kept alive while hidden, toggled in/out, switched
via a clickable tab bar, and **sent** commands (the builds / REPL workflow).

[![License: BSD-3-Clause](https://img.shields.io/badge/License-BSD--3--Clause-blue.svg)](https://github.com/lvim-tech/lvim-term/blob/main/LICENSE)

## Requirements

Requires **Neovim >= 0.10** and [lvim-utils](https://github.com/lvim-tech/lvim-utils) (palette +
theming). Optional integrations, both degrading gracefully when absent:
[lvim-ui](https://github.com/lvim-tech/lvim-ui) powers the `kill` confirm and the `select` chooser
(the tabs still work without it); [lvim-msgarea](https://github.com/lvim-tech/lvim-msgarea) hosts
the `area` layout in its message-area zone (without it, `area` falls back to the bottom dock).

## Installation

### lvim-installer (recommended)

```vim
:LvimInstaller plugins
```

lvim-installer installs plugins through Neovim's built-in `vim.pack`, so no external plugin manager
is needed.

### Native (vim.pack)

```lua
vim.pack.add({
    { src = "https://github.com/lvim-tech/lvim-utils" },
    { src = "https://github.com/lvim-tech/lvim-term" },
})
require("lvim-term").setup({})
```

## Usage

```vim
:LvimTerm                       " toggle the current terminal
:LvimTerm new                   " spawn another (or: :LvimTerm new name=build)
:LvimTerm next | prev           " switch tabs
:LvimTerm select                " pick a terminal (lvim-ui chooser)
:LvimTerm kill                  " close the current terminal (confirm if running)
:LvimTerm <sub> float|area|bottom  " a layout token anywhere in the args
```

The display goes through the canonical **lvim-ui `tabs` presenter** (the exact call shape
lvim-control-center uses), in its provider-tab mode: **one tab per terminal**, each tab's provider
showing that terminal's buffer in the shared content panel. The frame is a `terminal` title → the
**tab bar** (with `tabs = true`: the active tab highlighted, an exited one red, a per-tab `×` to kill
that terminal, a trailing `+` to spawn a new one) → the **terminal itself** → a **footer** of key
chips. The chassis navigation comes inherited, not hand-rolled: `<C-j>` / `<C-k>` walk tab bar ·
terminal · footer (and `<C-k>` off the top returns to the editor on a docked layout), `h` / `l` on
the focused tab bar switch terminals live, `<CR>` fires the selected bar button, and overflowing
bars mark their hidden items with `❮ ❯` chevrons. The footer's **`help` chip** (`g?`, in terminal-NORMAL
mode) opens the keymap CHEATSHEET — every key in `keys` below, built from the live config, so a rebind shows
up in it. Geometry, borders and the backdrop all come from
the chassis (the central `lvim-utils.config.dock.geometry` slot) — lvim-term hand-rolls no window of
its own.

**App-safe key model.** In **terminal-INSERT the running program owns EVERY key** — a `vim` / `lazygit`
/ `vifm` / `htop` inside the terminal keeps `<Esc>` / `q` / `<Leader>` / its own `<A-…>` chords, with
**zero interceptions** from the plugin. The single, native way out is **`<C-\><C-n>`** (which no
program uses), which drops to **terminal-NORMAL**. There the plugin's keys apply: the tab keys
**`<A-l>`** next · **`<A-h>`** prev · **`<A-n>`** new · **`<A-x>`** kill the current terminal
(confirm while running) · **`<A-j>`** / **`<A-k>`** move the current tab;
**`q`** or **`<Esc>`** PARK the terminal through the shared dock (the layout collapses cleanly, the
terminal stays cyclable, nothing stale is left behind — the same as a `:LvimTerm` toggle-off); and the
dock's **`<Leader>n`** / **`<Leader>p`** cycle, **`<Leader>x`** kills every terminal, **`<Leader>m`** is
the dock menu. (`C-c` at a shell prompt is the shell's own SIGINT — it is **not** a close path, so it
never drops the terminal from the dock.)

```lua
local term = require("lvim-term")

term.toggle() -- drop-down toggle
term.new({ name = "build" }) -- named terminal
term.next() -- next tab
term.prev() -- previous tab

-- send into a terminal (builds / REPLs):
term.send("make", nil, { interrupt = true, show = true }) -- Ctrl-C first, then reveal
term.send_file("python") -- run the current file
term.send_selection(nil, { show = true }) -- run the visual selection
```

## Adopting another plugin's terminal

```lua
-- Adopt a live terminal buffer this plugin did NOT spawn — e.g. a running lvim-tasks task's output —
-- as a terminal TAB. That is what makes such an output INTERACTIVE: insert mode types straight into the
-- running program (a watch-mode test runner waiting for a keypress, a REPL, anything reading stdin).
-- lvim-term only VIEWS it: the owner keeps the buffer and the job, closing the tab merely DETACHES it,
-- and it is never respawned.
require("lvim-term").adopt({ bufnr = task.bufnr, job_id = task.job_id, name = "npm test" })
```

In lvim-tasks this is bound to `t` in the task panel (or the `terminal` footer button).

## Layouts

Every layout's size + backdrop come from the ONE central geometry authority
(`lvim-utils.config.dock.geometry.<layout>`, resolved via `require("lvim-utils.dock").slot(layout)`)
— lvim-term keeps no size of its own. Override a layout for this plugin only with
`dock.force.<layout>` (deep-merged per field over the global; empty `{}` = inherit).

- **`bottom`** — a real split docked at the bottom (the drop-down default), full-width.
- **`float`** — a centred modal float (the only layout that also takes `dock.force.float.width` /
  `width_auto`).
- **`area`** — docks the terminal **in the lvim-msgarea zone** (the message-area / minibuffer space
  at the screen bottom) via msgarea's shared `host_window` primitive: the **zone owns the height**
  (the shared control-center `ui.size.area.height` setting) and keeps the terminal in place as the
  zone reflows — lvim-term never computes area geometry itself. When lvim-msgarea is absent or its
  zone is disabled, `area` falls back to the bottom dock.

The three layouts are **independent**: the shared dock keys every entry by `(id, layout)`, so the
terminal can be docked in **float, bottom and area at the same time** — three parallel display
windows, one dock entry in each stack, all showing the shared current-terminal buffer.
`:LvimTerm float` and `:LvimTerm bottom` open two separate windows; each toggles on/off on its own.
Re-issuing a layout that is already open just re-shows that one entry (never a duplicate). `q` /
`<Esc>` parks **only the window it was pressed in** (the terminal stays visible in the other
layouts); `<Leader>x` kills every terminal and tears down all of its display windows at once.

## Default configuration

```lua
require("lvim-term").setup({
    layout = "area", -- "float" | "area" | "bottom"
    title = "terminal", -- the border-title text
    title_pos = "center", -- "left" | "center" | "right"
    -- Dock integration, namespaced under `dock.*` (uniform with lvim-dependencies' `config.dock`).
    dock = {
        -- true = full dock-STACK consumer (managed: cyclable <Leader>n/p/x/m, :LvimDock, one-visible-
        -- per-layout, no overlap); false = geometry-only (central size/backdrop, opens standalone,
        -- NOT in the stack).
        dock_stack = true,
        -- Per-layout ANCHORED geometry overrides, deep-merged PER FIELD over the global
        -- lvim-utils.config.dock.geometry.<layout>; empty {} = inherit the global unchanged. Each layout
        -- may carry: height, height_auto, backdrop = { enabled, mode, dim = { amount },
        -- darken = { amount } }, auto_hide, keep_focus. float ALSO: width, width_auto. area/bottom are
        -- always full-width (no width / width_auto).
        force = { float = {}, area = {}, bottom = {} },
    },
    shell = nil, -- command to run (nil = &shell)
    start_in_insert = true, -- enter terminal-insert when shown
    cwd = "file", -- "file" | "cwd" | function() -> dir
    close_on_exit = false, -- keep the exited buffer (true = close the window)
    tabs = true, -- show the tab bar (one button per terminal; false hides the bar, the keys still switch)
    keys = { -- buffer-local keys inside a terminal — ALL normal-mode only
        help = "g?", -- the keymap CHEATSHEET (also a `help` chip on the footer bar)
        next = "<A-l>", -- next terminal tab
        prev = "<A-h>", -- previous terminal tab
        new = "<A-n>", -- new terminal
        move_next = "<A-j>", -- move the current tab right (rearrange)
        move_prev = "<A-k>", -- move the current tab left (rearrange)
        kill = "<A-x>", -- KILL the current terminal (confirm if running)
        close = "q", -- park the terminal via the dock
    },
    icons = { -- single-width Nerd Font glyphs
        terminal = "",
        running = "",
        exited = "",
        new = "",
        kill = "",
    },
})
```

## Highlights

Self-themed from lvim-utils, overwritable by a colorscheme or your own `setup`. The title band, the
tab bar and the footer use the chassis' own `LvimUi*` groups; lvim-term adds only the groups the
chassis has no concept of — the terminal body and the red/green tab accents:

- `LvimTermNormal` — the terminal window body.
- `LvimTermTabExited` / `LvimTermTabExitedActive` — an exited terminal's tab (red).
- `LvimTermKill` / `LvimTermKillActive` — the per-tab `×` kill button (red block, deepens on hover).
- `LvimTermTabNew` / `LvimTermTabNewActive` — the `+` new-terminal button (green).

## Health

```vim
:checkhealth lvim-term
```

Reports the shell, the lvim-utils base, the optional lvim-ui and lvim-msgarea integrations, and a
single-width audit of the status glyphs.
