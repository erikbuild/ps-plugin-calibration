-- ABOUTME: Builds the ironing calibration plate as per-layer G-code blobs: a
-- ABOUTME: 2D grid of labeled pads with custom ironing passes on the top layer. Pure.

info = nil

local M = {}

M.PAD_W = 30.0
M.PAD_H = 20.0
M.TAB_W = 24.0
M.TAB_H = 10.0
M.TAB_LAYERS = 2
M.GAP = 8.0
M.LAYERS = 10
M.MARGIN = 10.0
M.HANDLE_XY = 5.0
M.FIRST_LAYER_SPEED = 30
M.GLYPH_SPEED = 20
M.WALL_SPEED_FRACTION = 0.6
M.TOP_SPEED_FRACTION = 0.5
M.SPARSE_DENSITY = 0.35
M.INSERT_Z_FRACTION = 0.5
M.IRONING_INSET_FRACTION = 0.25

function M.resolve_speed(draw, requested, perimeter_speed, vol_cap, line_width, layer_height)
    local speed = (requested and requested > 0) and requested
                  or math.max(100, perimeter_speed or 0)
    if vol_cap and vol_cap > 0 then
        speed = math.min(speed, vol_cap / draw.bead_area(line_width, layer_height))
    end
    return math.floor(speed)
end

local function fmt_compact(v)
    return string.format("%.3g", v)
end

