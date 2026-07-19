-- lvim-term: persistent, named, toggleable terminals with betterTerm-style tabs.
-- Distinct from lvim-shell (one-shot TUI-app launchers): here a terminal is a long-lived shell
-- kept alive while hidden, toggled in/out of a lvim-ui surface frame, switched via its header tab
-- bar, and SENT commands (the builds/REPLs workflow). Public API + a single `:LvimTerm` verb.
--
--   :LvimTerm                       -- toggle the current terminal
--   :LvimTerm new [name=build]      -- spawn another
--   :LvimTerm next | prev           -- switch tabs
--   :LvimTerm select | kill         -- chooser / close
--   :LvimTerm <sub> [float|area|bottom]  -- with a layout token
--   require("lvim-term").send("make", nil, { interrupt = true, show = true })
--
---@module "lvim-term"

local api = vim.api
local config = require("lvim-term.config")
local manager = require("lvim-term.manager")
local ui = require("lvim-term.ui")
local send = require("lvim-term.send")
local highlights = require("lvim-term.highlights")
local hl = require("lvim-utils.highlight")
local merge = require("lvim-utils.utils").merge

local M = {}

---@type boolean  one-time setup done
local registered = false

-- ── public API ────────────────────────────────────────────────────────────

--- Toggle the current (or a given) terminal in `layout`.
---@param id integer?
---@param layout ("float"|"area"|"bottom")?
function M.toggle(id, layout)
    ui.toggle(id, layout)
end

--- Spawn a new terminal and show it.
---@param opts LvimTermSpawnOpts?
---@param layout ("float"|"area"|"bottom")?
---@return LvimTerminal
function M.new(opts, layout)
    local term = manager.spawn(opts)
    ui.show(term.id, layout)
    return term
end

--- ADOPT another plugin's live terminal buffer as a terminal TAB and show it — the seam that turns a
--- read-only output pane into a real INTERACTIVE terminal (lvim-tasks hands over a running task's output
--- so a watch-mode runner / a REPL / anything reading stdin can be typed into). lvim-term only VIEWS it:
--- the owner keeps the buffer and the job, and closing the tab merely detaches it.
---@param opts { bufnr: integer, job_id: integer?, name: string?, cwd: string? }
---@param layout ("float"|"area"|"bottom")?
---@return LvimTerminal?
function M.adopt(opts, layout)
    local term = manager.adopt(opts)
    if not term then
        return nil
    end
    ui.show(term.id, layout)
    return term
end

--- Switch to the next / previous terminal tab.
function M.next()
    ui.cycle(1)
end
function M.prev()
    ui.cycle(-1)
end

