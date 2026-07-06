-- lvim-term.ui: the terminal DISPLAY WINDOWS (one drop-down window PER LAYOUT; the manager owns
-- the buffers). A terminal is interactive (needs the real cursor + insert mode), so each display is
-- a plain themed window — NOT a surface panel (whose cursor-hiding / sector navigation would fight a
-- terminal). Within one layout a single window is reused: switching terminals swaps its buffer IN
-- PLACE (no window churn), the way a drop-down terminal cycles. Layouts: `bottom` (a dock), `float`
-- (a centred modal), and `area` — a float DOCKED in the lvim-msgarea area zone via its shared
-- `host_window` primitive (the ZONE owns the height + repositioning; without the zone, `area` falls
-- back to `bottom`).
--
-- lvim-term is a consumer of the shared DOCK-STACK manager (lvim-utils.dock), which keys every entry
-- by (id, LAYOUT): the stable id "lvim-term" is the base identity, and the SAME id opened in a
-- DIFFERENT layout is a SEPARATE entry in that other layout's stack. So the terminal can be docked in
-- float, bottom AND area SIMULTANEOUSLY — three live display windows, one entry in each stack, all
-- showing the SHARED current-terminal buffer — while re-opening the SAME (id, layout) RE-SHOWS the one
-- entry (never a duplicate in that stack). That is why every piece of display state is PER LAYOUT
-- (`panels[layout]`, see `panel`): one window / one dock KEY / one memoised consumer per layout, so an
-- open in float and an open in bottom are wholly independent and neither orphans the other's window.
-- `dock.open` RETURNS the entry key; each layout's slot STORES it and passes it back to the lifecycle
-- APIs (`parked`/`hide`) for THAT entry.
--
-- The `manager` (the terminals themselves) is SHARED across all layouts — only the DISPLAY windows are
-- per layout. The terminal's OWN inner tab bar (`<A-l>`/`<A-h>`) is a DIFFERENT axis — switching
-- TERMINALS within a display window — and is untouched. The manager owns visibility; this module owns
-- the windows (it is the consumer's `show`/`hide`/`is_alive` mechanism).
--
---@module "lvim-term.ui"

local api = vim.api
local config = require("lvim-term.config")
local manager = require("lvim-term.manager")

local M = {}

---@type string[]  the three coordinated layouts the terminal can be displayed in (independently)
local LAYOUTS = { "float", "area", "bottom" }

--- Per-LAYOUT display state. Because the dock keys every entry by (id, layout), the terminal can be
--- docked in float, bottom AND area at once — three live windows, one entry per stack — so every
--- piece of display state is PER LAYOUT, kept in `panels[layout]` (lazily created by `panel`). A flat
--- single-window model would orphan the first window the moment the terminal is opened in a 2nd layout.
---@class LvimTermPanel
---@field layout       "float"|"area"|"bottom"  which layout THIS slot displays (fixed for its lifetime)
---@field win          integer?     the display window for this layout (nil when hidden)
---@field area_dock    table?       the msgarea dock handle (`host_window`'s LvimMsgAreaDock, a cross-plugin
---                    optional type) while `area` is docked in the zone; `dock:release()` tears it down
---@field win_au       integer?     the WinClosed autocmd for the bottom/float window (external-close notify)
---@field parking      boolean      true while we deliberately tear this layout's window down in `park` — so the
---                    external-close hooks (the area `on_close`, the bottom/float WinClosed) DON'T re-notify
---                    the dock manager (which would re-enter mid-hide). The clean re-entrancy seam.
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

--- Whether slot `p` currently has an open, valid display window.
---@param p LvimTermPanel?
---@return boolean
local function shown(p)
    return p ~= nil and p.win ~= nil and api.nvim_win_is_valid(p.win)
end

--- The display slot whose window is the CURRENT window (a key/click happened inside it), or nil.
---@return LvimTermPanel?
local function current_panel()
    local cur = api.nvim_get_current_win()
    for _, name in ipairs(LAYOUTS) do
        local p = panels[name]
        if p and p.win == cur and api.nvim_win_is_valid(cur) then
            return p
        end
    end
    return nil
end

--- The terminal whose buffer is `buf` (so a display window's own active terminal can be resolved), or nil.
---@param buf integer
---@return LvimTerminal?
local function term_for_buf(buf)
    for _, t in ipairs(manager.all()) do
        if t.bufnr == buf then
            return t
        end
    end
    return nil
end

---@type table|false|nil  cached lvim-utils.dock module (nil = unprobed, false = probed & absent)
local dock_mod = nil
--- The dock-stack manager, or nil if unavailable (then lvim-term docks directly, un-managed).
---@return table?
local function get_dock()
    if dock_mod == nil then
        local ok, m = pcall(require, "lvim-utils.dock")
        dock_mod = ok and m or false
    end
    return dock_mod or nil
end

--- Apply the SHARED, focus-aware backdrop behind slot `p`'s float / bottom window so it mutes the
--- editor exactly like the lvim-ui pickers do. The layout's backdrop spec (enabled / mode / amount)
--- comes from the ONE central geometry authority — `dock.slot(render_layout).backdrop` — so the
--- terminal never owns a backdrop of its own. The window itself is PROTECTED (never muted). Keyed per
--- layout (`"lvim-term:<layout>"`) so a float and a bottom backdrop coexist without clobbering each
--- other. `render_layout` selects the SPEC (the area→bottom fallback renders as bottom); `p.layout`
--- keys the backdrop + protects its own window. `area` proper is deliberately NOT backdropped here
--- (the msgarea zone owns that layout). Cross-plugin, so pcall-guarded — a missing / older lvim-utils
--- just means no backdrop, never a failed open.
---@param p LvimTermPanel
---@param render_layout "float"|"bottom"
local function apply_backdrop(p, render_layout)
    pcall(function()
        -- Thread the per-layout force override so a forced backdrop (config.dock.force[layout].backdrop)
        -- wins here too — the same override dock.slot receives when sizing the window.
        local bd = require("lvim-utils.dock").slot(render_layout, config.dock.force[render_layout]).backdrop
        if bd and bd.enabled ~= false then
            local mode = (bd.mode == "dim") and "dim" or "darken"
            local amt = ((mode == "dim") and bd.dim or bd.darken or {}).amount or 0.5
            require("lvim-utils.dim").apply_backdrop("lvim-term:" .. p.layout, {
                enabled = true,
                mode = mode,
                amount = amt,
                protect = function(w)
                    return w == p.win
                end,
            })
        end
    end)
end

--- Tear slot `p`'s backdrop down (restore every muted window). Idempotent / no-op when none is live,
--- so it is safe to call on any close path (park, external WinClosed, area on_close).
---@param p LvimTermPanel
local function clear_backdrop(p)
    pcall(function()
        require("lvim-utils.dim").clear_backdrop("lvim-term:" .. p.layout)
    end)
end

--- Notify the dock manager that slot `p`'s window was dismissed by the USER destroying it DIRECTLY (an
--- external `:q`, a `<C-w>c` / "close current window", a shell that exited → WinClosed, or the area
--- `on_close`) — NOT a manager-driven park. This MIRRORS the lvim-picker consumer's self-dismiss: route
--- it through `dock.parked` (by THIS layout's stored KEY) so the layout COLLAPSES and the entry STAYS on
--- its stack. The terminal BUFFERS survive (bufhidden = "hide"), so `is_alive` stays true → the entry
--- remains cyclable (`<Leader>n`/`<Leader>p`) and re-toggleable, exactly like a parked picker. Crucially
--- it does NOT reveal the LIFO-next consumer (what `dock.closed` would do). The window is already gone at
--- every call site, so `dock.parked` fixes bookkeeping ONLY — it must NOT re-call the consumer's `hide`.
--- Guarded by `p.parking` at every call site so a manager park never re-notifies. No-op without a key
--- (standalone) — nothing to notify.
---@param p LvimTermPanel
local function notify_parked(p)
    local d = get_dock()
    if d and p.key then
        pcall(d.parked, p.key)
    end
end

--- Watch `win` for an EXTERNAL close (a `:q` / `<C-w>c` / `nvim_win_close` the user triggers, not our
--- park): fire `notify_parked(p)` so the dock manager COLLAPSES this layout while the terminal entry
--- stays parked on the stack (its buffers survive) — never revealing a stranded neighbour. The area
--- layout uses msgarea's own `on_close` instead (host_window owns that window's teardown), so this is
--- only for the bottom / float windows. Replaces any prior watcher for this slot.
---@param p LvimTermPanel
---@param win integer
local function watch_close(p, win)
    if p.win_au then
        pcall(api.nvim_del_autocmd, p.win_au)
        p.win_au = nil
    end
    p.win_au = api.nvim_create_autocmd("WinClosed", {
        pattern = tostring(win),
        once = true,
        callback = function()
            p.win_au = nil
            p.win = nil
            clear_backdrop(p) -- an external :q on the float/bottom window: lift the backdrop too
            if not p.parking then
                notify_parked(p)
            end
        end,
    })
end

--- Whether ANY display window is open — or, with `layout`, that specific layout's window.
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

-- Click-region minwid encoding: a bare id selects that tab; CLOSE_BASE + id closes it; NEW_TAB
-- is the "+" button. (Terminal ids are small; the bands never overlap.)
local CLOSE_BASE = 100000
local NEW_TAB = 999999

--- Escape a name for a winbar/statusline string (percent is the format sigil).
---@param s string
---@return string
local function esc(s)
    return (s:gsub("%%", "%%%%"))
end

--- The terminal window's WINBAR = a title bar: a "terminal" TITLE (with a background block) then,
--- when tabs are on, one clickable tab per terminal (active highlighted, exited dimmed) + a `+`
--- new-tab button. The title lives HERE (in the winbar / title bar), never on the border. Click
--- regions switch/create terminals via `M._click`.
--- The RIGHT-aligned winbar HINT — makes the app-safe close/nav discoverable. terminal-INSERT is untouched
--- (the running program owns every key); this only advertises the native `<C-\><C-n>` gateway into
--- terminal-NORMAL and the dock keys there (park / tab-nav / kill). Built from the live `config.keys`.
---@return string
local function winbar_hint()
    local k = config.keys or {}
    local function lbl(s)
        return (type(s) == "string" and s or ""):gsub("[<>]", "")
    end
    return ("%%#LvimTermWinbarFill# ^\\ ^n → %s/Esc park · %s/%s tabs · <Leader>x kill "):format(
        lbl(k.close) ~= "" and lbl(k.close) or "q",
        lbl(k.next),
        lbl(k.prev)
    )
end

---@param active LvimTerminal
---@return string
local function tabbar(active)
    local title = "%#LvimTermTitle# " .. config.icons.terminal .. " terminal %#LvimTermWinbarFill# "
    if not config.tabs then
        local icon = active.exited and config.icons.exited or config.icons.running
        return title
            .. "%#LvimTermTabActive# "
            .. icon
            .. " "
            .. esc(active.name)
            .. " %#LvimTermWinbarFill#%="
            .. winbar_hint()
    end
    local parts = { title }
    for _, term in ipairs(manager.all()) do
        local grp = (term.id == active.id) and "LvimTermTabActive"
            or (term.exited and "LvimTermTabExited" or "LvimTermTabInactive")
        local icon = term.exited and config.icons.exited or config.icons.running
        -- the tab body (click = select) + a trailing close button (click = kill THIS terminal)
        local tab = ("%%#%s#%%%d@v:lua.require'lvim-term.ui'._click@ %s %s %%X"):format(
            grp,
            term.id,
            icon,
            esc(term.name)
        )
        local close = ("%%#%s#%%%d@v:lua.require'lvim-term.ui'._click@%s %%X"):format(
            grp,
            CLOSE_BASE + term.id,
            config.icons.kill
        )
        parts[#parts + 1] = tab .. close
    end
    -- the "+" new-tab button, then the fill strip.
    parts[#parts + 1] = ("%%#LvimTermTabNew#%%%d@v:lua.require'lvim-term.ui'._click@ %s %%X"):format(
        NEW_TAB,
        config.icons.new
    )
    parts[#parts + 1] = "%#LvimTermWinbarFill#%="
    parts[#parts + 1] = winbar_hint()
    return table.concat(parts)
end

--- Winbar click handler (registered in the tab format via `%@v:lua…._click@`). `minwid` is the
--- terminal id, or NEW_TAB for the "+" button. The CLICKED window's layout is captured SYNCHRONOUSLY
--- (a winbar click makes that window current) so the tab switch / new-tab lands in the SAME display
--- window, then deferred so the window/buffer mutation (and a jobstart for a new terminal) never runs
--- INSIDE the winbar-eval / click context — doing it there froze the UI.
---@param minwid integer
function M._click(minwid)
    local p = current_panel()
    local layout = p and p.layout
    vim.schedule(function()
        if minwid == NEW_TAB then
            M.show(manager.spawn().id, layout)
        elseif minwid >= CLOSE_BASE then
            require("lvim-term").kill(minwid - CLOSE_BASE)
        elseif manager.get(minwid) then
            M.show(minwid, layout)
        end
    end)
end

--- Move the CURRENT tab one slot left (-1) / right (+1) in the order and repaint every visible bar.
---@param delta integer
function M.move_tab(delta)
    local cur = manager.current()
    if cur and manager.move(cur, delta) then
        M.refresh()
    end
end

--- Bind the buffer-local tab keys (next / prev / new / move) on a terminal buffer, in terminal AND
--- normal mode, once. Alt-based so they never clash with shell input. The CLOSE key is bound in
--- NORMAL mode ONLY (see below).
---@param buf integer
local function bind_keys(buf)
    if vim.b[buf].lvim_term_bound then
        return
    end
    vim.b[buf].lvim_term_bound = true
    local k = config.keys or {}
    -- Tab-nav keys are NORMAL-mode ONLY (reached via the native `<C-\><C-n>` gateway). In terminal-INSERT the
    -- running PROGRAM owns EVERY key — a vim / lazygit / vifm / htop inside legitimately uses the Alt chords —
    -- so binding them in `t` would STEAL them from the app. The clean, app-safe seam is normal-mode; the app
    -- keeps terminal-insert entirely (zero interceptions there). The dock's own `<Leader>n/p/x/m` (park/cycle/
    -- kill/menu) likewise only apply in terminal-normal via the dock leader owner.
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
            M.show(manager.spawn().id, current_panel() and current_panel().layout)
        end)
    end)
    map(k.move_next, function()
        M.move_tab(1)
    end)
    map(k.move_prev, function()
        M.move_tab(-1)
    end)
    -- PARK keys — `close` (default `q`) AND `<Esc>`, both park the terminal THROUGH the dock (collapse + keep
    -- the entry on the stack, cyclable — exactly like a `:LvimTerm` toggle-off / the picker's `q`). Bound in
    -- NORMAL mode ONLY: in terminal-insert the shell owns every byte (a vim / fzf / lazygit / vifm running
    -- inside legitimately needs `q` and `<Esc>`), so a terminal-mode close key would break it — the clean seam
    -- is a normal-mode key, reached with `<C-\><C-n>`, that never reaches the app. They route through `M.hide`
    -- for the CURRENT window's layout ONLY (parking that one display, leaving the terminal visible in any other
    -- layout it is docked in); a real KILL of every terminal stays on the dock's `<Leader>x` (→ `consumer.close`).
    for _, lhs in ipairs({ k.close, "<Esc>" }) do
        if lhs and lhs ~= "" then
            vim.keymap.set("n", lhs, function()
                local p = current_panel()
                M.hide(p and p.layout)
            end, {
                buffer = buf,
                silent = true,
                desc = "lvim-term: park this layout's terminal window via the dock (collapse, keep cyclable)",
            })
        end
    end
end

--- Post-creation window setup for slot `p`: theme, winbar tab bar, minimal chrome, focus + insert.
--- Called on first create and on a same-window buffer swap (switching tabs); a bare reposition skips it.
---@param p LvimTermPanel
---@param term LvimTerminal
local function finalize_window(p, term)
    api.nvim_set_current_win(p.win)
    vim.wo[p.win].winhighlight = "Normal:LvimTermNormal,NormalNC:LvimTermNormal"
    vim.wo[p.win].winbar = tabbar(term)
    vim.wo[p.win].number = false
    vim.wo[p.win].relativenumber = false
    vim.wo[p.win].signcolumn = "no"
    manager.set_current(term.id)
    if config.start_in_insert and not term.exited then
        vim.cmd("startinsert")
    end
end

--- Open (or reuse) slot `p`'s window as a BOTTOM split showing `term`'s buffer. Also the area→bottom
--- fallback target (the slot's layout stays "area"; only the geometry is bottom).
---@param p LvimTermPanel
---@param term LvimTerminal
local function open_bottom(p, term)
    -- Row count from the central geometry authority (config.dock.geometry.bottom via `dock.slot`);
    -- the per-layout `config.dock.force.bottom` ANCHORED override (empty {} = inherit) wins for this call.
    local h = require("lvim-utils.dock").slot("bottom", config.dock.force.bottom).height
    vim.cmd("botright " .. h .. "split")
    p.win = api.nvim_get_current_win()
    api.nvim_win_set_buf(p.win, term.bufnr)
    watch_close(p, p.win)
    finalize_window(p, term)
    apply_backdrop(p, "bottom")
end

--- Open slot `p`'s display window (or reuse it) and put `term`'s buffer in it, in `p.layout`.
---@param p LvimTermPanel
---@param term LvimTerminal
local function open_window(p, term)
    local layout = p.layout
    local buf = term.bufnr
    if not (buf and api.nvim_buf_is_valid(buf)) then
        return
    end
    bind_keys(buf)

    -- Already visible → just swap the buffer in place (switching tabs), no re-dock.
    if shown(p) then
        api.nvim_win_set_buf(p.win, buf)
        finalize_window(p, term)
        return
    end

    if layout == "float" then
        -- Geometry comes from the ONE central authority (config.dock.geometry.float via `dock.slot`),
        -- not a size lvim-term keeps — every dock consumer lands in the identical float rect. The
        -- per-layout `config.dock.force.float` ANCHORED override (empty {} = inherit) wins for this call.
        local s = require("lvim-utils.dock").slot("float", config.dock.force.float)
        -- No border title: the winbar TAB BAR already labels the terminal(s).
        p.win = api.nvim_open_win(buf, true, {
            relative = "editor",
            width = s.width,
            height = s.height,
            row = s.row,
            col = s.col,
            style = "minimal",
            border = "rounded",
        })
        watch_close(p, p.win)
        finalize_window(p, term)
        apply_backdrop(p, "float")
    elseif layout == "area" then
        -- Dock IN the msgarea area zone via the SHARED `host_window` primitive: the ZONE owns the
        -- height (the control-center `config.ui.size.area.height`) and repositions the window as it
        -- reflows — the terminal never computes area geometry itself (DRY). The window is a plain
        -- float the terminal owns (a surface panel would fight the live cursor / insert mode); the
        -- dock only re-places it. Without the zone, `area` falls back to the bottom dock.
        local ok, msgarea = pcall(require, "lvim-msgarea")
        if ok and msgarea.host_window and msgarea.is_enabled() then
            -- A placeholder rect at the screen bottom — host_window immediately re-places the window
            -- over the real reserved rect (and keeps it there on every zone reflow).
            p.win = api.nvim_open_win(buf, true, {
                relative = "editor",
                row = math.max(0, vim.o.lines - 2),
                col = 0,
                width = vim.o.columns,
                height = 1,
                style = "minimal",
                border = "none",
            })
            p.area_dock = msgarea.host_window(p.win, {
                on_close = function()
                    -- the dock is gone (released, or the window was closed directly) — drop our state
                    p.area_dock = nil
                    p.win = nil
                    clear_backdrop(p) -- idempotent: area owns no backdrop, but keep every close path uniform
                    -- an EXTERNAL close (not our park) PARKS the entry: collapse the area dock, keep it on
                    -- the stack (buffers survive), reveal nothing; a manager park suppresses it (parking guard).
                    if not p.parking then
                        notify_parked(p)
                    end
                end,
            })
            if p.area_dock then
                finalize_window(p, term)
            else
                -- the zone declined (disabled between the check and the dock) — bottom dock instead
                local w = p.win
                p.win = nil
                if w and api.nvim_win_is_valid(w) then
                    pcall(api.nvim_win_close, w, false)
                end
                open_bottom(p, term)
            end
        else
            open_bottom(p, term)
        end
    else -- bottom dock
        open_bottom(p, term)
    end
end

--- PARK slot `p`'s display window: tear it down (release the area dock / close the split-or-float)
--- while KEEPING every terminal buffer alive — the dock manager's "hide" (memory). `p.parking`
--- suppresses the external-close notifiers so this never re-enters the manager. State is nil'd FIRST
--- so the release's `on_close` / the WinClosed re-entry can't re-dock or loop.
---@param p LvimTermPanel
local function park(p)
    p.parking = true
    clear_backdrop(p) -- lift the muted editor before we tear the window down
    local dock, win, au = p.area_dock, p.win, p.win_au
    p.area_dock, p.win, p.win_au = nil, nil, nil
    if au then
        pcall(api.nvim_del_autocmd, au)
    end
    if dock then
        pcall(function()
            dock:release() -- host_window release does NOT close the window; we close it below
        end)
    end
    if win and api.nvim_win_is_valid(win) then
        pcall(api.nvim_win_close, win, false)
    end
    p.parking = false
end

--- Build (once, memoised in `panels[layout].consumer`) + return the dock consumer FOR ONE LAYOUT —
--- an `LvimDockConsumer` (the lvim-utils.dock contract; a cross-plugin type, annotated `table`). `id`
--- is the UNCHANGED base identity "lvim-term" — layout is NOT baked into it; the dock composes the
--- (id, layout) key. Because the terminal can be open in every layout at once, there is ONE consumer
--- PER layout, each with a fixed `layout` and each callback reading / writing THIS layout's slot `p`.
--- `show` realises the pending terminal in THIS layout's window; `hide` PARKS it (keeps buffers);
--- `close` (`<Leader>x`) KILLS every terminal (shared) and tears down ALL layouts' windows; `is_alive`
--- is true while any terminal exists; `buffers` returns EVERY terminal buffer (they are all the same
--- dock entry) so the leader owner covers all of them; `focus`/`is_current` read THIS slot's window.
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
            show = function()
                local term = p.pending_term
                if not (term and manager.get(term.id)) then
                    local cur = manager.current()
                    term = (cur and manager.get(cur)) or manager.spawn()
                end
                open_window(p, term)
            end,
            hide = function()
                park(p) -- PARK this layout's window: keep every terminal buffer (restorable on the stack)
            end,
            close = function()
                -- `<Leader>x` on the terminal DOCK: KILL the whole terminal set — the terminals are SHARED
                -- across layouts, so this stops EVERY shell + deletes its buffer, then tears down EVERY
                -- layout's display window and DROPS their now-dead dock entries (the current layout's entry
                -- the dock removes itself after this returns). The inner per-tab `×` kills ONE terminal; this
                -- cross-consumer kill removes them all. Guard `parking` on every slot FIRST so the buffer
                -- deletions can't fire a WinClosed self-notify mid-teardown. `manager.all()` is a snapshot, so
                -- killing (which mutates the order) while iterating it is safe.
                for _, name in ipairs(LAYOUTS) do
                    if panels[name] then
                        panels[name].parking = true
                    end
                end
                for _, t in ipairs(manager.all()) do
                    manager.kill(t.id)
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
            end,
            is_alive = function()
                return manager.count() > 0
            end,
            focus = function()
                if shown(p) then
                    pcall(api.nvim_set_current_win, p.win)
                end
            end,
            buffers = function()
                local bufs = {}
                for _, t in ipairs(manager.all()) do
                    if t.bufnr and api.nvim_buf_is_valid(t.bufnr) then
                        bufs[#bufs + 1] = t.bufnr
                    end
                end
                return bufs
            end,
            is_current = function()
                return shown(p) and api.nvim_get_current_win() == p.win
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
--- display window — it does NOT move the existing one, so the terminal can be present in float AND
--- bottom AND area at once. With `dock.dock_stack = false` — or without the manager (an older
--- lvim-utils) — it opens STANDALONE (`open_window`): geometry is still central (the window sizes via
--- `dock.slot(layout, config.dock.force[layout])`), it simply does NOT join the managed stack. Switching
--- TERMINALS (an inner-tab `id`) re-shows the same entry and swaps the buffer in place — a different
--- axis from cross-consumer dock cycling.
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
    local d = get_dock()
    if d and config.dock.dock_stack then
        -- STORE the returned ENTRY KEY (id, layout): the lifecycle notifications (`parked`/`hide`) for
        -- THIS layout's entry take that key back. Re-opening the same (id, layout) returns the same key
        -- and RE-SHOWS the one entry — never a duplicate in the stack.
        p.pending_term = term
        p.key = d.open(get_consumer(layout))
    else
        -- Standalone: dock_stack disabled (geometry-only) OR the dock manager is unavailable. The
        -- window still sizes from the central authority + force (open_window → dock.slot), it is
        -- just not registered in the stack.
        open_window(p, term)
    end
end

--- Hide the terminal. With `layout` given, PARK that layout's window ONLY (the terminal stays visible
--- in any other layout it is docked in); with none, park EVERY currently-shown layout (a `:LvimTerm`
--- toggle-off with no layout token, or a kill-all). As a dock-STACK consumer (`config.dock.dock_stack`)
--- a park routes through the manager (`dock.hide` by the layout's stored KEY): the window is torn down
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
--- toggles INDEPENDENTLY, so `:LvimTerm float` and `:LvimTerm bottom` open two parallel windows.
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

--- Switch the CURRENT display window to another terminal (next/prev), showing it if hidden. The layout
--- (and the terminal to step FROM) are resolved from the window the key was pressed in, so cycling in
--- the float window steps the float display and cycling in the bottom window steps the bottom one.
---@param delta integer  +1 next, -1 prev
---@param layout ("float"|"area"|"bottom")?
function M.cycle(delta, layout)
    local p = current_panel()
    local L = layout or (p and p.layout)
    local from = manager.current()
    if p and shown(p) and p.win then
        local t = term_for_buf(api.nvim_win_get_buf(p.win))
        if t then
            from = t.id
        end
    end
    local nid = manager.neighbour(from, delta)
    if nid then
        M.show(nid, L)
    end
end

--- Refresh the winbar of EVERY open display window (after a terminal exits / is renamed). Each window
--- keeps its OWN active terminal (resolved from its buffer), so they repaint independently.
function M.refresh()
    for _, name in ipairs(LAYOUTS) do
        local p = panels[name]
        if shown(p) then
            local term = term_for_buf(api.nvim_win_get_buf(p.win))
            if term then
                vim.wo[p.win].winbar = tabbar(term)
            end
        end
    end
end

return M
