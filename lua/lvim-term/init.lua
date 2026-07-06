-- lvim-term: persistent, named, toggleable terminals with betterTerm-style tabs.
-- Distinct from lvim-shell (one-shot TUI-app launchers): here a terminal is a long-lived shell
-- kept alive while hidden, toggled in/out of a drop-down window, switched via a clickable tab bar,
-- and SENT commands (the builds/REPLs workflow). Public API + a single `:LvimTerm` verb.
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
        manager.kill(id)
        if manager.count() == 0 then
            ui.hide()
        else
            ui.show(manager.current())
        end
    end
    if term.job_id and not term.exited then
        local ok, lvim_ui = pcall(require, "lvim-ui")
        if ok and lvim_ui.confirm then
            lvim_ui.confirm({
                title = "Kill terminal",
                message = ("Kill %q (still running)?"):format(term.name),
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

    -- A terminal exiting (or being renamed) repaints the visible tab bar.
    api.nvim_create_autocmd("User", {
        pattern = "LvimTermChanged",
        callback = function()
            vim.schedule(ui.refresh)
        end,
        desc = "lvim-term: refresh the tab bar on a terminal change",
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
