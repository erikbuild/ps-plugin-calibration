-- ABOUTME: Shared helpers for plugin glue scripts: guarded preset reads,
-- ABOUTME: plate-visible error reporting, and numeric param parsing.

local M = {}

--- Run fn safely; any error or nil result yields the fallback. Runtime errors
--- are invisible in the UI, so no preset read is allowed to take the run down.
function M.guarded(fallback, fn)
    local ok, v = pcall(fn)
    if ok and v ~= nil then return v end
    return fallback
end

--- Failures must be visible: emboss the message as an object on the plate.
function M.show_error(prefix, msg)
    print(prefix .. ": " .. msg)
    local ok = pcall(function()
        api.project:add_object{
            mesh = api.emboss_text{font = api.get_default_font(),
                                   text = msg, depth = 1},
            type = VolumeType.Solid,
        }
    end)
    if not ok then print(prefix .. ": could not create the error object") end
end

--- Parse a numeric string param; garbage or nil yields the fallback.
function M.parse_number(s, default)
    local v = tonumber(s)
    if v == nil then return default end
    return v
end

return M
