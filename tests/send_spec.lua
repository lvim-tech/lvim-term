-- What is actually written into the terminal's job.
--
-- A send is executed by the SHELL, which makes the quoting a correctness question with teeth: the
-- module says so and chooses `shellescape` over `fnameescape` for exactly that reason. A path like
-- `demo$(uname).py` would otherwise run the substitution, and `foo;rm.py` would split into two
-- commands. The suite intercepts `chansend` and reads the bytes.

local send = require("lvim-term.send")
local manager = require("lvim-term.manager")

--- Record every chansend payload while `fn` runs, with a pretend terminal as the target.
---@param fn fun(): any
---@return string[] payloads
---@return any result
local function sent(fn)
    local payloads = {}
    local real_chansend = vim.fn.chansend
    local real_get, real_current, real_spawn = manager.get, manager.current, manager.spawn

    vim.fn.chansend = function(_, data)
        payloads[#payloads + 1] = data
        return 1
    end
    -- A terminal that exists only for the test: `send` needs an id and a job to write to.
    local fake = { id = 1, job_id = 99 }
    manager.get = function()
        return fake
    end
    manager.current = function()
        return 1
    end
    manager.spawn = function()
        return fake
    end

    local ok, result = pcall(fn)

    vim.fn.chansend = real_chansend
    manager.get, manager.current, manager.spawn = real_get, real_current, real_spawn
    truthy(ok, tostring(result))
    return payloads, result
end

--- A named buffer whose file is `name` (never created on disk -- only its name is sent).
---@param name string
local function buffer_named(name)
    vim.cmd("enew!")
    vim.api.nvim_buf_set_name(0, vim.fn.tempname() .. "/" .. name)
end

describe("lvim-term: sending text")

it("the payload is the text plus a carriage return", function()
    local payloads = sent(function()
        return send.send("echo hi")
    end)
    eq({ "echo hi\r" }, payloads)
end)

it("a send can leave the newline off", function()
    local payloads = sent(function()
        return send.send("partial", nil, { newline = false })
    end)
    eq({ "partial" }, payloads, "for a prompt the user will finish themselves")
end)

it("interrupt sends Ctrl-C before the command, which is what rerun means", function()
    local payloads = sent(function()
        return send.send("make", nil, { interrupt = true })
    end)
    eq({ "\3", "make\r" }, payloads)
end)

it("clear sends Ctrl-L, after the interrupt and before the command", function()
    local payloads = sent(function()
        return send.send("make", nil, { interrupt = true, clear = true })
    end)
    eq({ "\3", "\12", "make\r" }, payloads)
end)

it("with no terminal and nothing to spawn, a send reports failure", function()
    local real_get, real_current, real_spawn = manager.get, manager.current, manager.spawn
    manager.get = function()
        return nil
    end
    manager.current = function()
        return nil
    end
    manager.spawn = function()
        return nil
    end
    local ok = send.send("echo hi")
    manager.get, manager.current, manager.spawn = real_get, real_current, real_spawn
    eq(false, ok, "a send with nowhere to go is false, not an error")
end)

describe("lvim-term: sending the current file")

it("the path is quoted for the SHELL, not for the cmdline", function()
    -- The exact case the module's comment names: a command substitution in a filename.
    buffer_named("demo$(uname).py")
    local payloads = sent(function()
        return send.send_file("python")
    end)
    eq(1, #payloads)
    local cmd = payloads[1]

    truthy(cmd:match("^python "), cmd)
    truthy(cmd:find("'", 1, true), "shellescape wraps the path in single quotes: " .. cmd)
    eq(nil, cmd:match("\\%$"), "a cmdline backslash-escape is the wrong domain here: " .. cmd)
    -- Inside single quotes the shell performs no substitution at all, which is the point.
    truthy(cmd:find("$(uname)", 1, true), "the name itself is preserved verbatim: " .. cmd)
end)

it("a semicolon in a filename cannot split the command", function()
    buffer_named("foo;rm.py")
    local cmd = sent(function()
        return send.send_file("python")
    end)[1]
    -- fnameescape leaves a `;` alone, so this is the case that would have become two commands.
    truthy(cmd:match("^python '"), cmd)
    truthy(cmd:find("foo;rm.py'", 1, true), cmd)
end)

it("a space in a filename survives as one argument", function()
    buffer_named("my file.py")
    local cmd = sent(function()
        return send.send_file("python")
    end)[1]
    truthy(cmd:find("my file.py", 1, true), cmd)
    truthy(cmd:match("'[^']*my file%.py[^']*'"), "quoted as a single word: " .. cmd)
end)

it("without a runner, the path alone is sent", function()
    buffer_named("plain.sh")
    local cmd = sent(function()
        return send.send_file()
    end)[1]
    eq(nil, cmd:match("^%a+ '"), "no runner prefix: " .. cmd)
    truthy(cmd:find("plain.sh", 1, true), cmd)
end)

it("an unnamed buffer has no file to send", function()
    vim.cmd("enew!")
    eq(false, send.send_file("python"), "there is no path, so there is nothing to run")
end)

describe("lvim-term: sending the selection")

it("the selected lines go as one payload, newline separated", function()
    vim.cmd("enew!")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "one", "two", "three", "four" })
    vim.fn.setpos("'<", { 0, 2, 1, 0 })
    vim.fn.setpos("'>", { 0, 3, 1, 0 })

    local payloads = sent(function()
        return send.send_selection()
    end)
    eq({ "two\rthree\r" }, payloads, "one payload, so a bracketed-paste REPL sees one block")
end)

it("a single selected line is sent with its newline", function()
    vim.cmd("enew!")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "only" })
    vim.fn.setpos("'<", { 0, 1, 1, 0 })
    vim.fn.setpos("'>", { 0, 1, 1, 0 })
    eq({ "only\r" }, (sent(function()
        return send.send_selection()
    end)))
end)

it("with no selection there is nothing to send", function()
    vim.cmd("enew!")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "x" })
    vim.fn.setpos("'<", { 0, 0, 0, 0 })
    vim.fn.setpos("'>", { 0, 0, 0, 0 })
    eq(false, send.send_selection())
end)
