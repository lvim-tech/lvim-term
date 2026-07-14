-- lvim-term.ui: the terminal DISPLAY — one `lvim-ui` TABS frame per layout (the manager owns the
-- buffers). The frame goes through the canonical `ui.tabs` presenter in its PROVIDER-TAB mode, the
-- same call shape lvim-control-center uses — so lvim-term INHERITS the whole chassis navigation for
-- free: the tab bar (h/l on the focused bar switches live, overflow chevrons, per-tab `×` kill
-- affordances + a trailing `+`), sector walking (<C-j>/<C-k> header · center · footer), escape-up to
-- the editor on a docked layout, footer key-chips, and sizing from the central
-- `lvim-utils.config.dock.geometry` authority. Each TERMINAL is one PROVIDER TAB: its `update`
-- provider owns the shared content panel window and swaps THAT terminal's buffer in via
-- nvim_win_set_buf (the lsp-outline pattern) — switching tabs relayouts the chassis, which re-fires
-- the newly-active tab's `update` (the buffer swap). lvim-term hand-rolls NO window, band or bar.
--
-- A terminal is interactive (needs the real cursor + insert mode), so no tab provider sets
-- `hide_cursor`; the chassis' sector navigation (<C-j>/<C-k>) is re-bound on the terminal buffer in
-- NORMAL mode only (mirroring the picker's hosted-fzf terminal), so terminal-INSERT stays 100% the
-- running program's — the app-owns-keys invariant.
--
-- PROGRAMMATIC tab changes (the terminal's own <A-l>/<A-h>/<A-n>/<A-x>, an exit repaint, a tab move)
-- RECONCILE the frame: the tabset is re-derived from the manager and the frame is re-opened in place
-- (park + `ui.tabs` again, `tab_selector` on the target — synchronous, so it lands in one redraw).
-- That is the ONE seam ui.tabs currently exposes for driving/mutating provider tabs from outside;
-- when its handle grows `select_tab`/`set_tabs`, `reopen`/`realize` here are the single places to
-- switch to them (see findings).
--
-- lvim-term is a consumer of the shared DOCK-STACK manager (lvim-utils.dock), which keys every entry
-- by (id, LAYOUT): the stable id "lvim-term" is the base identity, and the SAME id opened in a
-- DIFFERENT layout is a SEPARATE entry in that other layout's stack. So the terminal can be docked in
-- float, bottom AND area SIMULTANEOUSLY — three live frames, one entry in each stack, all showing the
-- SHARED current-terminal buffer — while re-opening the SAME (id, layout) RE-SHOWS the one entry
-- (never a duplicate in that stack). That is why every piece of display state is PER LAYOUT
-- (`panels[layout]`, see `panel`): one frame / one dock KEY / one memoised consumer per layout.
-- `dock.open` RETURNS the entry key; each layout's slot STORES it and passes it back to the lifecycle
-- APIs (`parked`/`hide`) for THAT entry.
--
-- The `manager` (the terminals themselves) is SHARED across all layouts — only the DISPLAY frames are
-- per layout. The terminal's OWN inner tab keys (`<A-l>`/`<A-h>`) are a DIFFERENT axis — switching
-- TERMINALS within a display frame — and drive the SAME ui.tabs switch as the tab bar. The manager
-- owns visibility; this module owns the frames (it is the consumer's `show`/`hide`/`is_alive`
-- mechanism).
--
---@module "lvim-term.ui"

local api = vim.api
local config = require("lvim-term.config")
local manager = require("lvim-term.manager")
local lvim_ui = require("lvim-ui")
local surface = require("lvim-ui.surface") -- chassis key ids only (`surface.key`, the sector re-bind)

local M = {}

---@type string[]  the three coordinated layouts the terminal can be displayed in (independently)
local LAYOUTS = { "float", "area", "bottom" }

--- Per-LAYOUT display state. Because the dock keys every entry by (id, layout), the terminal can be
--- docked in float, bottom AND area at once — three live frames, one entry per stack — so every piece
--- of display state is PER LAYOUT, kept in `panels[layout]` (lazily created by `panel`).
---@class LvimTermPanel
---@field layout       "float"|"area"|"bottom"  which layout THIS slot displays (fixed for its lifetime)
---@field st           table?       the open FRAME STATE (nil when hidden) — captured through the provider
---                    `keys` hook; its `close`/`sector`/`panels`/`container_buf` drive park + the consumer
---@field handle       table?       the `ui.tabs` return handle (`valid`/`close`) for the same frame
---@field term_pan     table?       the shared content panel handle ({ buf = scratch, win = the display window })
---@field shown        integer?     the terminal id THIS frame currently displays (the active provider tab)
---@field tabsig       string?      fingerprint of the tabset the OPEN frame was built from (id/name/exited per
---                    terminal, in tab order) — a mismatch with the live manager means the frame is STALE and
---                    must be reconciled (re-opened) on the next show/refresh
---@field parking      boolean      true while we deliberately tear this layout's frame down (a park OR an
---                    in-place reconcile) — so the frame close does NOT re-notify the dock manager
---@field pending_term LvimTerminal?  the terminal the next `consumer.show` should realise (set in `M.show`)
---@field consumer     table?       memoised LvimDockConsumer for THIS layout (`id` = base identity, `layout` fixed)
---@field key          string?      the dock ENTRY KEY (id, layout) returned by `dock.open` — passed back to
---                    the lifecycle APIs (`parked`/`hide`) for THIS layout's entry

---@type table<string, LvimTermPanel>  layout → its per-layout display state (each an independent live entry)
local panels = {}

--- Lazily create + return the per-layout display slot for `layout`.
---@param layout string  "float" | "area" | "bottom"
---@return LvimTermPanel
local function panel(layout)
    local p = panels[layout]
    if not p then
        p = { layout = layout, parking = false }
        panels[layout] = p
    end
    return p
end

--- Whether slot `p` currently has an open frame with a valid display window.
---@param p LvimTermPanel?
---@return boolean
local function shown(p)
    return p ~= nil
        and p.st ~= nil
        and p.term_pan ~= nil
        and p.term_pan.win ~= nil
        and api.nvim_win_is_valid(p.term_pan.win)
end

--- The display slot whose TERMINAL window is the CURRENT window (a key was pressed inside it), or nil.
---@return LvimTermPanel?
local function current_panel()
    local cur = api.nvim_get_current_win()
    for _, name in ipairs(LAYOUTS) do
        local p = panels[name]
        if shown(p) and p.term_pan.win == cur then
            return p
        end
    end
    return nil
end

---@type table|false|nil  cached lvim-utils.dock module (nil = unprobed, false = probed & absent)
local dock_mod = nil
--- The dock-stack manager, or nil if unavailable (then lvim-term opens standalone, un-managed).
---@return table?
local function get_dock()
    if dock_mod == nil then
        local ok, m = pcall(require, "lvim-utils.dock")
        dock_mod = ok and m or false
    end
    return dock_mod or nil
end

--- Notify the dock manager that slot `p`'s frame was dismissed by the USER destroying it DIRECTLY (an
--- external `:q` / `<C-w>c` on any frame window, or the chassis close keys on the chrome) — NOT a
--- manager-driven park. This MIRRORS the lvim-picker consumer's self-dismiss: route it through
--- `dock.parked` (by THIS layout's stored KEY) so the layout COLLAPSES and the entry STAYS on its
--- stack. The terminal BUFFERS survive (bufhidden = "hide"), so `is_alive` stays true → the entry
--- remains cyclable (`<Leader>n`/`<Leader>p`) and re-toggleable, exactly like a parked picker.
--- Crucially it does NOT reveal the LIFO-next consumer (what `dock.closed` would do). The frame is
--- already gone at every call site, so `dock.parked` fixes bookkeeping ONLY — it must NOT re-call the
--- consumer's `hide`. Guarded by `p.parking` at the call site so a manager park never re-notifies.
--- No-op without a key (standalone) — nothing to notify.
---@param p LvimTermPanel
local function notify_parked(p)
    local d = get_dock()
    if d and p.key then
        pcall(d.parked, p.key)
    end
end

--- Whether ANY display frame is open — or, with `layout`, that specific layout's frame.
---@param layout ("float"|"area"|"bottom")?
---@return boolean
function M.is_shown(layout)
    if layout then
        return shown(panels[layout])
    end
    for _, name in ipairs(LAYOUTS) do
        if shown(panels[name]) then
            return true
        end
    end
    return false
end

--- Normalise a chassis key value (string | list | nil) to a list of lhs strings.
---@param v string|string[]|nil
---@return string[]
local function keylist(v)
    if type(v) == "table" then
        return v
    end
    if type(v) == "string" and v ~= "" then
        return { v }
    end
    return {}
end

--- Bind the buffer-local keys on a terminal buffer, once. All NORMAL-mode ONLY (reached via the
--- native `<C-\><C-n>` gateway): in terminal-INSERT the running PROGRAM owns EVERY key — a vim /
--- lazygit / vifm / htop inside legitimately uses the Alt chords / `q` / `<Esc>` — so binding them in
--- `t` would STEAL them from the app. The clean, app-safe seam is normal-mode; the app keeps
--- terminal-insert entirely (zero interceptions there). The dock's own `<Leader>n/p/x/m` likewise
--- only apply in terminal-normal via the dock leader owner.
---
local show_help -- forward decl (bind_keys binds it before the window that opens it is defined)

--- Bound keys: the tab keys (next / prev / new / move — all landing in the ui.tabs reconcile, so the
--- tab bar and the shown terminal move together), the PARK keys (`config.keys.close` + `<Esc>`, both
--- routing through `M.hide` for the CURRENT window's layout only — the same collapse/park as a
--- `:LvimTerm` toggle-off; a real KILL of every terminal stays on the dock's `<Leader>x`), and the
--- chassis SECTOR keys (`sector_next`/`sector_prev`, read from the surface so they track its config):
--- the chassis binds those on its own scratch buffer, so a hosted terminal re-binds them on ITS
--- buffer (the picker's hosted-fzf pattern) — that is how `<C-j>`/`<C-k>` walk the tab bar · terminal
--- · footer from the terminal without ever touching terminal-insert (and how <C-k> off the top
--- escapes up to the editor on a docked layout, via the ui.tabs `on_escape_above`).
---@param buf integer
local function bind_keys(buf)
    if vim.b[buf].lvim_term_bound then
        return
    end
    vim.b[buf].lvim_term_bound = true
    local k = config.keys or {}
    local map = function(lhs, fn)
        if lhs and lhs ~= "" then
            vim.keymap.set("n", lhs, fn, { buffer = buf, silent = true })
        end
    end
    map(k.next, function()
        M.cycle(1)
    end)
    map(k.prev, function()
        M.cycle(-1)
    end)
    map(k.new, function()
        vim.schedule(function()
            local p = current_panel()
            M.show(manager.spawn().id, p and p.layout)
        end)
    end)
    map(k.move_next, function()
        M.move_tab(1)
    end)
    map(k.move_prev, function()
        M.move_tab(-1)
    end)
    map(k.kill, function()
        require("lvim-term").kill() -- KILL the current terminal (init's confirm flow); circular → inline
    end)
    map(k.help, show_help)
    -- The terminal buffer is HOSTED (swapped into the chassis panel window), so the chassis never maps it and
    -- cannot own the prefix of a chord bound here. `surface.own_chords` is the shared seam that does: without
    -- it a `g?` typed at human speed falls through to the builtin `g` once `timeoutlen` expires.
    surface.own_chords(buf, { k.help })
    for _, lhs in ipairs({ k.close, "<Esc>" }) do
        if lhs and lhs ~= "" then
            vim.keymap.set("n", lhs, function()
                local p = current_panel()
                M.hide(p and p.layout)
            end, {
                buffer = buf,
                silent = true,
                desc = "lvim-term: park this layout's terminal frame via the dock (collapse, keep cyclable)",
            })
        end
    end
    -- Chassis sector navigation, re-bound on the terminal buffer (see the doc block above). The slot
    -- (and so the frame) is resolved from the CURRENT window at press time — the terminal buffer is
    -- SHARED across the per-layout frames, so the binding cannot capture one frame handle.
    for _, sk in ipairs({ { "sector_next", 1 }, { "sector_prev", -1 } }) do
        local dir = sk[2]
        for _, lhs in ipairs(keylist(surface.key(sk[1]))) do
            vim.keymap.set("n", lhs, function()
                local p = current_panel()
                if p and p.st and p.st.sector then
                    p.st.sector(dir)
                end
            end, { buffer = buf, silent = true })
        end
    end
end

--- Put `term`'s buffer into slot `p`'s content panel window (the tab-switch buffer swap) and re-assert
--- the window chrome. The tab's `update` provider owns pan.win, so this is the ONE place the displayed
--- buffer changes; it never focuses (focus is a separate, explicit step — `update` also re-fires on
--- every chassis relayout/resize and must not steal the cursor then).
---@param p LvimTermPanel
---@param pan table  the content panel handle
---@param term LvimTerminal
local function show_term_in(p, pan, term)
    if not (pan.win and api.nvim_win_is_valid(pan.win)) then
        return
    end
    local buf = term and term.bufnr
    if not (buf and api.nvim_buf_is_valid(buf)) then
        return
    end
    bind_keys(buf)
    -- Name the buffer's filetype so ft-scoped rules (user autocmds, the cursor module's lists) can
    -- target it. NOT registered for cursor hiding — a terminal needs its real cursor.
    if vim.bo[buf].filetype == "" then
        vim.bo[buf].filetype = "lvim-term"
    end
    if api.nvim_win_get_buf(pan.win) ~= buf then
        api.nvim_win_set_buf(pan.win, buf)
    end
    -- Re-assert per swap: TermOpen / a user's window autocmds may re-apply gutter chrome over the
    -- panel's minimal style, and the winhighlight must carry the terminal body group.
    vim.wo[pan.win].winhighlight = "Normal:LvimTermNormal,NormalNC:LvimTermNormal,FloatBorder:LvimUiPeekBorder"
    vim.wo[pan.win].number = false
    vim.wo[pan.win].relativenumber = false
    vim.wo[pan.win].signcolumn = "no"
    p.shown = term.id
    manager.set_current(term.id)
end

--- Focus slot `p`'s terminal window; with `insert`, enter terminal-insert per `config.start_in_insert`
--- (the drop-down feel) — never for an exited shell (its buffer is read-only output).
---@param p LvimTermPanel
---@param insert boolean
local function focus_term(p, insert)
    local pan = p.term_pan
    if not (pan and pan.win and api.nvim_win_is_valid(pan.win)) then
        return
    end
    api.nvim_set_current_win(pan.win)
    local term = p.shown and manager.get(p.shown)
    if insert and config.start_in_insert and term and not term.exited then
        vim.cmd("startinsert")
    end
end

-- Per-button box-style OVERRIDES merged over the chassis `tab` / `plain` kinds (ui.tabs' shared
-- button mapper): an EXITED tab swaps the blue tab accent for the red "dead" accent in every state
-- (a per-tab `hl` box override riding the tab spec); the per-tab kill glyph and the `+` new button
-- carry their own red / green accents on their affordance records. Named groups (highlights.lua),
-- so they re-derive from the live palette on ColorScheme.
local EXITED_BOX = {
    icon = { normal = "LvimTermTabExited", active = "LvimTermTabExitedActive", hover = "LvimTermTabExitedActive" },
    text = { normal = "LvimTermTabExited", active = "LvimTermTabExitedActive", hover = "LvimTermTabExitedActive" },
}
local KILL_BOX = {
    text = {
        padding = { 1, 1 }, -- a space each side, so the red block reads as a padded button
        normal = "LvimTermKill",
        active = "LvimTermKillActive",
        hover = "LvimTermKillActive",
    },
}
local NEW_BOX = {
    text = {
        padding = { 1, 1 },
        normal = "LvimTermTabNew",
        active = "LvimTermTabNewActive",
        hover = "LvimTermTabNewActive",
    },
}

--- Fingerprint of the LIVE tabset (id / name / exited per terminal, in tab order). Stored on the slot
--- at open (`p.tabsig`); a mismatch with the live manager means the OPEN frame's tab bar is stale
--- (spawn / kill / exit / rename / reorder) and the frame must be reconciled.
---@return string
local function tabsig()
    local parts = {}
    for _, t in ipairs(manager.all()) do
        parts[#parts + 1] = ("%d:%s:%s"):format(t.id, t.name, t.exited and "x" or "r")
    end
    return table.concat(parts, "|")
end

--- 1-based tab index of terminal `id` in the tab order (the `ui.tabs` `tab_selector`).
---@param id integer
---@return integer
local function term_index(id)
    for i, t in ipairs(manager.all()) do
        if t.id == id then
            return i
        end
    end
    return 1
end

--- The PROVIDER for ONE tab of slot `p`'s frame — terminal `tid`'s. An `update` provider OWNS the
--- shared content panel window (the chassis writes no lines for it): `update(pan)` records the panel
--- handle and swaps THIS tab's terminal buffer into `pan.win`. The ui.tabs delegate forwards `update`
--- to the ACTIVE tab only and re-fires it on every tab switch / relayout / resize, so the swap is the
--- switch — idempotent per call. NO `hide_cursor` — the terminal must show its real cursor; the
--- shared scratch panel buffer carries the `lvim-term` filetype for ft rules.
---@param p LvimTermPanel
---@param tid integer
---@return table  the surface content provider for this tab
local function term_provider(p, tid)
    return {
        filetype = "lvim-term",
        --- Content-size hint, used only when an axis resolves to AUTO sizing (the central dock
        --- geometry normally fixes both axes).
        ---@return integer width, integer height
        size = function()
            return math.max(40, math.floor(vim.o.columns * 0.8)), 15
        end,
        --- Realise THIS tab's terminal in the (re)laid-out shared panel window.
        ---@param pan table
        update = function(pan)
            p.term_pan = pan
            local term = manager.get(tid)
            if term then
                show_term_in(p, pan, term)
            end
        end,
        --- Fired ONCE at open (chassis key wiring), for the initially-active tab: capture the panel +
        --- FRAME STATE as early as the chassis wires keys, so the affordance/footer `run` closures and
        --- the consumer (`buffers`, `sector`) can reach the live frame during the open itself.
        ---@param _ fun(lhs: string|string[], fn: fun())
        ---@param pan table
        ---@param st table
        keys = function(_, pan, st)
            p.term_pan = pan
            p.st = st
        end,
    }
end

-- ── the help window (the canonical cheatsheet) ───────────────────────────────

-- Key id → description, in display order. Built from the LIVE `config.keys` (an unset key drops its row).
---@type { [1]: string, [2]: string }[]
local HELP = {
    { "next", "next terminal tab" },
    { "prev", "previous terminal tab" },
    { "new", "new terminal" },
    { "move_next", "move this tab forward" },
    { "move_prev", "move this tab back" },
    { "kill", "KILL this terminal (confirm if running)" },
    { "close", "park the terminal (collapse, keep it cyclable)" },
    { "help", "this help" },
}

--- The terminal panel's keymap cheatsheet — the shared `lvim-ui.help` component owns the rows, the striping,
--- the colours and the window; this only supplies the plugin's LIVE keys. Every key it lists is a
--- terminal-NORMAL key (`<C-\><C-n>` first): in terminal-insert the running program owns the keyboard.
function show_help()
    local k = config.keys or {}
    local items = {}
    for _, e in ipairs(HELP) do
        local lhs = k[e[1]]
        if lhs and lhs ~= "" then
            items[#items + 1] = { lhs, e[2] }
        end
    end
    require("lvim-ui").help({
        title = "Terminal keymaps",
        items = items,
        close_keys = { "q", "<Esc>", k.help or "g?" },
    })
end

--- Build slot `p`'s footer chips (the `ui.tabs` `footer_hints` LIST form): the terminal's normal-mode
--- keys surfaced as clickable, label-only chips (`no_hotkey` — the real keymaps live buffer-local on
--- the terminal buffer, and registering multi-char labels would create mapping prefixes), grouped by
--- `●` dividers like the chassis' own key legend. The leading `^\ ^n` chip advertises the native
--- gateway into terminal-NORMAL (where all of these keys apply). Frame-mutating chips defer their
--- action: `run` fires from a chassis keymap inside the frame, and the reconcile tears that very
--- frame down mid-callback — the schedule moves it after the mapping completes (same ordering as the
--- buffer-local `new` binding).
---@param p LvimTermPanel
---@return table[]  footer_hints chip specs
local function footer_chips(p)
    local k = config.keys or {}
    local function lbl(s)
        return (type(s) == "string" and s or ""):gsub("[<>]", "")
    end
    local function sep()
        return { type = "separator", text = "●", style = { padding = { 1, 1 }, hl = "LvimUiFooterSep" } }
    end
    local function deferred(fn)
        return function()
            vim.schedule(fn)
        end
    end
    return {
        { key = [[^\ ^n]], label = "normal", no_hotkey = true, run = function() end },
        sep(),
        {
            key = lbl(k.prev),
            label = "prev",
            no_hotkey = true,
            run = deferred(function()
                M.cycle(-1, p.layout)
            end),
        },
        {
            key = lbl(k.next),
            label = "next",
            no_hotkey = true,
            run = deferred(function()
                M.cycle(1, p.layout)
            end),
        },
        sep(),
        {
            key = lbl(k.new),
            label = "new",
            no_hotkey = true,
            run = deferred(function()
                M.show(manager.spawn().id, p.layout)
            end),
        },
        {
            key = lbl(k.kill),
            label = "kill",
            no_hotkey = true,
            run = deferred(function()
                require("lvim-term").kill() -- the CURRENT terminal (init's confirm flow); circular → inline
            end),
        },
        sep(),
        {
            -- The terminal's normal-mode keys are not discoverable from the shell, so the bar says where the
            -- cheatsheet is (the real `g?` is bound on the terminal buffer by `bind_keys`).
            key = lbl(k.help),
            label = "help",
            no_hotkey = true,
            run = deferred(show_help),
        },
        {
            key = (lbl(k.close) ~= "" and lbl(k.close) or "q") .. "/Esc",
            label = "park",
            no_hotkey = true,
            run = deferred(function()
                M.hide(p.layout)
            end),
        },
    }
end

--- Open slot `p`'s `ui.tabs` frame showing `term`, in `p.layout` — the control-center call shape,
--- provider-tab mode. ONE provider tab per terminal (label = its name, icon = running/exited, the
--- exited red `hl` box, a per-tab `×` kill affordance) + a trailing `+` new-terminal bar action;
--- `tab_selector` lands on `term`'s tab, so its `update` provider realises that terminal in the
--- shared panel during the open. The chassis owns ALL geometry: `layout` maps float/bottom/area
--- (area auto-homes in the msgarea zone), and size + backdrop resolve from the central
--- `lvim-utils.config.dock.geometry.<layout>` with the per-plugin `config.dock.force[layout]`
--- anchored override threaded through as `slot` (its `backdrop` rides along inside — the same
--- threading as control-center). Frame teardown of ANY kind (chassis close keys, an external `:q`,
--- a park) lands in the shared per-open close handler through the providers' `on_close` (the
--- delegate fires every tab's — hence the once-guard), which clears the slot SYNCHRONOUSLY and
--- notifies the dock (`notify_parked`) unless this is a deliberate park/reconcile.
---@param p LvimTermPanel
---@param term LvimTerminal
local function open_tabs(p, term)
    local force = config.dock.force and config.dock.force[p.layout] or nil
    local tabs = {}
    for _, t in ipairs(manager.all()) do
        local tid = t.id
        tabs[#tabs + 1] = {
            label = t.name,
            icon = t.exited and config.icons.exited or config.icons.running,
            hl = t.exited and EXITED_BOX or nil,
            provider = term_provider(p, tid),
            -- The per-tab kill `×` companion button (fired by bar navigation <CR> / a click).
            actions = config.tabs and {
                {
                    name = config.icons.kill,
                    hl = KILL_BOX,
                    run = function()
                        -- init owns the kill flow (confirm dialog + display handoff) — circular, so inline.
                        require("lvim-term").kill(tid)
                    end,
                },
            } or nil,
        }
    end
    if #tabs == 0 then
        return
    end
    -- The shared close handler: the delegate calls EVERY tab provider's `on_close` at teardown, so a
    -- once-guard makes the slot cleanup + dock notification fire exactly once per open — and it fires
    -- SYNCHRONOUSLY inside the frame close (the ui.tabs `callback` is vim.schedule'd, which would race
    -- the `p.parking` guard around a deliberate park).
    local closed = false
    local function on_frame_close()
        if closed then
            return
        end
        closed = true
        p.st, p.handle, p.term_pan, p.shown, p.tabsig = nil, nil, nil, nil, nil
        if not p.parking then
            notify_parked(p)
        end
    end
    for _, t in ipairs(tabs) do
        t.provider.on_close = on_frame_close
    end
    -- `config.tabs = false` hides the tab BAR (the tabs themselves stay — switching still works via
    -- the terminal's own keys); nil = the ui.tabs auto (shown for >1 tab or any affordance).
    local tab_bar_opt
    if config.tabs == false then
        tab_bar_opt = false
    end
    p.tabsig = tabsig()
    p.handle = lvim_ui.tabs({
        title = { icon = config.icons.terminal, text = config.title },
        title_pos = config.title_pos, -- "left" | "center" | "right"
        layout = p.layout,
        -- No explicit size: it comes from the CENTRAL geometry authority (`dock.geometry.<layout>`),
        -- with `slot` = the per-plugin anchored override on top (empty {} = inherit the global).
        slot = force,
        tabs = tabs,
        tab_selector = term_index(term.id),
        tab_bar = tab_bar_opt,
        -- The trailing `+` new-terminal button at the end of the tab bar.
        tab_bar_actions = config.tabs and {
            {
                name = config.icons.new,
                hl = NEW_BOX,
                run = function()
                    -- Deferred: fired from a chassis keymap inside the frame the reconcile replaces.
                    vim.schedule(function()
                        M.show(manager.spawn().id, p.layout)
                    end)
                end,
            },
        } or nil,
        footer_hints = footer_chips(p),
    })
end

--- PARK slot `p`'s frame: tear it down through the chassis while KEEPING every terminal buffer alive
--- — the dock manager's "hide" (memory), and the first half of an in-place reconcile. `p.parking`
--- suppresses the frame close's self-dismiss notification so this never re-enters the manager (the
--- provider `on_close` runs synchronously inside `close`, so the guard window is exact). Idempotent
--- (no frame → no-op).
---@param p LvimTermPanel
local function park(p)
    p.parking = true
    local st = p.st or p.handle
    if st then
        pcall(st.close) -- fires the shared on_frame_close, which nils p.st / p.term_pan / p.shown / p.tabsig
    end
    p.parking = false
end

--- Whether the CURRENT window belongs to slot `p`'s open frame (the terminal panel, the container, or
--- any frame panel) — decides if a reconcile must hand focus back into the rebuilt terminal.
---@param p LvimTermPanel
---@return boolean
local function frame_focused(p)
    if not p.st then
        return false
    end
    local cur = api.nvim_get_current_win()
    if p.st.container_win == cur then
        return true
    end
    for _, pan in ipairs(p.st.panels or {}) do
        if pan.win == cur then
            return true
        end
    end
    return false
end

--- RECONCILE slot `p`'s open frame to the live manager state, keeping the user's focus where it was:
--- park (no dock notify — the entry stays) + re-open on `term`'s tab. Synchronous, so the swap lands
--- in one redraw. Focus: inside the frame before → back into the terminal (re-entering terminal-insert
--- only if the user was IN it — a background repaint must not change the mode); outside → restored to
--- the exact window (opening a frame moves focus into it).
---@param p LvimTermPanel
---@param term LvimTerminal
local function reopen(p, term)
    local prev_win = api.nvim_get_current_win()
    local inside = frame_focused(p)
    local in_insert = inside and api.nvim_get_mode().mode:sub(1, 1) == "t"
    park(p)
    open_tabs(p, term)
    if inside then
        focus_term(p, in_insert)
    elseif prev_win and api.nvim_win_is_valid(prev_win) then
        api.nvim_set_current_win(prev_win)
    end
end

--- Realise slot `p`'s pending terminal (a user-initiated show): with the frame open AND current (the
--- tabset fingerprint matches) AND already on that terminal, just focus it; with the frame open but
--- on another terminal / stale, reconcile it in place onto the target tab; otherwise open the frame.
--- Always ends focused in the terminal window, in insert per `config.start_in_insert` (the drop-down
--- feel).
---@param p LvimTermPanel
local function realize(p)
    local term = p.pending_term
    p.pending_term = nil
    if not (term and manager.get(term.id)) then
        local cur = manager.current()
        term = (cur and manager.get(cur)) or manager.spawn()
    end
    if shown(p) then
        if p.tabsig == tabsig() and p.shown == term.id then
            focus_term(p, true)
            return
        end
        park(p) -- an in-place reconcile: the dock entry stays, only the frame is rebuilt
    end
    open_tabs(p, term)
    focus_term(p, true)
end

--- Build (once, memoised in `panels[layout].consumer`) + return the dock consumer FOR ONE LAYOUT —
--- an `LvimDockConsumer` (the lvim-utils.dock contract; a cross-plugin type, annotated `table`). `id`
--- is the UNCHANGED base identity "lvim-term" — layout is NOT baked into it; the dock composes the
--- (id, layout) key. Because the terminal can be open in every layout at once, there is ONE consumer
--- PER layout, each with a fixed `layout` and each callback reading / writing THIS layout's slot `p`.
--- `show(ctx)` realises the pending terminal in THIS layout's frame (ctx.layout == the fixed layout —
--- the dock pushes it with the canonical slot rect; the frame re-reads the same authority itself);
--- `hide` PARKS the frame (keeps buffers); `close` (`<Leader>x`) KILLS every terminal (shared) and
--- tears down ALL layouts' frames; `is_alive` is true while any terminal exists; `buffers` returns
--- every terminal buffer PLUS this frame's chrome buffers (container + panel scratch) so the dock
--- leader owner covers the whole frame; `focus`/`is_current` read THIS slot's terminal window.
---@param layout string  "float" | "area" | "bottom"
---@return table  the LvimDockConsumer handle for this layout
local function get_consumer(layout)
    local p = panel(layout)
    if not p.consumer then
        p.consumer = {
            id = "lvim-term", -- base identity, UNCHANGED across layouts — the dock keys the entry by (id, layout)
            name = "terminal",
            icon = config.icons.terminal,
            layout = layout, -- which stack THIS entry joins (fixed for this per-layout consumer)
            ---@param _ table?  the dock show ctx ({ layout, reason, previous_id, rect }) — layout is fixed here
            show = function(_)
                realize(p)
            end,
            hide = function()
                park(p) -- PARK this layout's frame: keep every terminal buffer (restorable on the stack)
            end,
            close = function()
                -- `<Leader>x` on the terminal DOCK: KILL the whole terminal set — the terminals are SHARED
                -- across layouts, so this stops EVERY shell + deletes its buffer, then tears down EVERY
                -- layout's frame and DROPS their now-dead dock entries (the current layout's entry the dock
                -- removes itself after this returns). The inner per-tab `×` kills ONE terminal; this
                -- cross-consumer kill removes them all. Order matters: park the FRAMES FIRST (windows gone,
                -- buffers merely hidden), THEN delete the buffers — deleting a buffer still displayed in a
                -- frame float would yank that window out from under the live frame. `parking` guards every
                -- slot across the whole sequence so no teardown self-notifies the manager mid-close.
                for _, name in ipairs(LAYOUTS) do
                    if panels[name] then
                        panels[name].parking = true
                    end
                end
                local d = get_dock()
                for _, name in ipairs(LAYOUTS) do
                    local q = panels[name]
                    if q then
                        park(q) -- resets q.parking = false
                        if d and q ~= p and q.key then
                            pcall(d.dropped, q.key) -- drop the other layouts' now-dead entries (no reveal)
                        end
                    end
                end
                -- `manager.all()` is a snapshot, so killing (which mutates the order) while iterating is safe.
                for _, t in ipairs(manager.all()) do
                    manager.kill(t.id)
                end
            end,
            is_alive = function()
                return manager.count() > 0
            end,
            focus = function()
                focus_term(p, false)
            end,
            -- DESCEND from an outside editor window (the dock's global `<C-j>`): land on the frame's
            -- HEADER — the tab bar — so a further `<C-j>` steps down into the terminal (the mirror of the
            -- `<C-k>` escape-up). Falls back to focusing the terminal if the frame lacks the sector API.
            descend = function()
                if p.st and p.st.enter then
                    p.st.enter()
                else
                    focus_term(p, false)
                end
            end,
            buffers = function()
                local bufs = {}
                for _, t in ipairs(manager.all()) do
                    if t.bufnr and api.nvim_buf_is_valid(t.bufnr) then
                        bufs[#bufs + 1] = t.bufnr
                    end
                end
                -- The frame's chrome buffers (container + the content block's scratch), so the dock
                -- leader owner covers the bands too — not only the terminal buffers.
                if p.st then
                    if p.st.container_buf and api.nvim_buf_is_valid(p.st.container_buf) then
                        bufs[#bufs + 1] = p.st.container_buf
                    end
                    for _, pan in ipairs(p.st.panels or {}) do
                        if pan.buf and api.nvim_buf_is_valid(pan.buf) then
                            bufs[#bufs + 1] = pan.buf
                        end
                    end
                end
                return bufs
            end,
            is_current = function()
                return shown(p) and api.nvim_get_current_win() == p.term_pan.win
            end,
        }
    end
    -- Refresh the ANCHORED geometry override per open: `do_show` feeds it to `dock.slot(layout,
    -- consumer.slot)` for this entry's rect. Empty {} = inherit the global geometry; a populated
    -- `config.dock.force[layout]` forces this entry's size/backdrop.
    p.consumer.slot = config.dock.force[layout]
    return p.consumer
end

--- Show terminal `id` (default: the current terminal, else spawn one) in `layout`. With
--- `config.dock.dock_stack = true` (the default) it opens THROUGH the dock manager: it becomes /
--- re-shows the "lvim-term" dock entry FOR THAT LAYOUT (hiding any other consumer in that layout, and
--- being cyclable with `<Leader>n`/`<Leader>p`). Opening in a DIFFERENT layout adds a 2nd/3rd live
--- frame — it does NOT move the existing one, so the terminal can be present in float AND bottom AND
--- area at once. With `dock.dock_stack = false` — or without the manager (an older lvim-utils) — it
--- opens STANDALONE (`realize`): the frame still sizes from the central geometry (ui.tabs reads it,
--- with `config.dock.force[layout]` on top), it simply does NOT join the managed stack. Switching
--- TERMINALS (an inner-tab `id`) re-shows the same entry and reconciles the frame onto that tab — a
--- different axis from cross-consumer dock cycling.
---@param id integer?
---@param layout ("float"|"area"|"bottom")?
function M.show(id, layout)
    layout = layout or config.layout
    local term = id and manager.get(id)
    if not term then
        local cur = manager.current()
        term = cur and manager.get(cur) or manager.spawn()
    end
    local p = panel(layout)
    p.pending_term = term
    local d = get_dock()
    if d and config.dock.dock_stack then
        -- STORE the returned ENTRY KEY (id, layout): the lifecycle notifications (`parked`/`hide`) for
        -- THIS layout's entry take that key back. Re-opening the same (id, layout) returns the same key
        -- and RE-SHOWS the one entry — never a duplicate in the stack.
        p.key = d.open(get_consumer(layout))
    else
        realize(p)
    end
end

--- Hide the terminal. With `layout` given, PARK that layout's frame ONLY (the terminal stays visible
--- in any other layout it is docked in); with none, park EVERY currently-shown layout (a `:LvimTerm`
--- toggle-off with no layout token, or a kill-all). As a dock-STACK consumer (`config.dock.dock_stack`)
--- a park routes through the manager (`dock.hide` by the layout's stored KEY): the frame is torn down
--- but every terminal buffer stays alive, and the entry stays on its stack so it remains cyclable /
--- re-toggleable — it is NOT killed (that is `<Leader>x` → `consumer.close`). Standalone / without the
--- manager it parks directly.
---@param layout ("float"|"area"|"bottom")?
function M.hide(layout)
    local function hide_one(name)
        local p = panel(name)
        local d = get_dock()
        if d and config.dock.dock_stack and p.key then
            d.hide(p.key) -- park + keep the entry on the stack (memory); NOT a kill
        else
            park(p)
        end
    end
    if layout then
        hide_one(layout)
        return
    end
    for _, name in ipairs(LAYOUTS) do
        if shown(panels[name]) then
            hide_one(name)
        end
    end
end

--- Toggle `layout` (default `config.layout`): show the current/given terminal there when that layout is
--- hidden, park that layout when it is shown (and no explicit `id` re-selects a terminal). Each layout
--- toggles INDEPENDENTLY, so `:LvimTerm float` and `:LvimTerm bottom` open two parallel frames.
---@param id integer?
---@param layout ("float"|"area"|"bottom")?
function M.toggle(id, layout)
    local L = layout or config.layout
    if not id and M.is_shown(L) then
        M.hide(L)
    else
        M.show(id, layout)
    end
end

--- Switch a display frame to another terminal (next/prev), showing it if hidden. With `layout` given
--- (a footer chip), that slot cycles from ITS shown terminal; otherwise the slot (and the terminal
--- to step FROM) resolve from the window the key was pressed in, so cycling in the float frame steps
--- the float display and cycling in the bottom frame steps the bottom one.
---@param delta integer  +1 next, -1 prev
---@param layout ("float"|"area"|"bottom")?
function M.cycle(delta, layout)
    local p = layout and panels[layout] or current_panel()
    local L = layout or (p and p.layout)
    local from = (p and p.shown) or manager.current()
    local nid = manager.neighbour(from, delta)
    if nid then
        M.show(nid, L)
    end
end

--- Move the CURRENT tab one slot left (-1) / right (+1) in the order and reconcile every visible frame.
---@param delta integer
function M.move_tab(delta)
    local cur = manager.current()
    if cur and manager.move(cur, delta) then
        M.refresh()
    end
end

--- Reconcile EVERY open frame whose tabset is stale (after a terminal exits / is renamed / the order
--- moves / a spawn or kill from outside that frame) — the ui.tabs re-open keeps each frame on its OWN
--- shown terminal (they reconcile independently) and keeps focus + mode where they were (`reopen`), so
--- a background exit never yanks the user out of their window.
function M.refresh()
    local sig = tabsig()
    for _, name in ipairs(LAYOUTS) do
        local p = panels[name]
        if shown(p) and p.tabsig ~= sig then
            local cur = manager.current()
            local term = (p.shown and manager.get(p.shown)) or (cur and manager.get(cur)) or manager.all()[1]
            if term then
                reopen(p, term)
            end
        end
    end
end

--- Detach terminal `id`'s buffer from every display window it is shown in — the ownership handoff
--- BEFORE that buffer is deleted (a kill). Deleting a buffer still displayed in a frame float would
--- close that float and tear the whole frame down with it. Each affected frame swaps to the NEXT
--- terminal in the tab order IN PLACE (so a kill in the float frame stays a float display — no layout
--- jump); the tab bar catches up on the caller's follow-up `refresh` (the fingerprint reconcile).
--- When `id` is the LAST terminal the frame falls back to its own scratch panel buffer (the caller
--- hides it right after, once the registry is empty).
---@param id integer
function M.detach(id)
    local term = manager.get(id)
    local buf = term and term.bufnr
    if not (buf and api.nvim_buf_is_valid(buf)) then
        return
    end
    local nid = manager.neighbour(id, 1)
    if nid == id then
        nid = nil -- `id` is the only terminal — nothing to step to
    end
    for _, name in ipairs(LAYOUTS) do
        local p = panels[name]
        if shown(p) and api.nvim_win_get_buf(p.term_pan.win) == buf then
            local nterm = nid and manager.get(nid)
            if nterm then
                show_term_in(p, p.term_pan, nterm)
            else
                local scratch = p.term_pan.buf
                if scratch and api.nvim_buf_is_valid(scratch) then
                    api.nvim_win_set_buf(p.term_pan.win, scratch)
                end
                p.shown = nil
            end
        end
    end
end

return M
