-- lvim-term.manager: the terminal registry + lifecycle (no windows here — ui.lua shows them).
-- Each terminal is a long-lived `:terminal` buffer (jobstart term) kept alive while hidden
-- (bufhidden = "hide"), tracked by a stable id and a name. Spawning, respawning a dead shell in
-- the SAME slot (id/name stable), killing, and the TermClose → "exited" transition live here.
--
---@module "lvim-term.manager"

local api = vim.api
local fn = vim.fn
local config = require("lvim-term.config")

local M = {}

---@class LvimTermSpawnOpts
---@field name string?  overrides the auto name ("term N")
---@field cwd  string?  overrides the config-resolved working directory

---@class LvimTerminal
---@field id     integer
---@field name   string
---@field bufnr  integer?
---@field job_id integer?
---@field cwd    string?
---@field exited boolean
---@field last_mode "i"|"n"?  Remembered mode when hidden (drop-down insert feel)

---@type table<integer, LvimTerminal>
local terms = {}
---@type integer[]  the EXPLICIT tab order (ids), so tabs can be rearranged (not id-sorted)
local order = {}
local _next_id = 0
---@type integer?  the most recently shown terminal (toggle default)
local current_id = nil

--- Remove `id` from the order list.
---@param id integer
local function order_remove(id)
    for i, v in ipairs(order) do
        if v == id then
            table.remove(order, i)
            return
        end
    end
end

--- Resolve the working directory for a new terminal per config.cwd.
---@return string?
local function resolve_cwd()
    local mode = config.cwd
    if type(mode) == "function" then
        local ok, dir = pcall(mode)
        return ok and dir or nil
    elseif mode == "file" then
        -- Only a REAL file buffer contributes a dir — never a terminal buffer (its "term://…"
        -- name would resolve to a bogus cwd and make jobstart fail), so spawning FROM a terminal
        -- falls back to the editor cwd.
        local buf = api.nvim_get_current_buf()
        if vim.bo[buf].buftype == "" then
            local name = api.nvim_buf_get_name(buf)
            if name ~= "" then
                return fn.fnamemodify(name, ":h")
            end
        end
        return (vim.uv or vim.loop).cwd()
    end
    return (vim.uv or vim.loop).cwd()
end

--- Start (or restart) the shell job for `term` into a fresh terminal buffer.
---@param term LvimTerminal
---@return boolean
local function launch(term)
    local buf = api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "hide"
    term.bufnr = buf
    term.exited = false
    local cmd = config.shell or vim.o.shell
    local ok, job = pcall(function()
        return api.nvim_buf_call(buf, function()
            return fn.jobstart(cmd, {
                cwd = term.cwd,
                term = true,
                on_exit = function()
                    term.job_id = nil
                    term.exited = true
                    pcall(api.nvim_exec_autocmds, "User", {
                        pattern = "LvimTermChanged",
                        data = { id = term.id },
                    })
                end,
            })
        end)
    end)
    if not ok or type(job) ~= "number" or job <= 0 then
        term.job_id = nil
        term.exited = true
        return false
    end
    term.job_id = job
    return true
end

--- Create and start a new terminal. `opts.name` overrides the auto name; `opts.cwd` the directory.
---@param opts LvimTermSpawnOpts?
---@return LvimTerminal
function M.spawn(opts)
    opts = opts or {}
    _next_id = _next_id + 1
    local term = {
        id = _next_id,
        name = opts.name or ("term " .. _next_id),
        cwd = opts.cwd or resolve_cwd(),
        exited = false,
    }
    terms[term.id] = term
    order[#order + 1] = term.id
    launch(term)
    current_id = term.id
    return term
end

--- Respawn a dead terminal in the same slot (id/name stay stable). No-op if still alive.
---@param id integer
---@return boolean
function M.respawn(id)
    local term = terms[id]
    if not term then
        return false
    end
    if term.job_id and not term.exited then
        return false
    end
    if term.bufnr and api.nvim_buf_is_valid(term.bufnr) then
        pcall(api.nvim_buf_delete, term.bufnr, { force = true })
    end
    return launch(term)
end

--- Kill a terminal (stop its job) and drop it from the registry.
---@param id integer
---@return boolean
function M.kill(id)
    local term = terms[id]
    if not term then
        return false
    end
    if term.job_id then
        pcall(fn.jobstop, term.job_id)
    end
    if term.bufnr and api.nvim_buf_is_valid(term.bufnr) then
        pcall(api.nvim_buf_delete, term.bufnr, { force = true })
    end
    terms[id] = nil
    order_remove(id)
    if current_id == id then
        current_id = order[#order]
    end
    return true
end

--- A terminal by id.
---@param id integer
---@return LvimTerminal?
function M.get(id)
    return terms[id]
end

--- Terminal ids in the current TAB ORDER (rearrangeable; not id-sorted).
---@return integer[]
function M.ids()
    return vim.deepcopy(order)
end

--- Move terminal `id` one slot left (-1) or right (+1) in the tab order (clamped, no wrap so a
--- drag toward an edge stops there). The reordered position is kept for the session.
---@param id integer
---@param delta integer
---@return boolean moved
function M.move(id, delta)
    for i, v in ipairs(order) do
        if v == id then
            local j = i + delta
            if j < 1 or j > #order then
                return false
            end
            order[i], order[j] = order[j], order[i]
            return true
        end
    end
    return false
end

--- Replace the tab order with `ids` (a drag-drop reorder). Ignores unknown ids and appends any
--- omitted existing ones, so the order stays complete.
---@param ids integer[]
function M.set_order(ids)
    local seen, new = {}, {}
    for _, id in ipairs(ids) do
        if terms[id] and not seen[id] then
            new[#new + 1] = id
            seen[id] = true
        end
    end
    for _, id in ipairs(order) do
        if not seen[id] then
            new[#new + 1] = id
        end
    end
    order = new
end

--- All terminals in the current TAB ORDER (what the tab bar renders).
---@return LvimTerminal[]
function M.all()
    local out = {}
    for _, id in ipairs(M.ids()) do
        out[#out + 1] = terms[id]
    end
    return out
end

--- Number of terminals.
---@return integer
function M.count()
    return #M.ids()
end

--- The current terminal id (last shown), or nil.
---@return integer?
function M.current()
    return current_id
end

--- Mark `id` current (called by ui when a terminal is shown).
---@param id integer
function M.set_current(id)
    if terms[id] then
        current_id = id
    end
end

--- The id after/before `id` in the TAB order (wraps), for next/prev. nil when empty.
---@param id integer?
---@param delta integer  +1 next, -1 prev
---@return integer?
function M.neighbour(id, delta)
    local ids = M.ids()
    if #ids == 0 then
        return nil
    end
    local idx = 1
    for i, v in ipairs(ids) do
        if v == id then
            idx = i
            break
        end
    end
    local n = ((idx - 1 + delta) % #ids) + 1
    return ids[n]
end

return M
