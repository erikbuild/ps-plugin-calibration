-- ABOUTME: Flow-ratio calibration plugin: prints a grid of pads at stepped flow
-- ABOUTME: multipliers via per-layer custom G-code, each labeled on a tab.

info = {
    id = "flow_ratio",
    type = "project.plugin",
    title = "Flow Ratio",
    menu = "Calibration/Flow Ratio",
    params = {
        {name = "mode", label = "Mode (coarse|fine)", type = "string",
         default = "coarse"},
        {name = "pattern", label = "Top Pattern (archimedean|monotonic)",
         type = "string", default = "archimedean"},
        {name = "speed", label = "Speed [mm/s] (0 = auto)", type = "int",
         default = 0},
        {name = "bed_width", label = "Bed Width [mm]", type = "int",
         default = 250},
        {name = "bed_depth", label = "Bed Depth [mm]", type = "int",
         default = 220},
    },
}

function execute(opts)
    local util = require("plugin_util")
    local gen = require("flow_ratio_gen")

    local bed = api.project:current_bed()

    local rel_e = util.guarded(true, function()
        return bed:printer_presets():value("use_relative_e_distances")
    end)
    if rel_e ~= true then
        util.show_error("Flow Ratio", "FLOW: NEEDS RELATIVE E")
        return
    end

    local S = {
        mode = opts.mode,
        pattern = opts.pattern,
        speed = opts.speed,
        bed_w = opts.bed_width,
        bed_d = opts.bed_depth,
        nozzle = util.guarded(0.4, function()
            return bed:printer_config().tools[1]:nozzle_diameter()
        end),
        perimeter_speed = util.guarded(0, function()
            return bed:print_presets():value("perimeter_speed")
        end),
        travel_speed = util.guarded(150, function()
            return bed:print_presets():value("travel_speed")
        end),
        vol_cap = util.guarded(0, function()
            return bed:material_presets(0):value("filament_max_volumetric_speed")
        end),
        filament_d = util.guarded(1.75, function()
            return bed:material_presets(0):value("filament_diameter")
        end),
        flow_mult = util.guarded(1.0, function()
            return bed:material_presets(0):value("extrusion_multiplier")
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

    local r = gen.build(S)
    if not r.fits then
        util.show_error("Flow Ratio", "FLOW: BED TOO SMALL")
        return
    end

    -- Known layer grid: the handle's slicing must match the blob z schedule.
    bed:print_presets():set("layer_height", S.nozzle / 2)
    bed:print_presets():set("first_layer_height", S.nozzle / 2)
    bed:print_presets():set("brim_type", "no_brim")
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
    }

    print(string.format(
        "Flow Ratio: %s/%s, flow %.3f..%.3f (baseline %.3f), speed %d mm/s",
        opts.mode, opts.pattern, r.v_min, r.v_max, S.flow_mult, r.speed))
end
