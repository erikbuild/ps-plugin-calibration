-- ABOUTME: Diagnostic plugin that reports what the firmware module can read from the
-- ABOUTME: active printer and which G-code dialect it resolves to. Changes nothing.

-- `require` does not exist while plugin metadata is being scanned at startup, so it can
-- only be called from execute(), and `info` below cannot reference the firmware module.
-- The parameter is therefore written out literally; tests keep it equal to firmware.PARAM.
info = {
    id = "firmware_probe",
    type = "project.plugin",
    title = "Firmware Probe",
    menu = "Calibration/Firmware Probe",
    params = {
        {
            name = "firmware",
            label = "Firmware (auto|marlin|marlin2|prusabuddy|klipper|rrf)",
            type = "string",
            default = "auto",
        },
    },
}

local function read(label, fn)
    local ok, value = pcall(fn)
    if ok then
        return string.format("%s = %s (%s)", label, tostring(value), type(value))
    end
    return string.format("%s -> ERROR: %s", label, tostring(value))
end

function execute(opts)
    local firmware = require('firmware')
    local bed = api.project:current_bed()
    local printer = bed:printer_presets()

    print("FIRMWARE PROBE")
    print("  " .. read("printer_model", function() return printer:value("printer_model") end))
    print("  " .. read("printer_vendor", function() return printer:value("printer_vendor") end))
    print("  " .. read("printer_variant", function() return printer:value("printer_variant") end))
    print("  " .. read("tool_count", function() return bed:printer_config().tool_count end))
    print("  " .. read("#tools", function() return #bed:printer_config().tools end))

    -- Expected to fail: gcode_flavor is an Enum, and ConfigBox:value() throws on those.
    -- Kept so we notice immediately if a later build starts returning it.
    print("  " .. read("gcode_flavor", function() return printer:value("gcode_flavor") end))

    local resolved = firmware.from_bed(bed, opts.firmware)
    print(string.format("  requested = %q", tostring(opts.firmware)))
    print("  RESOLVED  = " .. resolved)
    print("  sample temperature cmd = " .. firmware.set_temperature(resolved, 215))

    -- Candidate names for HwToolConfig:feature(); unknown names return nil.
    -- A readable bed size would replace the PA Pattern's bed_width/bed_depth params.
    local tool = bed:printer_config().tools[1]
    local candidates = {
        "bed_width", "bed_depth", "bed_size", "bed_size_x", "bed_size_y",
        "printable_area", "print_area", "bed", "x_size", "y_size",
        "filament_diameter", "hotend_type", "extruder_type", "nozzle_diameter",
    }
    print("  FEATURE CANDIDATES")
    for _, name in ipairs(candidates) do
        print("    " .. read(name, function() return tool:feature(name) end))
    end

    -- Are per-filament settings scalars in the per-slot material box?
    print("  MATERIAL PRESET SCALARS")
    print("    " .. read("filament_max_volumetric_speed", function()
        return bed:material_presets(0):value("filament_max_volumetric_speed")
    end))
    print("    " .. read("filament_diameter", function()
        return bed:material_presets(0):value("filament_diameter")
    end))
    print("    " .. read("extrusion_multiplier", function()
        return bed:material_presets(0):value("extrusion_multiplier")
    end))
    -- pressure_advance_value: scalar double per slot? pressure_advance is an
    -- enum, expected to throw until ConfigBox:value() learns enums.
    print("    " .. read("pressure_advance_value", function()
        return bed:material_presets(0):value("pressure_advance_value")
    end))
    print("    " .. read("pressure_advance", function()
        return bed:material_presets(0):value("pressure_advance")
    end))
end
