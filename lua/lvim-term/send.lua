-- lvim-term.send: send text/commands INTO a terminal (the betterTerm core).
-- chansend to a terminal's job, with the ergonomics builds/REPLs want: reveal the terminal,
-- interrupt a running program first (Ctrl-C — the "rerun" pattern), clear the screen, and the
-- send-the-current-file / send-the-visual-selection helpers.
--
---@module "lvim-term.send"

local api = vim.api
local fn = vim.fn
local manager = require("lvim-term.manager")

local M = {}

--- The target terminal for a send: the given id, else the current terminal, else a freshly
--- spawned one (so `send` from a keymap always has somewhere to go).
---@param id integer?
---@return LvimTerminal?
local function target(id)
    if id then
        return manager.get(id)
    end
    local cur = manager.current()
    if cur then
        return manager.get(cur)
    end
    return manager.spawn()
end

--- Send `data` to a terminal. `opts.interrupt` sends Ctrl-C first (rerun); `opts.clear` clears
--- the screen; `opts.show` reveals the terminal (via ui) after sending; a trailing newline is
--- added unless `opts.newline == false`.
---@param data string
---@param id integer?
---@param opts { interrupt?: boolean, clear?: boolean, show?: boolean, newline?: boolean }?
---@return boolean
function M.send(data, id, opts)
    opts = opts or {}
    local term = target(id)
    if not term or not term.job_id then
        return false
    end
    if opts.interrupt then
        pcall(fn.chansend, term.job_id, "\3") -- Ctrl-C
    end
    if opts.clear then
        pcall(fn.chansend, term.job_id, "\12") -- Ctrl-L (clear)
    end
    local payload = data
    if opts.newline ~= false then
        payload = payload .. "\r"
    end
    local ok = pcall(fn.chansend, term.job_id, payload)
    if opts.show then
        pcall(function()
            require("lvim-term.ui").show(term.id)
        end)
    end
    return ok
end

--- Send the current buffer's file path prefixed by `runner` (e.g. `send_file("python")` →
--- `python /path/file.py`). Without `runner`, sends the raw path.
---@param runner string?
---@param id integer?
---@param opts table?
---@return boolean
function M.send_file(runner, id, opts)
    local file = api.nvim_buf_get_name(0)
    if file == "" then
        return false
    end
    local cmd = (runner and runner ~= "") and (runner .. " " .. fn.fnameescape(file)) or fn.fnameescape(file)
    return M.send(cmd, id, opts)
end

--- Send the last visual selection's text, line by line.
---@param id integer?
---@param opts table?
---@return boolean
function M.send_selection(id, opts)
    local s = fn.getpos("'<")
    local e = fn.getpos("'>")
    if s[2] == 0 or e[2] == 0 then
        return false
    end
    local lines = api.nvim_buf_get_lines(0, s[2] - 1, e[2], false)
    if #lines == 0 then
        return false
    end
    local term = target(id)
    if not term or not term.job_id then
        return false
    end
    -- Send as one payload of joined lines + a trailing newline (bracketed-paste-friendly).
    local ok = pcall(fn.chansend, term.job_id, table.concat(lines, "\r") .. "\r")
    if opts and opts.show then
        pcall(function()
            require("lvim-term.ui").show(term.id)
        end)
    end
    return ok
end

return M
