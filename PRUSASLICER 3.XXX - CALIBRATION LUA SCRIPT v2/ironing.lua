-- ABOUTME: Ironing calibration plugin: prints a 2D matrix of pads testing
-- ABOUTME: combinations of ironing flow (%) and ironing speed (mm/s).

info = {
    id = "ironing",
    type = "project.plugin",
    title = "Ironing",
    menu = "Calibration/Ironing",
    params = {
        {name = "tool", label = "Extruder / Tool (1 = T0, 2 = T1...)", type = "int", default = 1},
        {name = "nozzle", label = "Nozzle [mm] (0 = auto)", type = "string", default = "0"},
        {name = "layer_height", label = "Layer Height [mm] (0 = auto)", type = "string", default = "0"},
        {name = "flow_start", label = "Start Ironing Flow [%]", type = "string", default = "10"},
        {name = "flow_step", label = "Ironing Flow Step [%]", type = "string", default = "5"},
        {name = "flow_count", label = "Flow Sample Count (Columns)", type = "int", default = 4},
        {name = "speed_start", label = "Start Ironing Speed [mm/s]", type = "string", default = "15"},
        {name = "speed_step", label = "Ironing Speed Step [mm/s]", type = "string", default = "15"},
        {name = "speed_count", label = "Speed Sample Count (Rows)", type = "int", default = 3},
        {name = "spacing", label = "Ironing Line Spacing [mm]", type = "string", default = "0.1"},
        {name = "base_speed", label = "Base Print Speed [mm/s] (0 = auto)", type = "int", default = 0},
        {name = "bed_width", label = "Bed Width [mm]", type = "int", default = 250},
        {name = "bed_depth", label = "Bed Depth [mm]", type = "int", default = 220},
    },
}

function execute(opts)
    local util = require("plugin_util")
    local gen = require("ironing_gen")

    local bed = api.project:current_bed()

    local rel_e = util.guarded(true, function()
        return bed:printer_presets():value("use_relative_e_distances")
    end)
    if rel_e ~= true then
        util.show_error("Ironing", "IRONING: NEEDS RELATIVE E")
        return
    end

    local tool_idx = math.max(1, opts.tool or 1)
    local slot_idx = tool_idx - 1

    local ui_nozzle = util.parse_number(opts.nozzle, 0)
    local ui_lh = util.parse_number(opts.layer_height, 0)

    local S = {
        tool_idx = tool_idx,
        slot_idx = slot_idx,
        flow_start = util.parse_number(opts.flow_start, 10),
        flow_step = util.parse_number(opts.flow_step, 5),
        flow_count = math.max(1, opts.flow_count or 4),
        speed_start = util.parse_number(opts.speed_start, 15),
        speed_step = util.parse_number(opts.speed_step, 15),
        speed_count = math.max(1, opts.speed_count or 3),
        spacing = util.parse_number(opts.spacing, 0.1),
        speed = opts.base_speed,
        bed_w = opts.bed_width,
        bed_d = opts.bed_depth,
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

    if S.flow_start <= 0 or S.speed_start <= 0 or S.spacing <= 0 then
        util.show_error("Ironing", "IRONING: BAD PARAMS")
        return
    end

    local r = gen.build(S)
    if not r.fits then
        util.show_error("Ironing", "IRONING: BED TOO SMALL")
        return
    end

    local layer_h = S.layer_height
    bed:print_presets():set("layer_height", layer_h)
    bed:print_presets():set("first_layer_height", layer_h)
    bed:print_presets():set("brim_type", "no_brim")
    bed:print_presets():set("skirts", 0)
    pcall(function() bed:print_presets():set("ironing", false) end)

    -- Force slicer to use selected tool for global settings and wiping
    bed:print_presets():set("perimeter_extruder", tool_idx)
    bed:print_presets():set("infill_extruder", tool_idx)
    bed:print_presets():set("solid_infill_extruder", tool_idx)
    bed:print_presets():set("support_material_extruder", tool_idx)
    bed:print_presets():set("support_material_interface_extruder", tool_idx)

    api.project:clear_layer_custom_steps(bed)
    for _, layer in ipairs(r.layers) do
        api.project:insert_layer_custom_gcode(bed, layer.insert_z, layer.gcode)
    end

    api.project:add_object{
        mesh = api.make_cube(gen.HANDLE_XY, gen.HANDLE_XY, r.handle.height),
        type = VolumeType.Solid,
        extruder = S.tool_idx,
    }

    print(string.format(
        "Ironing: Tool T%d, %dx%d grid, flow %g..%g%% (step %g%%), speed %g..%g mm/s (step %g), spacing %.2f mm",
        S.slot_idx, S.flow_count, S.speed_count,
        r.flow_min, r.flow_max, S.flow_step,
        r.speed_min, r.speed_max, S.speed_step, S.spacing))
end