function M.layout(S)
    local L = {}
    L.h = S.layer_height or (S.nozzle / 2)
    L.width = {
        wall = 1.125 * S.nozzle,
        first = 1.40 * S.nozzle,
        solid = 1.20 * S.nozzle,
    }

    local f_start = S.flow_start or 10
    local f_step = S.flow_step or 5
    local f_count = math.max(1, S.flow_count or 4)

    local s_start = S.speed_start or 15
    local s_step = S.speed_step or 15
    local s_count = math.max(1, S.speed_count or 3)

    L.cols = f_count
    L.rows = s_count

    L.flow_min = f_start
    L.flow_max = f_start + (f_count - 1) * f_step
    L.speed_min = s_start
    L.speed_max = s_start + (s_count - 1) * s_step

    local cell_w = M.PAD_W
    local cell_h = M.PAD_H + M.TAB_H
    L.pitch_x = cell_w + M.GAP
    L.pitch_y = cell_h + M.GAP
    L.span_x = L.cols * cell_w + (L.cols - 1) * M.GAP
    L.span_y = L.rows * cell_h + (L.rows - 1) * M.GAP

    local cx, cy = S.bed_w / 2, S.bed_d / 2
    L.xbase = cx - L.span_x / 2
    L.ybase = cy + M.GAP / 2 - (L.rows // 2) * L.pitch_y

    L.extents = {
        min_x = L.xbase,
        min_y = L.ybase,
        max_x = L.xbase + L.span_x,
        max_y = L.ybase + L.span_y,
    }
    L.fits = L.extents.min_x >= M.MARGIN and L.extents.min_y >= M.MARGIN
             and L.extents.max_x <= S.bed_w - M.MARGIN
             and L.extents.max_y <= S.bed_d - M.MARGIN

    L.pads = {}
    for r = 0, L.rows - 1 do
        local ir_speed = s_start + r * s_step
        for c = 0, L.cols - 1 do
            local ir_flow = f_start + c * f_step
            local x0 = L.xbase + c * L.pitch_x
            local y0 = L.ybase + r * L.pitch_y
            local label
            if L.rows == 1 then
                label = fmt_compact(ir_flow)
            elseif L.cols == 1 then
                label = fmt_compact(ir_speed)
            else
                label = fmt_compact(ir_speed) .. " " .. fmt_compact(ir_flow)
            end
            table.insert(L.pads, {
                x0 = x0,
                y0 = y0,
                iron_flow = ir_flow,
                iron_speed = ir_speed,
                label = label,
                tab_x0 = x0 + (M.PAD_W - M.TAB_W) / 2,
                tab_y0 = y0 + M.PAD_H - L.width.wall,
            })
        end
    end
    return L
end

M.LAYER_PLAN = {
    {role = "bottom", width = "first", angle = 45},
    {role = "bottom", width = "wall", angle = 135},
    {role = "sparse", width = "wall", angle = 45},
    {role = "sparse", width = "wall", angle = 135},
    {role = "sparse", width = "wall", angle = 45},
    {role = "solid", width = "solid", angle = 135},
    {role = "solid", width = "solid", angle = 45},
    {role = "solid", width = "solid", angle = 135},
    {role = "solid", width = "solid", angle = 45},
    {role = "top", width = "solid", angle = 45},
}

function M.ironing_epm(draw, nozzle, layer_height, spacing, filament_d, base_flow_mult, iron_flow_pct)
    local normal_spacing = nozzle - layer_height * (1 - math.pi / 4)
    local effective_mult = base_flow_mult * (iron_flow_pct / 100.0) * (spacing / normal_spacing)
    return draw.e_per_mm(nozzle, layer_height, filament_d, effective_mult)
end

function M.draw_pad(draw, w, pad, i, S, L, speed)
    local plan = M.LAYER_PLAN[i]
    local z = i * L.h
    local width = L.width[plan.width]
    local wall_w = (i == 1) and L.width.first or L.width.wall
    local base_mult = S.flow_mult or 1.0

    local epm = draw.e_per_mm(width, L.h, S.filament_d, base_mult)
    local epm_wall = draw.e_per_mm(wall_w, L.h, S.filament_d, base_mult)
    local wall_speed = (i == 1) and M.FIRST_LAYER_SPEED
                       or math.floor(speed * M.WALL_SPEED_FRACTION)
    local fill_speed = speed
    if i == 1 then
        fill_speed = M.FIRST_LAYER_SPEED
    elseif plan.role == "top" then
        fill_speed = math.floor(speed * M.TOP_SPEED_FRACTION)
    end

    draw.draw_box(w, pad.x0, pad.y0, M.PAD_W, M.PAD_H,
                  {perimeters = 1, line_width = wall_w, layer_height = L.h,
                   epm = epm_wall, speed = wall_speed, layer_z = z,
                   fill = false})

    local wall_spacing = wall_w - L.h * (1 - math.pi / 4)
    local fx, fy = pad.x0 + wall_spacing, pad.y0 + wall_spacing
    local fsz_x = M.PAD_W - 2 * wall_spacing
    local fsz_y = M.PAD_H - 2 * wall_spacing
    local opts = {
        line_width = width,
        layer_height = L.h,
        epm = epm,
        speed = fill_speed,
        layer_z = z,
        angle = plan.angle,
    }

    if plan.role == "sparse" then
        opts.spacing = (width - L.h * (1 - math.pi / 4)) / M.SPARSE_DENSITY
    end
    draw.fill_zigzag(w, fx, fy, fsz_x, fsz_y, opts)

    -- Ironing pass right after the top solid layer is completed
    if plan.role == "top" then
        draw.emit(w, string.format("; IRONING pass: speed %g mm/s, flow %g%%, spacing %.3f mm",
                                   pad.iron_speed, pad.iron_flow, S.spacing))
        local inset = S.nozzle * M.IRONING_INSET_FRACTION
        local ix = pad.x0 + inset
        local iy = pad.y0 + inset
        local isz_x = M.PAD_W - 2 * inset
        local isz_y = M.PAD_H - 2 * inset
        local epm_iron = M.ironing_epm(draw, S.nozzle, L.h, S.spacing,
                                       S.filament_d, base_mult, pad.iron_flow)
        draw.fill_zigzag(w, ix, iy, isz_x, isz_y, {
            line_width = S.nozzle,
            layer_height = L.h,
            spacing = S.spacing,
            epm = epm_iron,
            speed = pad.iron_speed,
            layer_z = z,
            angle = 135,
        })
    end

    -- Label tab and 7-segment numbers
    if i <= M.TAB_LAYERS then
        draw.draw_box(w, pad.tab_x0, pad.tab_y0, M.TAB_W,
                      M.TAB_H + L.width.wall,
                      {perimeters = 1, line_width = wall_w, layer_height = L.h,
                       epm = epm_wall, speed = wall_speed, layer_z = z,
                       fill = true})
    elseif i == M.TAB_LAYERS + 1 then
        local epm_glyph = draw.e_per_mm(S.nozzle, L.h, S.filament_d, base_mult)
        local ox = pad.tab_x0 + (M.TAB_W - #pad.label * 3) / 2
        local oy = pad.tab_y0 + L.width.wall + (M.TAB_H - 4) / 2
        draw.draw_number(w, ox, oy, pad.label,
                         {epm = epm_glyph, speed = M.GLYPH_SPEED, layer_z = z,
                          horizontal = true})
    end
end

function M.build(S)
    local draw = require("draw")
    local L = M.layout(S)
    local base_mult = S.flow_mult or 1.0
    local vol_cap = (S.vol_cap and S.vol_cap > 0) and S.vol_cap / base_mult or 0
    local speed = M.resolve_speed(draw, S.speed, S.perimeter_speed, vol_cap,
                                  L.width.solid, L.h)
    local layers = {}
    local entry = draw.writer_opts(S)

    for i = 1, M.LAYERS do
        local w = draw.new(entry)
        draw.emit(w, string.format("; IRONING_CALIBRATION layer %d", i))
        draw.emit(w, "G90")
        draw.emit(w, "M83")
        for _, pad in ipairs(L.pads) do
            M.draw_pad(draw, w, pad, i, S, L, speed)
        end
        draw.emit(w, "; park over the handle")
        draw.park_at(w, S.bed_w / 2, S.bed_d / 2, i * L.h)
        if not entry.retracted then draw.unretract(w) end
        table.insert(layers, {
            z = i * L.h,
            insert_z = (i - M.INSERT_Z_FRACTION) * L.h,
            gcode = draw.gcode(w),
        })
    end

    return {
        handle = {size_xy = M.HANDLE_XY, height = M.LAYERS * L.h},
        pads = L.pads,
        layers = layers,
        speed = speed,
        fits = L.fits,
        extents = L.extents,
        flow_min = L.flow_min,
        flow_max = L.flow_max,
        speed_min = L.speed_min,
        speed_max = L.speed_max,
    }
end

return M