--- Kill a terminal (confirm via lvim-ui when it is still running).
---@param id integer?
function M.kill(id)
    id = id or manager.current()
    if not id then
        return
    end
    local term = manager.get(id)
    if not term then
        return
    end
    local function do_kill()
        -- Hand the display OFF the dying buffer first: a frame float still showing it would be closed
        -- by the buffer delete, tearing the whole frame down. The detach steps each affected frame to
        -- the NEXT terminal in place (layout-correct), so after the kill only a repaint is needed.
        ui.detach(id)
        -- An ADOPTED terminal keeps its buffer (the owner's), so manager.kill only detaches it — but
        -- show_term_in stamped lvim-term's buffer-local maps + filetype on that foreign buffer. Strip
        -- them here so the owner's own window is not left carrying lvim-term's park/kill keymaps.
        if term.external then
            ui.unbind_keys(term.bufnr)
        end
        manager.kill(id)
        if manager.count() == 0 then
            ui.hide()
        elseif ui.is_shown() then
            ui.refresh() -- the open frame(s) already display the neighbour; drop the dead tab from the bar
        else
            ui.show(manager.current()) -- killed from the command with no frame open: reveal the next one
        end
    end
    if term.job_id and not term.exited then
        local ok, lvim_ui = pcall(require, "lvim-ui")
        if ok and lvim_ui.confirm then
            lvim_ui.confirm({
                -- lvim-ui.confirm renders `opts.title or opts.prompt` as the question — it has NO
                -- `message` field, so the terminal name must live in the title itself (else the user
                -- confirms blind when several terminals are open).
                title = ("Kill %q (still running)?"):format(term.name),
                callback = function(yes)
                    if yes then
                        do_kill()
                    end
                end,
            })
            return
        end
    end
    do_kill()
end

--- Pick a terminal from a chooser (via lvim-ui.select) and show it.
function M.select()
    local ok, lvim_ui = pcall(require, "lvim-ui")
    if not ok then
        return
    end
    local items = {}
    for _, t in ipairs(manager.all()) do
        items[#items + 1] = {
            label = ("%s%s"):format(t.name, t.exited and "  (exited)" or ""),
            icon = t.exited and config.icons.exited or config.icons.running,
            id = t.id,
        }
    end
    if #items == 0 then
        M.new()
        return
    end
    lvim_ui.select({
        title = "Terminals",
        items = items,
        callback = function(confirmed, index)
            if confirmed and index and items[index] then
                ui.show(items[index].id)
            end
        end,
    })
end

--- Send text to a terminal (see lvim-term.send). Exposed for builds/REPL keymaps.
---@param data string
---@param id integer?
---@param opts table?
---@return boolean
function M.send(data, id, opts)
    return send.send(data, id, opts)
end

--- Send the current file (optionally prefixed by a runner) to a terminal.
---@param runner string?
---@param id integer?
---@param opts table?
function M.send_file(runner, id, opts)
    return send.send_file(runner, id, opts)
end

--- Send the last visual selection to a terminal.
---@param id integer?
---@param opts table?
function M.send_selection(id, opts)
    return send.send_selection(id, opts)
end

-- ── command ──────────────────────────────────────────────────────────────

local LAYOUTS = { float = true, area = true, bottom = true }

--- Parse `:LvimTerm` args: a layout token anywhere + a subcommand + inline `name=…`.
---@param args string
---@return string sub, string? layout, string? name
local function parse(args)
    local sub, layout, name = "toggle", nil, nil
    for _, tok in ipairs(vim.split(vim.trim(args), "%s+")) do
        if tok == "" then -- skip
        elseif LAYOUTS[tok] then
            layout = tok
        elseif tok:match("^name=") then
            name = tok:sub(6)
        else
            sub = tok
        end
    end
    return sub, layout, name
end

--- Dispatch a parsed `:LvimTerm` invocation.
---@param sub string
---@param layout string?
---@param name string?
local function dispatch(sub, layout, name)
    if sub == "toggle" then
        M.toggle(nil, layout)
    elseif sub == "new" then
        M.new({ name = name }, layout)
    elseif sub == "next" then
        M.next()
    elseif sub == "prev" then
        M.prev()
    elseif sub == "select" then
        M.select()
    elseif sub == "kill" then
        M.kill()
    else
        vim.notify("lvim-term: unknown subcommand " .. sub, vim.log.levels.WARN)
    end
end

-- ── setup ─────────────────────────────────────────────────────────────────

--- Merge user options into the live config, bind the self-theming groups, register `:LvimTerm`
--- and the change handler (a terminal exiting refreshes the tab bar). Optional — defaults work.
---@param opts LvimTermConfig?
function M.setup(opts)
    if opts then
        merge(config, opts)
    end
    if registered then
        return
    end
    registered = true

    hl.setup()
    hl.bind(highlights.build)

    -- A terminal exiting (or being renamed) repaints the visible tab bar. When `close_on_exit` is set,
    -- a shell that has just exited also CLOSES its display: the only terminal parks every frame (ui.hide),
    -- otherwise each frame showing it steps to the neighbour (ui.detach) and the dead terminal is dropped
    -- from the registry — matching the config doc's "close the window when the shell exits (else keep the
    -- exited buffer)". An exit while no frame is open removes the terminal silently (no frame is popped).
    api.nvim_create_autocmd("User", {
        pattern = "LvimTermChanged",
        group = api.nvim_create_augroup("LvimTermChanged", { clear = true }),
        callback = function(event)
            local data = event.data
            if config.close_on_exit and type(data) == "table" and data.id then
                local term = manager.get(data.id)
                if term and term.exited then
                    vim.schedule(function()
                        if ui.is_shown() then
                            if manager.count() <= 1 then
                                ui.hide()
                            else
                                ui.detach(data.id)
                            end
                        end
                        manager.kill(data.id)
                        ui.refresh()
                    end)
                    return
                end
            end
            vim.schedule(ui.refresh)
        end,
        desc = "lvim-term: refresh the tab bar on a terminal change (close the frame on exit when close_on_exit)",
    })

    api.nvim_create_user_command("LvimTerm", function(cmd)
        dispatch(parse(cmd.args))
    end, {
        nargs = "*",
        desc = "lvim-term: toggle / new / next / prev / select / kill [float|area|bottom]",
        complete = function()
            return { "toggle", "new", "next", "prev", "select", "kill", "float", "area", "bottom" }
        end,
    })
end

return M
