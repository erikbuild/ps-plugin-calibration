-- ABOUTME: Builds the flow-ratio calibration plate as per-layer G-code blobs: a
-- ABOUTME: grid of labeled pads, each extruded at its own flow multiplier. Pure.

local draw = require("draw")

local M = {}

M.PAD_W = 30.0             -- judged pad footprint [mm] (Orca's coupon)
M.PAD_H = 20.0
M.TAB_W = 18.0             -- label tab on the pad's top edge [mm]
M.TAB_H = 10.0
M.TAB_LAYERS = 2           -- tab height in layers; digits go on the next layer
M.GAP = 8.0                -- clearance between grid cells [mm]
M.COLS = 4                 -- even: the centered grid keeps an X gap at bed center
M.LAYERS = 10              -- 2 bottom + 3 sparse + 4 solid + 1 top
M.MARGIN = 10.0            -- minimum distance from the bed edge [mm]
M.HANDLE_XY = 5.0          -- handle cube footprint [mm]
M.FIRST_LAYER_SPEED = 30   -- everything on layer 1 [mm/s]
M.GLYPH_SPEED = 20         -- digit drawing [mm/s]
M.WALL_SPEED_FRACTION = 0.6
M.TOP_SPEED_FRACTION = 0.5
M.SPARSE_DENSITY = 0.35    -- Orca's sparse_infill_density for this test
M.INSERT_Z_FRACTION = 0.5  -- blobs inserted at (i - this) * layer_height

-- Orca's YOLO flow deltas: absolute offsets from the current multiplier
M.DELTAS = {
    coarse = {-0.05, -0.04, -0.03, -0.02, -0.01, 0.0,
              0.01, 0.02, 0.03, 0.04, 0.05},
    fine = {-0.035, -0.03, -0.025, -0.02, -0.015, -0.01, -0.005, 0.0,
            0.005, 0.01, 0.015, 0.02, 0.025, 0.03, 0.035},
}

function M.deltas(mode)
    return M.DELTAS[mode] or M.DELTAS.coarse
end

--- Speed from the profile floor and the volumetric cap. Unlike the PA
--- pattern's, an explicit request stays capped: the plate exists to
--- over-extrude and the fattest pad must not be speed-masked.
function M.resolve_speed(requested, perimeter_speed, vol_cap, line_width, layer_height)
    local speed = (requested and requested > 0) and requested
                  or math.max(100, perimeter_speed or 0)
    if vol_cap and vol_cap > 0 then
        speed = math.min(speed, vol_cap / draw.bead_area(line_width, layer_height))
    end
    return math.floor(speed)
end

--- Everything geometric, derived from the settings table. No side effects.
-- The grid is centered in X (even COLS keeps an X gap at bed center); in Y the
-- inter-row gap ahead of row floor(rows/2) straddles bed center, so the
-- auto-centered handle cube lands on bare bed.
function M.layout(S)
    local L = {}
    L.h = S.nozzle / 2
    L.width = {wall = 1.125 * S.nozzle, first = 1.40 * S.nozzle,
               solid = 1.20 * S.nozzle}
    L.deltas = M.deltas(S.mode)
    L.v_max = S.flow_mult + L.deltas[#L.deltas]
    local n = #L.deltas
    L.rows = (n + M.COLS - 1) // M.COLS
    local cell_w = M.PAD_W
    local cell_h = M.PAD_H + M.TAB_H
    L.pitch_x = cell_w + M.GAP
    L.pitch_y = cell_h + M.GAP
    L.span_x = M.COLS * cell_w + (M.COLS - 1) * M.GAP
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
        local col = (p - 1) % M.COLS
        local row = (p - 1) // M.COLS
        local x0 = L.xbase + col * L.pitch_x
        local y0 = L.ybase + row * L.pitch_y
        local v = S.flow_mult + L.deltas[p]
        table.insert(L.pads, {
            x0 = x0, y0 = y0, v = v, label = draw.fmt_value(v),
            tab_x0 = x0 + (M.PAD_W - M.TAB_W) / 2,
            tab_y0 = y0 + M.PAD_H - L.width.wall,   -- fused by one wall width
        })
    end
    return L
end

-- The faithful Orca pad: 2 bottom, 3 sparse, 4 internal solid, 1 top surface.
-- width keys L.width; angle alternates so successive fills cross.
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

--- One pad (wall, fill, tab, digits) on one layer. Everything scales with
--- the pad's flow value through epm; nothing else varies between pads.
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
    elseif plan.role == "top" and S.pattern ~= "monotonic" then
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

--- Assemble the ten per-layer blobs. S is the settings table (see tests).
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
        -- Marlin-family firmware makes G90 absolute for E as well; without an
        -- immediate M83 every relative E below becomes an absolute target
        draw.emit(w, "M83")
        for _, pad in ipairs(L.pads) do
            M.draw_pad(w, pad, i, S, L, speed)
        end
        -- the slicer resumes believing the nozzle never left the handle's
        -- seam: hand it back there, in the retraction state it handed over
        draw.emit(w, "; park over the handle")
        draw.park_at(w, S.bed_w / 2, S.bed_d / 2, i * L.h)
        if not entry.retracted then draw.unretract(w) end
        table.insert(layers, {z = i * L.h,
                              insert_z = (i - M.INSERT_Z_FRACTION) * L.h,
                              gcode = draw.gcode(w)})
    end
    return {
        handle = {size_xy = M.HANDLE_XY, height = M.LAYERS * L.h},
        layers = layers,
        speed = speed,
        fits = L.fits,
        extents = L.extents,
        v_min = S.flow_mult + L.deltas[1],
        v_max = L.v_max,
    }
end

return M
