-- lvim-term: :checkhealth lvim-term.
-- Reports the shell that terminals run, the lvim-utils base (palette/theming + the dock manager),
-- lvim-ui (the REQUIRED surface chassis every display frame rides — plus kill-confirm + select),
-- and lvim-msgarea (hosts the `area` layout's zone; without it the surface grows cmdheight itself).
-- Read-only.
--
---@module "lvim-term.health"

local config = require("lvim-term.config")
local manager = require("lvim-term.manager")

local M = {}

--- Entry point for `:checkhealth lvim-term`.
---@return nil
function M.check()
    local health = vim.health
    health.start("lvim-term")

    local shell = config.shell or vim.o.shell
    if shell and shell ~= "" and vim.fn.executable(vim.split(shell, "%s+")[1]) == 1 then
        health.ok(("shell: %s"):format(shell))
    else
        health.error(("shell %q is not executable — terminals cannot start"):format(tostring(shell)))
    end

    if pcall(require, "lvim-utils.colors") then
        health.ok("lvim-utils found (palette + theming)")
    else
        health.error("lvim-utils not found — theming is unavailable")
    end

    -- Dock-stack integration: with `dock.dock_stack = true` the terminal joins the shared managed stack
    -- (one-visible-per-layout, cyclable). Without lvim-utils.dock (an older lvim-utils) it can only
    -- open standalone regardless of the flag — report both the module and the configured mode.
    if pcall(require, "lvim-utils.dock") then
        health.ok(
            ("lvim-utils.dock found — dock.dock_stack = %s (%s)"):format(
                tostring(config.dock.dock_stack),
                config.dock.dock_stack and "managed dock stack" or "standalone, geometry-only"
            )
        )
    else
        health.info("lvim-utils.dock not found — the terminal opens standalone (dock.dock_stack has no effect)")
    end

    if pcall(require, "lvim-ui") then
        health.ok("lvim-ui found (kill-confirm + select chooser)")
    else
        health.info("lvim-ui not found — kill skips the confirm and select is disabled (tabs still work)")
    end

    -- The `area` layout docks in the lvim-msgarea zone (which owns the dock height); without it (or
    -- with the zone disabled) `area` falls back to the bottom dock — degraded, not broken.
    local has_msgarea, msgarea = pcall(require, "lvim-msgarea")
    if has_msgarea then
        local zone_on = type(msgarea.is_enabled) == "function" and msgarea.is_enabled()
        health.ok(
            ("lvim-msgarea found (area layout docks in the zone; zone currently %s)"):format(
                zone_on and "enabled" or "disabled — area falls back to the bottom dock"
            )
        )
    else
        health.info("lvim-msgarea not found — the area layout falls back to the bottom dock")
    end

    -- Verify the configured glyphs are single-width (the tab bar / winbar rely on it).
    local bad = {}
    for name, g in pairs(config.icons or {}) do
        if vim.fn.strdisplaywidth(g) ~= 1 then
            bad[#bad + 1] = name
        end
    end
    if #bad == 0 then
        health.ok("all status glyphs are single-width")
    else
        health.warn("non-single-width glyphs: " .. table.concat(bad, ", "))
    end

    health.info(("%d terminal(s) currently in the registry"):format(manager.count()))
end

return M
