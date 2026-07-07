-- lvim-term.highlights: the terminal-body + tab-accent groups, self-themed from the palette.
-- The display rides the lvim-ui surface chassis, so the tab bar / footer / title use the chassis'
-- own LvimUi* groups; lvim-term only adds the groups the chassis has no concept of — the terminal
-- window body and the red/green accent OVERRIDES merged over the chassis tab boxes (an exited tab,
-- the per-tab kill glyph, the `+` new button). Accents are fg-only where they sit ON the chassis
-- bar strip (so its fill bg shows through); the "Active" variants add the mtint block (accent
-- blended toward bg at the shared 0.3 — the button-state canon). build() reads the live palette;
-- bound via lvim-utils.highlight.bind in init so the groups re-derive on ColorScheme / palette sync.
--
---@module "lvim-term.highlights"

local c = require("lvim-utils.colors")
local hl = require("lvim-utils.highlight")

local M = {}

--- Blend an accent toward the editor bg (the shared "mtint" convention).
---@param accent string
---@param t number
---@return string
local function mtint(accent, t)
    return hl.blend(accent, c.bg, t)
end

--- The terminal highlight groups from the live palette.
---@return table<string, table>
function M.build()
    return {
        -- The terminal window body: the panel dark bg, so a docked terminal reads as chrome.
        LvimTermNormal = { bg = c.bg_dark },
        -- The red "dead" accent — an EXITED tab's boxes. fg-only, so the chassis bar-fill bg shows
        -- through; Active/hover raises it onto a soft red block.
        LvimTermTabExited = { fg = c.red },
        LvimTermTabExitedActive = { fg = c.red, bg = mtint(c.red, 0.3), bold = true },
        -- The per-tab kill `×` box: a translucent red block ALWAYS (space-padded, reads as a button),
        -- INTENSIFYING on hover/active (the red block deepens 0.2 → 0.4).
        LvimTermKill = { fg = c.red, bg = mtint(c.red, 0.2) },
        LvimTermKillActive = { fg = c.red, bg = mtint(c.red, 0.4), bold = true },
        -- The green `+` new-terminal button: a translucent green block ALWAYS (space-padded, reads as a
        -- button — the mirror of the red `×` kill box), INTENSIFYING on hover/active (0.2 → 0.4).
        LvimTermTabNew = { fg = c.green, bg = mtint(c.green, 0.2), bold = true },
        LvimTermTabNewActive = { fg = c.green, bg = mtint(c.green, 0.4), bold = true },
    }
end

return M
