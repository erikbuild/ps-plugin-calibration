-- ABOUTME: Builds the Ellis pressure-advance pattern as per-layer G-code blobs keyed
-- ABOUTME: to the handle object's layer heights. Pure: plain settings in, blobs out.

local draw = require("draw")
local firmware = require("firmware")

local M = {}

M.HANDLE_XY = 5.0          -- handle cube footprint [mm]
M.LAYERS = 4               -- pattern layers
M.LEG = 30.0               -- chevron leg length [mm]
M.WALLS = 3                -- nested walls per chevron
M.CLEARANCE = 2.0          -- gap between the frame's left wall and the handle [mm]
M.MARGIN = 10.0            -- minimum pattern distance from the bed edge [mm]
M.GLYPH_PAD = 1.0          -- padding inside the number tab [mm]
M.FIRST_LAYER_SPEED = 30   -- frame/tab/layer-1 speed [mm/s]
M.GLYPH_SPEED = 20         -- digit drawing speed [mm/s], Orca's pattern value
M.INSERT_Z_FRACTION = 0.5  -- blobs inserted at (i - this) * layer_height

function M.parse_number(s, default)
    local v = tonumber(s)
    if v == nil then return default end
    return v
end

--- Orca's find_optimal_PA_speed: at least 100 mm/s (or the profile's perimeter
--- speed if higher), capped by the filament volumetric limit; cap 0 = uncapped.
function M.resolve_speed(requested, perimeter_speed, vol_cap, line_width, layer_height)
    if requested and requested > 0 then return requested end
    local speed = math.max(100, perimeter_speed or 0)
    if vol_cap and vol_cap > 0 then
        speed = math.min(speed, vol_cap / draw.bead_area(line_width, layer_height))
    end
    return math.floor(speed)
end

--- Everything geometric, derived from the settings table. No side effects.
function M.layout(S)
    local L = {}
    L.lw = 1.125 * S.nozzle
    L.lw_first = 1.40 * S.nozzle
    L.h = S.layer_height
    L.spacing = L.lw - L.h * (1 - math.pi / 4)
    L.wall_shift = L.spacing * math.sqrt(2)   -- X shift giving perpendicular spacing
    L.pitch = 2.0 + L.lw                      -- chevron column advance
    L.dx = M.LEG / math.sqrt(2)               -- horizontal extent of one leg
    L.dy = M.LEG / math.sqrt(2)               -- vertical rise of one leg

    local n = math.ceil((S.pa_end - S.pa_start) / S.pa_step - 1e-9) + 1
    -- width including the flow/accel label slots past the last chevron
    local function width_for(count)
        local chev = (count - 1) * L.pitch + L.dx + (M.WALLS - 1) * L.wall_shift
        local labels = (count + 4) * L.pitch + 4          -- glyph cell over the column
        return math.max(chev, labels)
    end
    local spacing_first = L.lw_first - L.h * (1 - math.pi / 4)
    L.wall_band = M.WALLS * spacing_first     -- width of the frame's perimeter band
    L.frame_pad = L.wall_band + M.GLYPH_PAD
    -- the frame wraps the auto-centered handle: its left wall sits just left
    -- of the cube, putting the handle inside the frame's vertex notch like
    -- Orca's, and the pattern extends rightward from bed center
    L.frame_min_x = S.bed_w / 2 - M.HANDLE_XY / 2 - M.CLEARANCE - L.wall_band
    local usable = (S.bed_w - M.MARGIN) - L.frame_min_x - 2 * L.frame_pad
    L.clamped = false
    while n > 2 and width_for(n) > usable do
        n = n - 1
        L.clamped = true
    end
    L.num_patterns = n
    L.pattern_w = width_for(n)
    L.frame_w = L.pattern_w + 2 * L.frame_pad
    -- chevron legs span the frame's outer bottom edge to its outer top edge,
    -- crossing the whole wall band at both ends so every stroke on layers 2+
    -- starts and ends resting on the layer-1 frame
    L.frame_h = 2 * L.dy
    L.frame_min_y = S.bed_d / 2 - L.frame_h / 2
    L.tab_min_y = L.frame_min_y + L.frame_h
    L.tab_h = 5 * 3 + 2 * M.GLYPH_PAD          -- five 3 mm glyph pitches + padding
    L.pat_min_x = L.frame_min_x + L.frame_pad
    L.pat_min_y = L.frame_min_y
    -- layer 1 shares the layer with the frame, so its chevrons shrink to sit
    -- inside the walls with clearance, vertex x-aligned with the full columns
    L.first_y0 = L.frame_min_y + L.wall_band + 0.5
    L.first_dy = (L.frame_h - 2 * L.wall_band - 1.0) / 2
    L.first_dx = L.first_dy
    L.first_x_off = L.dx - L.first_dx
    return L
end

local function draw_chevrons(w, L, S, z, epm, speed, geo)
    for j = 0, L.num_patterns - 1 do
        draw.emit(w, firmware.set_pressure_advance(S.flavor, S.pa_start + j * S.pa_step))
        local base_x = L.pat_min_x + j * L.pitch + geo.x_off
        for k = 0, M.WALLS - 1 do
            local x0 = base_x + k * L.wall_shift
            draw.travel_to(w, x0, geo.y0, z)
            draw.line_to(w, x0 + geo.dx, geo.y0 + geo.dy, epm, speed)   -- up-right to the vertex
            draw.line_to(w, x0, geo.y0 + 2 * geo.dy, epm, speed)        -- up-left; legs never cross neighbors
        end
    end
end

