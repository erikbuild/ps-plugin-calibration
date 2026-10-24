-- ABOUTME: PA Pattern calibration plugin: prints the Ellis pressure-advance pattern
-- ABOUTME: via a handle object plus per-layer custom G-code with printed value labels.

-- `require` is unavailable at scan time, so params are written literally; tests in
-- tests/test_firmware.lua keep the firmware param equal to firmware.PARAM.
info = {
    id = "pa_pattern",
    type = "project.plugin",
    title = "PA Pattern",
    menu = "Calibration/PA Pattern",
    params = {
        {name = "tool", label = "Extruder / Tool (1 = T0, 2 = T1...)", type = "int", default = 1},
        {name = "use_lines", label = "Use Lines Pattern", type = "bool", default = true},
        {name = "draw_labels", label = "Print Labels", type = "bool", default = true},
        {name = "nozzle", label = "Nozzle [mm] (0 = auto)", type = "string", default = "0"},
        {name = "layer_height", label = "Layer Height [mm] (0 = auto)", type = "string", default = "0"},
        -- PA values are strings: the dialog's float control rounds to whole
        -- numbers (upstream bug), so fractional values cannot use type "float".
        {name = "pa_start", label = "PA Start", type = "string", default = "0"},
        {name = "pa_end", label = "PA End", type = "string", default = "0.08"},
        {name = "pa_step", label = "PA Step", type = "string", default = "0.005"},
        {name = "speed", label = "Speed [mm/s] (0 = auto)", type = "int", default = 0},
        {name = "accel", label = "Acceleration [mm/s^2] (0 = leave alone)", type = "int", default = 0},
        {name = "bed_width", label = "Bed Width [mm]", type = "int", default = 250},
        {name = "bed_depth", label = "Bed Depth [mm]", type = "int", default = 220},
        {
            name = "firmware",
            label = "Firmware (auto|marlin|marlin2|prusabuddy|klipper|rrf)",
            type = "string",
            default = "auto",
        },
    },
}

function execute(opts)
    local util = require("plugin_util")
    local firmware = require("firmware")
    local gen = require("pa_pattern_gen")

    local bed = api.project:current_bed()
    local flavor = firmware.from_bed(bed, opts.firmware)
    if firmware.set_pressure_advance(flavor, 0) == nil then
        util.show_error("PA Pattern", "PA: NO PA COMMAND FOR " .. flavor)
        return
    end

    local rel_e = util.guarded(true, function()
        return bed:printer_presets():value("use_relative_e_distances")
    end)
    if rel_e ~= true then
        util.show_error("PA Pattern", "PA: NEEDS RELATIVE E")
        return
    end

    local tool_idx = math.max(1, opts.tool or 1)
    local slot_idx = tool_idx - 1
    
    local ui_nozzle = util.parse_number(opts.nozzle, 0)
    local ui_lh = util.parse_number(opts.layer_height, 0)

    -- Opravená logika přepínače: výchozí stav (doprava) = true -> tiskne se "lines"
    local is_lines = (opts.use_lines == false)

    local S = {
        tool_idx = tool_idx,
        slot_idx = slot_idx,
        pattern = is_lines and "lines" or "ellis",
        draw_labels = (opts.draw_labels == false),
        pa_start = util.parse_number(opts.pa_start, 0),
        pa_end = util.parse_number(opts.pa_end, 0.08),
        pa_step = util.parse_number(opts.pa_step, 0.005),
        speed = opts.speed,
        accel = opts.accel,
        bed_w = opts.bed_width,
        bed_d = opts.bed_depth,
        flavor = flavor,
        layer_height = (ui_lh > 0) and ui_lh or util.guarded(0.2, function()
            return bed:print_presets():value("layer_height")
        end),
        nozzle = (ui_nozzle > 0) and ui_nozzle or util.guarded(0.4, function()
            local tools = bed:printer_config().tools
            if tools and tools[tool_idx] then
                return tools[tool_idx]:nozzle_diameter()
            end
            return tools[1]:nozzle_diameter()
        end),
        perimeter_speed = util.guarded(0, function()
            return bed:print_presets():value("perimeter_speed")
        end),
        travel_speed = util.guarded(150, function()
            return bed:print_presets():value("travel_speed")
        end),
        vol_cap = util.guarded(0, function()
            return bed:material_presets(slot_idx):value("filament_max_volumetric_speed")
        end),
        filament_d = util.guarded(1.75, function()
            return bed:material_presets(slot_idx):value("filament_diameter")
        end),
        flow_mult = util.guarded(1.0, function()
            return bed:material_presets(slot_idx):value("extrusion_multiplier")
        end),
        retract = util.guarded(0.8, function()
            return bed:print_presets():value("retract_length")
        end),
        retract_speed = util.guarded(35, function()
            return bed:print_presets():value("retract_speed")
        end),
        deretract_speed = util.guarded(0, function()
            return bed:print_presets():value("deretract_speed")
        end),
        zhop = util.guarded(0.5, function()
            return bed:print_presets():value("retract_lift")
        end),
        retract_layer_change = util.guarded(true, function()
            return bed:print_presets():value("retract_layer_change")
        end),
    }

    if S.pa_start < 0 or S.pa_step <= 0 or S.pa_end < S.pa_start + S.pa_step then
        util.show_error("PA Pattern", "PA: BAD RANGE")
        return
    end

    local r = gen.build(S)

    -- Force slicer to use selected tool for global settings and wiping
    bed:print_presets():set("perimeter_extruder", tool_idx)
    bed:print_presets():set("infill_extruder", tool_idx)
    bed:print_presets():set("solid_infill_extruder", tool_idx)
    bed:print_presets():set("support_material_extruder", tool_idx)
    bed:print_presets():set("support_material_interface_extruder", tool_idx)

    -- Known layer grid (first_layer_height is unreadable but settable), and keep
    -- slicer-drawn loops out of the pattern area.
    bed:print_presets():set("first_layer_height", S.layer_height)
    bed:print_presets():set("brim_type", "none")
    bed:print_presets():set("skirts", 0)

    -- Custom-gcode inserts poke the bed instance directly and fire no
    -- slicing-input-changed event; add_object does. Inserting first means the
    -- snapshot taken when the handle appears carries the blobs with it.
    api.project:clear_layer_custom_steps(bed)
    for _, layer in ipairs(r.layers) do
        api.project:insert_layer_custom_gcode(bed, layer.insert_z, layer.gcode)
    end
    api.project:add_object{
        mesh = api.make_cube(gen.HANDLE_XY, gen.HANDLE_XY, r.handle.height),
        type = VolumeType.Solid,
        extruder = S.tool_idx,
    }

    print(string.format("PA Pattern: Tool T%d, %s, %s, PA %g..%g step %g, speed %d mm/s",
                        S.slot_idx, flavor, S.pattern, S.pa_start, r.pa_end_effective, S.pa_step, r.speed))
    if r.clamped then
        print(string.format("PA Pattern: range clamped to fit the bed; PA End now %g",
                            r.pa_end_effective))
    end
end