-- lvim-term.highlights: the terminal window + tab-bar groups, self-themed from the palette.
-- The tab bar follows the button-state canon: the ACTIVE tab is the full accent on a soft accent
-- block (mtint 0.3), inactive tabs a dim tint (0.6), an EXITED tab the red "dead" accent. build()
-- reads the live palette; bound via lvim-utils.highlight.bind in init so the groups re-derive on
-- ColorScheme / palette sync.
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

--- The terminal + tab-bar highlight groups from the live palette.
---@return table<string, table>
function M.build()
    return {
        -- The terminal window body: the panel dark bg, so a docked terminal reads as chrome.
        LvimTermNormal = { bg = c.bg_dark },
        -- Tab bar: active = full blue on a soft blue block; inactive = a dim blue tint;
        -- exited = the red "dead" accent; new = the green "+".
        LvimTermTabActive = { fg = c.blue, bg = mtint(c.blue, 0.3), bold = true },
        LvimTermTabInactive = { fg = mtint(c.blue, 0.6), bg = c.bg_dark },
        LvimTermTabExited = { fg = c.red, bg = c.bg_dark },
        LvimTermTabNew = { fg = c.green, bg = c.bg_dark, bold = true },
        -- The winbar fill strip to the right of the tabs.
        LvimTermWinbarFill = { bg = c.bg_dark },
        -- The winbar TITLE block (" terminal ") leading the tab bar — a soft blue block (the
        -- peek-title canon) so it reads as a titled header WITH a background, not loose text.
        LvimTermTitle = { fg = c.blue, bg = mtint(c.blue, 0.3), bold = true },
    }
end

return M