local function draw_labels(w, L, S, z, epm_glyph, speed)
    local opts = {epm = epm_glyph, speed = M.GLYPH_SPEED, layer_z = z}
    local oy = L.tab_min_y + M.GLYPH_PAD
    -- the glyph cell spans [ox - 4, ox]; ox = column start + 4 centers it over
    -- the chevron's top point, which returns to the column start x
    for j = 0, L.num_patterns - 1, 2 do
        local ox = L.pat_min_x + j * L.pitch + 4
        draw.draw_number(w, ox, oy, draw.fmt_value(S.pa_start + j * S.pa_step), opts)
    end
    local flow = speed * draw.bead_area(L.lw, L.h) * S.flow_mult
    draw.draw_number(w, L.pat_min_x + (L.num_patterns + 2) * L.pitch + 4, oy,
                     draw.fmt_value(flow), opts)
    if S.accel and S.accel > 0 then
        draw.draw_number(w, L.pat_min_x + (L.num_patterns + 4) * L.pitch + 4, oy,
                         string.format("%d", S.accel), opts)
    end
end

--- Writer options from the settings: the profile's retraction values, and the
--- extruder state the slicer hands over (retracted at the layer change unless
--- retract_layer_change is off). A deretract speed of 0 means the retract speed.
local function writer_opts(S)
    local deretract = S.deretract_speed
    if deretract == 0 then deretract = nil end
    return {
        travel_speed = S.travel_speed,
        retract = S.retract, retract_speed = S.retract_speed, deretract_speed = deretract,
        zhop = S.zhop,
        retracted = S.retract_layer_change ~= false,
    }
end

--- Assemble the four per-layer blobs. S is the settings table (see tests).
function M.build(S)
    assert(firmware.set_pressure_advance(S.flavor, 0),
           "flavor has no pressure-advance command: " .. tostring(S.flavor))
    local L = M.layout(S)
    local speed = M.resolve_speed(S.speed, S.perimeter_speed, S.vol_cap, L.lw, L.h)
    local epm = draw.e_per_mm(L.lw, L.h, S.filament_d, S.flow_mult)
    local epm_first = draw.e_per_mm(L.lw_first, L.h, S.filament_d, S.flow_mult)
    local epm_glyph = draw.e_per_mm(S.nozzle, L.h, S.filament_d, S.flow_mult)

    local layers = {}
    local entry = writer_opts(S)
    for i = 1, M.LAYERS do
        local z = i * L.h
        local w = draw.new(entry)
        draw.emit(w, string.format("; PA_PATTERN layer %d", i))
        draw.emit(w, "G90")
        -- Marlin-family firmware makes G90 absolute for E as well; without an
        -- immediate M83 every relative E below becomes an absolute target
        draw.emit(w, "M83")
        if S.accel and S.accel > 0 then
            draw.emit(w, string.format("M204 S%d", S.accel))
        end
        if i == 1 then
            draw.emit(w, firmware.set_pressure_advance(S.flavor, S.pa_start))
            local box = {perimeters = M.WALLS, line_width = L.lw_first,
                         layer_height = L.h, epm = epm_first,
                         speed = M.FIRST_LAYER_SPEED, layer_z = z, fill = false}
            draw.draw_box(w, L.frame_min_x, L.frame_min_y, L.frame_w, L.frame_h, box)
            local tab = {perimeters = 1, line_width = L.lw_first,
                         layer_height = L.h, epm = epm_first,
                         speed = M.FIRST_LAYER_SPEED, layer_z = z, fill = true}
            draw.draw_box(w, L.frame_min_x, L.tab_min_y, L.frame_w, L.tab_h, tab)
        end
        local chev_speed = (i == 1) and M.FIRST_LAYER_SPEED or speed
        if i > 1 then
            -- prime/anchor line up the frame's left wall band before the fast
            -- chevron strokes (Orca's "accel/flow trick line", kept for flow)
            draw.emit(w, "; prime line")
            local px = L.frame_min_x + L.wall_band / 2
            draw.travel_to(w, px, L.frame_min_y, z)
            draw.line_to(w, px, L.frame_min_y + L.frame_h, epm, chev_speed)
        end
        local geo = (i == 1)
            and {x_off = L.first_x_off, y0 = L.first_y0, dx = L.first_dx, dy = L.first_dy}
            or {x_off = 0, y0 = L.pat_min_y, dx = L.dx, dy = L.dy}
        draw_chevrons(w, L, S, z, epm, chev_speed, geo)
        if i == 2 then
            draw_labels(w, L, S, z, epm_glyph, speed)
        end
        if i == M.LAYERS then
            draw.emit(w, firmware.set_pressure_advance(S.flavor, 0))
        end
        -- the slicer resumes believing the nozzle never left the handle's
        -- seam: hand it back there, in the retraction state it handed over
        draw.emit(w, "; park over the handle")
        draw.park_at(w, S.bed_w / 2, S.bed_d / 2, z)
        if not entry.retracted then draw.unretract(w) end
        table.insert(layers, {z = z, insert_z = (i - M.INSERT_Z_FRACTION) * L.h,
                              gcode = draw.gcode(w)})
    end

    return {
        handle = {size_xy = M.HANDLE_XY, height = M.LAYERS * L.h},
        layers = layers,
        speed = speed,
        clamped = L.clamped,
        pa_end_effective = S.pa_start + (L.num_patterns - 1) * S.pa_step,
        extents = {min_x = L.frame_min_x, min_y = L.frame_min_y,
                   max_x = L.frame_min_x + L.frame_w,
                   max_y = L.tab_min_y + L.tab_h},
    }
end

return M
