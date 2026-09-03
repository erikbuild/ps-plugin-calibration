-- ABOUTME: Builds Orca's retraction tower as per-layer G-code blobs: two
-- ABOUTME: hollow posts whose inter-post travel retracts by height band. Pure.

local draw = require("draw")

local M = {}

M.BASE_W = 40.0            -- base plate [mm] (Orca's)
M.BASE_D = 15.0
M.BASE_LAYERS = 2          -- base plate layers; bands start at its top (2h)
M.POST_D = 6.0             -- post outer diameter [mm] (measured from Orca's export)
M.POST_SPACING = 31.5      -- center to center [mm] (ditto; posts sit fully on the base)
M.PERIMETERS = 2
M.TOWER_OFFSET_Y = 25.0    -- keep the string gap clear of the handle column
M.BAND_MM = 1.0            -- Orca: one retraction step per mm of height
M.MAX_BANDS = 50           -- taller than 50 mm is a typo
M.HANDLE_XY = 5.0
M.FIRST_LAYER_SPEED = 30
M.SEG_LEN = 0.5            -- circle segment length [mm]
M.INSERT_Z_FRACTION = 0.5
M.MARGIN = 10.0            -- minimum distance from the bed edge [mm]

function M.bands(start_len, end_len, step)
    return math.floor((end_len - start_len) / step + 0.5) + 1
end

--- Orca's rule: one step per mm above the base. The epsilon keeps binary
--- float noise (1.4 - 0.4 < 1.0) from shifting a band boundary by a layer.
function M.band_length(z, base_top, start_len, step, bands)
    local b = math.floor(math.max(0, z - base_top) / M.BAND_MM + 1e-6)
    if b > bands - 1 then b = bands - 1 end
    return start_len + b * step
end

--- Walls print at the profile's own speed (stringing depends on it), only
--- volumetric-capped. No minimum floor, unlike the PA/flow generators.
function M.resolve_speed(perimeter_speed, vol_cap, line_width, layer_height)
    local speed = (perimeter_speed and perimeter_speed > 0) and perimeter_speed
                  or 45
    if vol_cap and vol_cap > 0 then
        speed = math.min(speed, vol_cap / draw.bead_area(line_width, layer_height))
    end
    return math.floor(speed)
end

--- Everything geometric and the band plan. No side effects.
function M.layout(S)
    local L = {}
    L.h = S.nozzle / 2
    L.width = {wall = 1.125 * S.nozzle, first = 1.40 * S.nozzle}
    L.valid = S.ret_step > 0 and S.ret_end >= S.ret_start
    if L.valid then
        L.bands = M.bands(S.ret_start, S.ret_end, S.ret_step)
        L.valid = L.bands >= 1 and L.bands <= M.MAX_BANDS
    end
    if not L.valid then return L end
    L.base_top = M.BASE_LAYERS * L.h
    -- enough layers to print into the top band, whatever the layer height:
    -- the last layer below the schedule's top z
    L.layers = math.ceil((L.base_top + L.bands * M.BAND_MM - 1e-9) / L.h) - 1
    L.tower_top = L.layers * L.h
    local cx = S.bed_w / 2
    local ty = S.bed_d / 2 + M.TOWER_OFFSET_Y
    L.base = {x0 = cx - M.BASE_W / 2, y0 = ty - M.BASE_D / 2}
    L.r = M.POST_D / 2 - L.width.wall / 2
    -- seams face INTO the gap: the band travel then hops between the posts'
    -- interior closest points and ooze strings launch across the air you
    -- read, matching Orca's retract placement
    L.posts = {
        {x = cx - M.POST_SPACING / 2, y = ty, seam_deg = 0},
        {x = cx + M.POST_SPACING / 2, y = ty, seam_deg = 180},
    }
    -- The posts overhang the base plate by 2 mm on each side in X, so the
    -- footprint is their union with it, not the plate alone.
    L.extents = {min_x = L.base.x0, min_y = L.base.y0,
                 max_x = L.base.x0 + M.BASE_W, max_y = L.base.y0 + M.BASE_D}
    local post_r = M.POST_D / 2
    for _, p in ipairs(L.posts) do
        L.extents.min_x = math.min(L.extents.min_x, p.x - post_r)
        L.extents.min_y = math.min(L.extents.min_y, p.y - post_r)
        L.extents.max_x = math.max(L.extents.max_x, p.x + post_r)
        L.extents.max_y = math.max(L.extents.max_y, p.y + post_r)
    end
    L.fits = L.extents.min_x >= M.MARGIN and L.extents.min_y >= M.MARGIN
             and L.extents.max_x <= S.bed_w - M.MARGIN
             and L.extents.max_y <= S.bed_d - M.MARGIN
    return L
end

--- One layer: 2 solid base layers, then post A, the band-length travel,
--- post B. The writer's retract is the profile's except around the A->B
--- travel (spec section 5).
function M.draw_layer(w, i, S, L, speed)
    local z = i * L.h
    if i <= M.BASE_LAYERS then
        local width = (i == 1) and L.width.first or L.width.wall
        local epm = draw.e_per_mm(width, L.h, S.filament_d, S.flow_mult or 1.0)
        draw.draw_box(w, L.base.x0, L.base.y0, M.BASE_W, M.BASE_D,
                      {perimeters = 1, line_width = width, layer_height = L.h,
                       epm = epm, speed = M.FIRST_LAYER_SPEED,
                       layer_z = z, fill = true,
                       angle = (i == 1) and 45 or 135})
        return
    end
    local epm = draw.e_per_mm(L.width.wall, L.h, S.filament_d,
                              S.flow_mult or 1.0)
    local opts = {perimeters = M.PERIMETERS, line_width = L.width.wall,
                  layer_height = L.h, epm = epm, speed = speed, layer_z = z,
                  seg_len = M.SEG_LEN}
    opts.seam_deg = L.posts[1].seam_deg
    draw.draw_circle(w, L.posts[1].x, L.posts[1].y, L.r, opts)
    -- the one travel that the test measures: retract at the band's length
    local profile_retract = w.retract
    w.retract = M.band_length(z, L.base_top, S.ret_start, S.ret_step, L.bands)
    opts.seam_deg = L.posts[2].seam_deg
    draw.draw_circle(w, L.posts[2].x, L.posts[2].y, L.r, opts)
    w.retract = profile_retract
end

--- Assemble the per-layer blobs. S is the settings table (see tests).
function M.build(S)
    local L = M.layout(S)
    if not L.valid then return {valid = false} end
    local speed = M.resolve_speed(S.perimeter_speed, S.vol_cap,
                                  L.width.wall, L.h)
    local layers = {}
    local entry = draw.writer_opts(S)
    for i = 1, L.layers do
        local w = draw.new(entry)
        draw.emit(w, string.format("; RETRACTION layer %d", i))
        draw.emit(w, "G90")
        -- Marlin-family firmware makes G90 absolute for E as well; without an
        -- immediate M83 every relative E below becomes an absolute target
        draw.emit(w, "M83")
        M.draw_layer(w, i, S, L, speed)
        draw.emit(w, "; park over the handle")
        draw.park_at(w, S.bed_w / 2, S.bed_d / 2, i * L.h)
        if not entry.retracted then draw.unretract(w) end
        table.insert(layers, {z = i * L.h,
                              insert_z = (i - M.INSERT_Z_FRACTION) * L.h,
                              gcode = draw.gcode(w)})
    end
    return {
        -- the handle carries the tower's blobs: a taller tower needs a wider
        -- footprint to stay stable on the bed
        -- a round handle has no corners to curl, so it tolerates a slimmer
        -- aspect than a square one; 2.5:1 against the tower height
        handle = {diameter = math.max(M.HANDLE_XY, L.tower_top / 2.5),
                  height = L.tower_top},
        layers = layers, speed = speed, valid = true,
        fits = L.fits, extents = L.extents,
        bands = L.bands, tower_top = L.tower_top,
    }
end

return M
