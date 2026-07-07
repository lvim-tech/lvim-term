-- lvim-term: the live configuration table.
-- Holds the defaults; setup() merges user overrides into it IN PLACE (via
-- lvim-utils.utils.merge), so every require("lvim-term.config") reader sees the effective values.
--
-- lvim-term owns PERSISTENT, named, toggleable terminals — distinct from lvim-shell (one-shot
-- TUI-app launchers with a result callback). A terminal here is a long-lived shell kept alive
-- while hidden, toggled in/out, switched between, and SENT commands.
--
---@module "lvim-term.config"

---@class LvimTermForceSlot  Per-layout ANCHORED geometry override, deep-merged PER FIELD over the
--- global `lvim-utils.config.dock.geometry.<layout>`. Empty {} = inherit the global unchanged.
---@field height?      number       height override — ≤ 1 = a fraction of the editor, > 1 = absolute rows
---@field height_auto? boolean      true → `height` is the MAX (content-fit up to it); false → EXACT/fixed
---@field width?       number       FLOAT ONLY width — ≤ 1 = fraction, > 1 = absolute cols (area/bottom ignore it)
---@field width_auto?  boolean      FLOAT ONLY (area/bottom ignore it)
---@field backdrop?    table|false  backdrop override ({ enabled, mode, dim = { amount }, darken = { amount } }; false = none)
---@field auto_hide?   boolean      close the surface when a file is opened from the dock
---@field keep_focus?  boolean      keep focus in the dock after opening a file from it

---@class LvimTermForce
---@field float  LvimTermForceSlot  float-layout geometry override (may include width / width_auto)
---@field area   LvimTermForceSlot  area-layout geometry override (always full-width — no width)
---@field bottom LvimTermForceSlot  bottom-layout geometry override (always full-width — no width)

---@class LvimTermDock  Dock integration, namespaced under `config.dock.*` (uniform with lvim-dependencies).
---@field dock_stack boolean         Join the shared dock STACK (managed) vs open standalone (geometry-only)
---@field force      LvimTermForce   Per-layout ANCHORED geometry overrides (empty {} = inherit the global)

---@class LvimTermConfig
---@field layout         "float"|"area"|"bottom"  Default layout a terminal shows in
---@field title          string                   The frame's border-title text (default "terminal")
---@field title_pos      "left"|"center"|"right"  Border-title alignment (default "center")
---@field dock           LvimTermDock             Dock integration (dock_stack + per-layout force overrides)
---@field shell          string?                  Command to run (nil = &shell)
---@field start_in_insert boolean                 Enter insert mode when a terminal is shown
---@field cwd            "file"|"cwd"|fun(): string  New-terminal working directory
---@field close_on_exit  boolean                  Close the window when the shell exits (else keep the exited buffer)
---@field tabs           boolean                  Show the terminal tab bar (one button per terminal) in the frame's header band
---@field keys           table                    Buffer-local normal-mode keys inside a terminal: next / prev / new / move tabs + close
---@field icons          table                    Nerd Font glyphs (terminal / running / exited / new-tab / separators)

---@type LvimTermConfig
return {
    -- Where a terminal shows. Bottom dock is the familiar "drop-down terminal" default. The SIZE of
    -- each layout (bottom rows, float fractions) + the backdrop live centrally in
    -- lvim-utils.config.dock.geometry — resolved via `require("lvim-utils.dock").slot(layout)` — so
    -- lvim-term keeps no size of its own (every dock consumer shares the one geometry authority).
    layout = "area",
    -- The frame's border-title: its TEXT and alignment ("left" | "center" | "right"). The fronting
    -- glyph is `icons.terminal`. Centered by default (as the other lvim-tech panels).
    title = "terminal",
    title_pos = "center",
    -- Dock integration, namespaced under `dock.*` (uniform with lvim-dependencies' `config.dock`).
    dock = {
        -- true = full dock-STACK consumer (managed: cyclable <Leader>n/p/x/m, :LvimDock,
        -- one-visible-per-layout, no overlap); false = geometry-only (central dock.slot size/
        -- backdrop, opens standalone, NOT in the stack).
        dock_stack = true,
        -- Per-plugin per-layout ANCHORED geometry overrides, deep-merged per field OVER the global
        -- `lvim-utils.config.dock.geometry.<layout>`; empty {} = inherit the global unchanged. Each
        -- layout may carry: height, height_auto, backdrop = { enabled, mode, dim = { amount },
        -- darken = { amount } }, auto_hide, keep_focus. FLOAT ALSO: width, width_auto. area/bottom
        -- are ALWAYS full-width — NO width/width_auto (ignored if set).
        force = { float = {}, area = {}, bottom = {} },
    },
    -- The program each terminal runs. nil = the user's &shell.
    shell = nil,
    -- Enter terminal-insert mode when a terminal is shown (drop-down feel). The last mode is
    -- remembered per terminal on hide.
    start_in_insert = true,
    -- Working directory for a NEW terminal:
    --   "file" — the current file's directory (falls back to cwd when unnamed),
    --   "cwd"  — Neovim's cwd,
    --   function -> dir — a custom resolver (e.g. the project root).
    cwd = "file",
    -- When the shell process exits, close its window (true) or keep the exited buffer visible so
    -- you can read the final output (false).
    close_on_exit = false,
    -- Show the terminal TAB BAR (one button per terminal, active one highlighted, a per-tab kill
    -- glyph, a `+` new-tab button) as the frame's header band — the betterTerm-style tabs on the
    -- lvim-ui surface chassis (overflow chevrons come free from its ui.bar).
    tabs = true,
    -- Buffer-local keys inside a terminal — ALL bound in NORMAL mode ONLY (reach it with the native
    -- `<C-\><C-n>` gateway): in terminal-insert the running PROGRAM owns every key (a vim / fzf /
    -- lazygit / REPL inside the terminal legitimately uses the Alt chords, `q` and `<Esc>`), so no
    -- key is ever intercepted there. `close` parks the terminal through the dock — the same
    -- collapse/park as a `:LvimTerm` toggle-off. A full KILL of every terminal stays on the dock's
    -- `<Leader>x`.
    keys = {
        next = "<A-l>", -- next terminal tab
        prev = "<A-h>", -- previous terminal tab
        new = "<A-n>", -- new terminal
        move_next = "<A-j>", -- move the current tab forward / right (rearrange)
        move_prev = "<A-k>", -- move the current tab back / left (rearrange)
        kill = "<A-x>", -- (normal mode) KILL the current terminal (confirm if running)
        close = "q", -- (normal mode) park the terminal via the dock — collapse, keep it cyclable
    },
    -- Single-width Nerd Font glyphs (real literal glyphs; override with your own).
    icons = {
        terminal = "", -- a terminal (window title / tab)
        running = "", -- a live shell (tab / chooser)
        exited = "", -- a dead shell (tab / chooser)
        new = "", -- the "+" new-tab button
        kill = "", -- the per-tab close button
    },
}
