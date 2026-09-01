-- ABOUTME: Determines which G-code dialect the active printer speaks, and builds
-- ABOUTME: dialect-correct commands for calibration plugins that emit custom G-code.

local M = {}

--- Parameter to splice into a plugin's info.params. The dialog has no dropdown control,
--- so this is a free-text field whose label carries the valid values, and "auto" leaves
--- the choice to detection. A default is mandatory: a param without one aborts the
--- application during the startup plugin scan.
M.PARAM = {
    name = "firmware",
    label = "Firmware (auto|marlin|marlin2|prusabuddy|klipper|rrf)",
    type = "string",
    default = "auto",
}

--- Dialects this module can emit commands for. Anything outside this set is treated
--- as unusable input, not as an error.
M.FLAVORS = {
    marlin = true, marlin2 = true, prusabuddy = true,
    klipper = true, rrf = true, repetier = true,
    mach3 = true, machinekit = true,
}

--- Infer the dialect from what the plugin API lets us observe about the printer.
-- gcode_flavor is unreadable from Lua and printer_vendor/printer_variant come back empty,
-- so printer_model is the only identifier available. Every Prusa printer in the shipped
-- bundle runs marlin2 except the CORE One INDX family, which runs prusabuddy and reports
-- models like "COREONE_INDX8T" -- the suffix is a tool-count variant marker, so match the
-- family rather than one exact string.
-- @param model string|nil printer_model, may be empty
function M.detect(model)
    if model and model:find("INDX", 1, true) then
        return "prusabuddy"
    end
    return "marlin2"
end

--- Pick a dialect from the user's choice, falling back to detection.
-- "auto", an empty value, or anything unrecognised all fall through to detection:
-- plugin runtime errors are invisible in the UI, so bad input must never throw.
-- @param requested string|nil the firmware parameter's value
function M.resolve(requested, model)
    if requested and M.FLAVORS[requested] then
        return requested
    end
    return M.detect(model)
end

--- Resolve a dialect from the live project.
-- The only function here that touches the plugin API, and so the only one not unit
-- tested. Every read is guarded: a plugin runtime error closes the dialog with no
-- message to the user, so an unexpected API shape must degrade to detection rather
-- than take the whole run down.
-- @param bed BedInstRef from api.project:current_bed()
-- @param requested string|nil the firmware parameter's value
function M.from_bed(bed, requested)
    local ok, model = pcall(function()
        return bed:printer_presets():value("printer_model")
    end)
    if not ok or type(model) ~= "string" then model = "" end
    return M.resolve(requested, model)
end

--- Set the hotend temperature, without waiting.
-- @param flavor string a value from M.FLAVORS
-- @param celsius number target temperature; emitted as a whole number
function M.set_temperature(flavor, celsius)
    local degrees = math.floor(celsius + 0.5)
    if flavor == "rrf" then
        return string.format("G10 S%d", degrees)          -- M104 is deprecated on RRF
    elseif flavor == "mach3" or flavor == "machinekit" then
        return string.format("M104 P%d", degrees)         -- P rather than S
    end
    return string.format("M104 S%d", degrees)
end

--- Set the pressure advance / linear advance factor.
-- Returns nil where the dialect has no equivalent, so a caller can skip the
-- calibration rather than emit a command the controller will ignore or misread.
-- @param flavor string a value from M.FLAVORS
-- @param k number the advance factor
function M.set_pressure_advance(flavor, k)
    local value = string.format("%g", k)
    if flavor == "klipper" then
        return "SET_PRESSURE_ADVANCE ADVANCE=" .. value
    elseif flavor == "rrf" then
        return "M572 D0 S" .. value
    elseif flavor == "repetier" then
        return string.format("M233 X%s Y%s", value, value)
    elseif flavor == "prusabuddy" then
        return "M572 S" .. value                  -- Buddy-native; M900 only converted
    elseif flavor == "mach3" or flavor == "machinekit" then
        return nil
    end
    return "M900 K" .. value
end

return M
