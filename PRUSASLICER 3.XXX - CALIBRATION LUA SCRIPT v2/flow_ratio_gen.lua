-- ABOUTME: Builds the flow-ratio calibration plate as per-layer G-code blobs: a
-- ABOUTME: grid of labeled pads, each extruded at its own flow multiplier. Pure.

local draw = require("draw")

local M = {}

M.PAD_W = 30.0
M.PAD_H = 20.0
M.TAB_W = 18.0
M.TAB_H = 10.0
M.TAB_LAYERS = 2
M.GAP = 8.0
M.COLS = 4
M.LAYERS = 10
M.MARGIN = 10.0
M.HANDLE_XY = 5.0
M.FIRST_LAYER_SPEED = 30
M.GLYPH_SPEED = 20
M.WALL_SPEED_FRACTION = 0.6
M.TOP_SPEED_FRACTION = 0.5
M.SPARSE_DENSITY = 0.35
M.INSERT_Z_FRACTION = 0.5

function M.resolve_speed(requested, perimeter_speed, vol_cap, line_width, layer_height)
    local speed = (requested and requested > 0) and requested
                  or math.max(100, perimeter_speed or 0)
    if vol_cap and vol_cap > 0 then
        speed = math.min(speed, vol_cap / draw.bead_area(line_width, layer_height))
    end
    return math.floor(speed)
end

function M.layout(S)
    local L = {}
    L.h = S.layer_height or (S.nozzle / 2)
    L.width = {wall = 1.125 * S.nozzle, first = 1.40 * S.nozzle,
               solid = 1.20 * S.nozzle}

    local start_val = S.start_flow or 0.95
    local step_val = S.step or 0.01
    local count = math.max(1, S.count or 11)

    L.values = {}
    for p = 1, count do
        table.insert(L.values, start_val + (p - 1) * step_val)
    end

    local n = #L.values
    L.v_min = L.values[1]
    L.v_max = L.values[n]

    local cols = math.min(M.COLS, n)
    if cols > 2 and cols < 4 then
        cols = 4
    elseif cols <= 2 then
        cols = 2
    end
    L.cols = cols
    L.rows = (n + L.cols - 1) // L.cols

    local cell_w = M.PAD_W
    local cell_h = M.PAD_H + M.TAB_H
    L.pitch_x = cell_w + M.GAP
    L.pitch_y = cell_h + M.GAP
    L.span_x = L.cols * cell_w + (L.cols - 1) * M.GAP
    L.span_y = L.rows * cell_h + (L.rows - 1) * M.GAP

    local cx, cy = S.bed_w / 2, S.bed_d / 2
    L.xbase = cx - L.span_x / 2
    L.ybase = cy + M.GAP / 2 - (L.rows // 2) * L.pitch_y

    L.extents = {min_x = L.xbase, min_y = L.ybase,
                 max_x = L.xbase + L.span_x, max_y = L.ybase + L.span_y}
    L.fits = L.extents.min_x >= M.MARGIN and L.extents.min_y >= M.MARGIN
             and L.extents.max_x <= S.bed_w - M.MARGIN
             and L.extents.max_y <= S.bed_d - M.MARGIN

    L.pads = {}
    for p = 1, n do
        local col = (p - 1) % L.cols
        local row = (p - 1) // L.cols
        local x0 = L.xbase + col * L.pitch_x
        local y0 = L.ybase + row * L.pitch_y
        local v = L.values[p]
        table.insert(L.pads, {
            x0 = x0, y0 = y0, v = v, label = draw.fmt_value(v),
            tab_x0 = x0 + (M.PAD_W - M.TAB_W) / 2,
            tab_y0 = y0 + M.PAD_H - L.width.wall,
        })
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

function M.draw_pad(w, pad, i, S, L, speed)
    local plan = M.LAYER_PLAN[i]
    local z = i * L.h
    local width = L.width[plan.width]
    local wall_w = (i == 1) and L.width.first or L.width.wall
    local epm = draw.e_per_mm(width, L.h, S.filament_d, pad.v)
    local epm_wall = draw.e_per_mm(wall_w, L.h, S.filament_d, pad.v)
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
    local opts = {line_width = width, layer_height = L.h, epm = epm,
                  speed = fill_speed, layer_z = z, angle = plan.angle}
    if plan.role == "sparse" then
        opts.spacing = (width - L.h * (1 - math.pi / 4)) / M.SPARSE_DENSITY
        draw.fill_zigzag(w, fx, fy, fsz_x, fsz_y, opts)
    elseif plan.role == "top" and S.pattern == "archimedean" then
        draw.fill_archimedean_chords(w, fx, fy, fsz_x, fsz_y, opts)
    else
        draw.fill_zigzag(w, fx, fy, fsz_x, fsz_y, opts)
    end
    if i <= M.TAB_LAYERS then
        draw.draw_box(w, pad.tab_x0, pad.tab_y0, M.TAB_W,
                      M.TAB_H + L.width.wall,
                      {perimeters = 1, line_width = wall_w, layer_height = L.h,
                       epm = epm_wall, speed = wall_speed, layer_z = z,
                       fill = true})
    elseif i == M.TAB_LAYERS + 1 then
        local epm_glyph = draw.e_per_mm(S.nozzle, L.h, S.filament_d, pad.v)
        local ox = pad.tab_x0 + (M.TAB_W - #pad.label * 3) / 2
        local oy = pad.tab_y0 + L.width.wall + (M.TAB_H - 4) / 2
        draw.draw_number(w, ox, oy, pad.label,
                         {epm = epm_glyph, speed = M.GLYPH_SPEED, layer_z = z,
                          horizontal = true})
    end
end

function M.build(S)
    local L = M.layout(S)
    local vol_cap = (S.vol_cap and S.vol_cap > 0) and S.vol_cap / L.v_max or 0
    local speed = M.resolve_speed(S.speed, S.perimeter_speed, vol_cap,
                                  L.width.solid, L.h)
    local layers = {}
    local entry = draw.writer_opts(S)
    for i = 1, M.LAYERS do
        local w = draw.new(entry)
        draw.emit(w, string.format("; FLOW_RATIO layer %d", i))

        draw.emit(w, "G90")
        draw.emit(w, "M83")
        for _, pad in ipairs(L.pads) do
            M.draw_pad(w, pad, i, S, L, speed)
        end
        draw.emit(w, "; park over the handle")
        draw.park_at(w, S.bed_w / 2, S.bed_d / 2, i * L.h)
        if not entry.retracted then draw.unretract(w) end
        table.insert(layers, {z = i * L.h,
                              insert_z = (i - M.INSERT_Z_FRACTION) * L.h,
                              gcode = draw.gcode(w)})
    end
    return {
        handle = {size_xy = M.HANDLE_XY, height = M.LAYERS * L.h},
        pads = L.pads,
        layers = layers,
        speed = speed,
        fits = L.fits,
        extents = L.extents,
        v_min = L.v_min,
        v_max = L.v_max,
    }
end

return M