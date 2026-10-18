-- ABOUTME: Max Volumetric Flow plugin: prints Orca's single-wall comb tower with one speed
-- ABOUTME: modifier per layer so flow climbs start + z * step, plus a note badge.

info = {
    id = "max_volumetric_flow",
    type = "project.plugin",
    title = "Max Volumetric Flow",
    menu = "Calibration/Max Volumetric Flow",
    params = {
        -- Flow values are strings: the dialog's float control rounds to whole
        -- numbers (upstream bug), so fractional values cannot use type "float".
        {name = "flow_start", label = "Start Flow [mm^3/s]", type = "string", default = "5"},
        {name = "flow_end", label = "End Flow [mm^3/s]", type = "string", default = "20"},
        {name = "flow_step", label = "Step [mm^3/s per mm]", type = "string", default = "0.5"},
        {name = "extruder", label = "Extruder", type = "int", default = 1},
        {name = "note", label = "Note (badge line 2)", type = "string", default = ""},
        {name = "bed_width", label = "Bed Width [mm]", type = "int", default = 250},
    },
}

function execute(opts)
    local util = require("plugin_util")
    local gen = require("max_volumetric_flow_gen")

    local bed = api.project:current_bed()

    -- extruder ids are material slots; a slot that doesn't exist throws
    local extruder = opts.extruder
    if extruder < 1 or not pcall(function() return bed:material_presets(extruder - 1) end) then
        util.show_error("Max Volumetric Flow", "MAXFLOW: BAD EXTRUDER")
        return
    end
    local slot = bed:material_presets(extruder - 1)
    -- a single-tool printer with an MMU has several slots on tool 1
    local tool_count = util.guarded(1, function() return bed:printer_config().tool_count end)
    local tool = (tool_count == 1) and 1 or extruder

    local S = {
        flow_start = util.parse_number(opts.flow_start, 5),
        flow_end = util.parse_number(opts.flow_end, 20),
        flow_step = util.parse_number(opts.flow_step, 0.5),
        nozzle = util.guarded(0.4, function()
            return bed:printer_config().tools[tool]:nozzle_diameter()
        end),
        flow_mult = util.guarded(1.0, function()
            return slot:value("extrusion_multiplier")
        end),
        temperature = util.guarded(false, function() return slot:value("temperature") end),
        high_flow = util.guarded(false, function()
            return bed:printer_config().tools[tool]:feature("nozzle_high_flow")
        end),
        note = opts.note or "",
        bed_w = opts.bed_width,
    }
    if S.temperature == false then S.temperature = nil end

    local plan = gen.build(S)
    if plan.error then
        util.show_error("Max Volumetric Flow", plan.error)
        return
    end
    local h = plan.h

    -- Measured before any preset write, so a too-long note changes nothing.
    local text = api.emboss_text{font = api.get_default_font(), text = plan.badge_text,
                                 depth = 2 * h, line_height = gen.BADGE_LINE_HEIGHT}
    local tb = text:bounds()
    local text_w, text_d = tb.max_x - tb.min_x, tb.max_y - tb.min_y
    if text_w + 2 * gen.BADGE_PAD > gen.COMB_W then
        util.show_error("Max Volumetric Flow", "MAXFLOW: NOTE TOO LONG")
        return
    end

    -- Every limit that can cap the wall speed, on the extruder the tower
    -- prints with. These stay in the project's presets: the plugin exits
    -- before slicing and cannot restore them.
    slot:set("filament_max_volumetric_speed", 0)
    slot:set("slowdown_below_layer_time", 0)
    -- Z shrinkage compensation stretches the object, modifiers included, so
    -- the speed bands drift off the layer grid (half a layer by 73 mm at 0.22%).
    slot:set("filament_shrinkage_compensation_z", 0)
    bed:print_presets():set("layer_height", h)
    -- the tool's print preset wins over the print preset on multi-tool printers
    for _, box in ipairs{bed:print_presets(), bed:tool_print_presets(tool - 1)} do
        box:set("first_layer_height", h)
        box:set("max_volumetric_speed", 0)
        box:set("max_volumetric_extrusion_rate_slope_positive", 0)
        box:set("max_volumetric_extrusion_rate_slope_negative", 0)
    end

    -- Leftover per-layer blobs from our other calibrations survive object
    -- deletion and would print inside the comb.
    api.project:clear_layer_custom_steps(bed)

    local comb = api.emboss_svg(gen.COMB_SVG, plan.height)
    local bb = comb:bounds()

    -- one speed region per layer: layer k sits in [(k-1)h, kh]
    local m = gen.MODIFIER_MARGIN
    local volumes = {}
    for k = 1, plan.layers do
        table.insert(volumes, {
            mesh = api.make_cube(bb.max_x - bb.min_x + 2 * m, bb.max_y - bb.min_y + 2 * m, h),
            translate = {x = bb.min_x - m, y = bb.min_y - m, z = (k - 1) * h},
            type = VolumeType.Modifier,
            params = {perimeter_speed = plan.speeds[k], external_perimeter_speed = plan.speeds[k]},
        })
    end

    -- note badge in front of the comb, centered in X
    local pad = gen.BADGE_PAD
    local bg_w, bg_d = text_w + 2 * pad, text_d + 2 * pad
    local bg_x = (bb.min_x + bb.max_x) / 2 - bg_w / 2
    local bg_y = bb.min_y - gen.BADGE_GAP - bg_d
    table.insert(volumes, {
        mesh = api.make_cube(bg_w, bg_d, 2 * h),
        translate = {x = bg_x, y = bg_y, z = 0},
        type = VolumeType.Solid,
    })
    table.insert(volumes, {
        mesh = text,
        translate = {x = bg_x + pad - tb.min_x, y = bg_y + pad - tb.min_y, z = 2 * h - tb.min_z},
        type = VolumeType.Solid,
    })

    api.project:add_object{
        mesh = comb,
        translate = {z = -bb.min_z},
        params = {
            perimeters = 1,
            fill_density = "0%",
            top_solid_layers = 0,
            bottom_solid_layers = 0,
            external_perimeter_extrusion_width = plan.w,
        },
        object_params = {
            extruder = extruder,
            brim_type = "outer_and_inner",
            brim_width = 5,
            brim_separation = 0,
        },
        other_volumes = volumes,
    }

    print(string.format(
        "Max Volumetric Flow: %g..%g mm3/s (+%g/mm), %d layers at %.2f mm, %d..%d mm/s, extruder %d",
        S.flow_start, plan.top_flow, S.flow_step, plan.layers, h,
        plan.speeds[1], plan.speeds[plan.layers], extruder))
end
