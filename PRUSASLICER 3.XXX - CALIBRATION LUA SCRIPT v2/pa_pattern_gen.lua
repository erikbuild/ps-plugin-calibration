-- ABOUTME: Builds the Ellis and Lines pressure-advance patterns as per-layer 
-- ABOUTME: G-code blobs keyed to the handle object's layer heights. Pure.

local draw = require("draw")
local firmware = require("firmware")

local M = {}

M.HANDLE_XY = 5.0          -- handle cube footprint [mm]
M.LAYERS = 4               -- pattern layers (Ellis)
M.LEG = 30.0               -- chevron leg length [mm]
M.WALLS = 3                -- nested walls per chevron / frame perimeters
M.CLEARANCE = 2.0          -- gap between the frame's left wall and the handle [mm]
M.MARGIN = 10.0            -- minimum pattern distance from the bed edge [mm]
M.GLYPH_PAD = 1.5          -- padding inside the number tab [mm]
M.GLYPH_SCALE = 1.25       -- 25% larger digits (5 mm tall instead of 4 mm)
M.FIRST_LAYER_SPEED = 30   -- frame/tab/layer-1 speed [mm/s]
M.GLYPH_SPEED = 20         -- digit drawing speed [mm/s], Orca's pattern value
M.INSERT_Z_FRACTION = 0.5  -- blobs inserted at (i - this) * layer_height

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

--------------------------------------------------------------------------------
-- ELLIS PATTERN GENERATOR
--------------------------------------------------------------------------------

function M.layout_ellis(S)
    local L = {}
    L.lw = 1.125 * S.nozzle
    L.lw_first = 1.40 * S.nozzle
    L.h = S.layer_height
    L.spacing = L.lw - L.h * (1 - math.pi / 4)
    L.wall_shift = L.spacing * math.sqrt(2)
    L.pitch = 2.5 + L.lw
    L.dx = M.LEG / math.sqrt(2)
    L.dy = M.LEG / math.sqrt(2)

    local glyph_h = 4.0 * M.GLYPH_SCALE
    local n = math.ceil((S.pa_end - S.pa_start) / S.pa_step - 1e-9) + 1
    local function width_for(count)
        local chev = (count - 1) * L.pitch + L.dx + (M.WALLS - 1) * L.wall_shift
        local labels = S.draw_labels and ((count + 4) * L.pitch + glyph_h) or 0
        return math.max(chev, labels)
    end
    local spacing_first = L.lw_first - L.h * (1 - math.pi / 4)
    L.wall_band = M.WALLS * spacing_first
    L.frame_pad = L.wall_band + M.GLYPH_PAD
    
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
    
    L.frame_h = 2 * L.dy
    L.frame_min_y = S.bed_d / 2 - L.frame_h / 2
    L.tab_min_y = L.frame_min_y + L.frame_h
    L.tab_h = S.draw_labels and (5 * 3.0 * M.GLYPH_SCALE + 2 * M.GLYPH_PAD) or 0
    L.pat_min_x = L.frame_min_x + L.frame_pad
    L.pat_min_y = L.frame_min_y
    
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
            draw.line_to(w, x0 + geo.dx, geo.y0 + geo.dy, epm, speed)
            draw.line_to(w, x0, geo.y0 + 2 * geo.dy, epm, speed)
        end
    end
end

local function draw_labels(w, L, S, z, epm_glyph, speed)
    local opts = {epm = epm_glyph, speed = M.GLYPH_SPEED, layer_z = z, scale = M.GLYPH_SCALE}
    local glyph_h = 4.0 * M.GLYPH_SCALE
    local oy = L.tab_min_y + M.GLYPH_PAD
    for j = 0, L.num_patterns - 1, 2 do
        local ox = L.pat_min_x + j * L.pitch + glyph_h
        draw.draw_number(w, ox, oy, draw.fmt_value(S.pa_start + j * S.pa_step), opts)
    end
    local flow = speed * draw.bead_area(L.lw, L.h) * S.flow_mult
    draw.draw_number(w, L.pat_min_x + (L.num_patterns + 2) * L.pitch + glyph_h, oy,
                     draw.fmt_value(flow), opts)
    if S.accel and S.accel > 0 then
        draw.draw_number(w, L.pat_min_x + (L.num_patterns + 4) * L.pitch + glyph_h, oy,
                         string.format("%d", S.accel), opts)
    end
end

function M.build_ellis(S)
    local L = M.layout_ellis(S)
    local speed = M.resolve_speed(S.speed, S.perimeter_speed, S.vol_cap, L.lw, L.h)
    local epm = draw.e_per_mm(L.lw, L.h, S.filament_d, S.flow_mult)
    local epm_first = draw.e_per_mm(L.lw_first, L.h, S.filament_d, S.flow_mult)
    local epm_glyph = draw.e_per_mm(L.lw, L.h, S.filament_d, S.flow_mult)

    local layers = {}
    local entry = draw.writer_opts(S)
    for i = 1, M.LAYERS do
        local z = i * L.h
        local w = draw.new(entry)
        draw.emit(w, string.format("; PA_PATTERN layer %d", i))
        draw.emit(w, "G90")
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
            if S.draw_labels then
                local tab = {perimeters = 1, line_width = L.lw_first,
                             layer_height = L.h, epm = epm_first,
                             speed = M.FIRST_LAYER_SPEED, layer_z = z, fill = true}
                draw.draw_box(w, L.frame_min_x, L.tab_min_y, L.frame_w, L.tab_h, tab)
            end
        end
        local chev_speed = (i == 1) and M.FIRST_LAYER_SPEED or speed
        if i > 1 then
            draw.emit(w, "; prime line")
            local px = L.frame_min_x + L.wall_band / 2
            draw.travel_to(w, px, L.frame_min_y, z)
            draw.line_to(w, px, L.frame_min_y + L.frame_h, epm, chev_speed)
        end
        local geo = (i == 1)
            and {x_off = L.first_x_off, y0 = L.first_y0, dx = L.first_dx, dy = L.first_dy}
            or {x_off = 0, y0 = L.pat_min_y, dx = L.dx, dy = L.dy}
        draw_chevrons(w, L, S, z, epm, chev_speed, geo)
        
        -- Tisk čísel ve 2. i 3. vrstvě pro výraznější výšku a čitelnost
        if (i == 2 or i == 3) and S.draw_labels then
            draw.emit(w, firmware.set_pressure_advance(S.flavor, 0))
            draw_labels(w, L, S, z, epm_glyph, speed)
        end
        
        if i == M.LAYERS then
            draw.emit(w, firmware.set_pressure_advance(S.flavor, 0))
        end
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

--------------------------------------------------------------------------------
-- LINES PATTERN GENERATOR
--------------------------------------------------------------------------------

function M.layout_lines(S)
    local L = {}
    L.lw = 1.125 * S.nozzle
    L.lw_first = 1.40 * S.nozzle
    L.h = S.layer_height
    L.slow_len = 20.0
    L.fast_len = 40.0
    L.line_span_x = L.slow_len * 2 + L.fast_len
    L.pitch_y = 6.5            -- větší rozestup pro vyšší 5mm čísla
    L.pad_y = 4.0              -- přesah rámečku nad první a pod poslední linkou
    L.layers = S.draw_labels and 3 or 1

    local spacing_first = L.lw_first - L.h * (1 - math.pi / 4)
    L.wall_band = M.WALLS * spacing_first

    local n = math.ceil((S.pa_end - S.pa_start) / S.pa_step - 1e-9) + 1
    L.num_lines = n
    L.label_w = 24.0
    L.span_x = L.line_span_x + (S.draw_labels and L.label_w or 0)
    L.span_y = (n - 1) * L.pitch_y
    L.frame_h = L.span_y + 2 * L.pad_y

    L.min_x = S.bed_w / 2 - L.span_x / 2
    L.min_y = S.bed_d / 2 - L.span_y / 2

    L.clamped = false
    while n > 2 and (L.min_y - L.pad_y < M.MARGIN or L.min_y + L.span_y + L.pad_y > S.bed_d - M.MARGIN) do
        n = n - 1
        L.span_y = (n - 1) * L.pitch_y
        L.frame_h = L.span_y + 2 * L.pad_y
        L.min_y = S.bed_d / 2 - L.span_y / 2
        L.num_lines = n
        L.clamped = true
    end

    L.frame_min_y = L.min_y - L.pad_y
    L.max_x = L.min_x + L.span_x
    L.max_y = L.min_y + L.span_y
    return L
end

function M.build_lines(S)
    local L = M.layout_lines(S)
    local speed = M.resolve_speed(S.speed, S.perimeter_speed, S.vol_cap, L.lw, L.h)
    local epm = draw.e_per_mm(L.lw, L.h, S.filament_d, S.flow_mult)
    local epm_first = draw.e_per_mm(L.lw_first, L.h, S.filament_d, S.flow_mult)
    local epm_glyph = draw.e_per_mm(L.lw, L.h, S.filament_d, S.flow_mult)

    local entry = draw.writer_opts(S)
    local layers = {}
    
    for i = 1, L.layers do
        local z = i * L.h
        local w = draw.new(entry)

        draw.emit(w, string.format("; PA_PATTERN LINES layer %d", i))
        draw.emit(w, "G90")
        draw.emit(w, "M83")
        if S.accel and S.accel > 0 then
            draw.emit(w, string.format("M204 S%d", S.accel))
        end

        local slow_speed = M.FIRST_LAYER_SPEED

        if i == 1 then
            draw.emit(w, firmware.set_pressure_advance(S.flavor, 0))

            -- 1. Obvodový rámeček kolem celé kalibrace (propojí všechny linky do jednoho kusu)
            local frame_box = {
                perimeters = M.WALLS,
                line_width = L.lw_first,
                layer_height = L.h,
                epm = epm_first,
                speed = slow_speed,
                layer_z = z,
                fill = false,
            }
            draw.draw_box(w, L.min_x, L.frame_min_y, L.line_span_x, L.frame_h, frame_box)

            -- 2. Společný podklad pro čísla přímo napojený na pravou stěnu rámečku
            if S.draw_labels then
                local tab_x = L.min_x + L.line_span_x - L.lw_first
                local tab = {
                    perimeters = 2,
                    line_width = L.lw_first,
                    layer_height = L.h,
                    epm = epm_first,
                    speed = slow_speed,
                    layer_z = z,
                    fill = true,
                }
                draw.draw_box(w, tab_x, L.frame_min_y, L.label_w + L.lw_first, L.frame_h, tab)
            end

            -- 3. Vykreslení kalibračních linek (ukotvených zleva i zprava do stěny rámečku)
            local overlap = L.wall_band * 0.5
            for j = 0, L.num_lines - 1 do
                local pa = S.pa_start + j * S.pa_step
                draw.emit(w, firmware.set_pressure_advance(S.flavor, pa))
                local y = L.min_y + j * L.pitch_y
                local x = L.min_x + overlap

                draw.travel_to(w, x, y, z)
                x = L.min_x + L.slow_len
                draw.line_to(w, x, y, epm, slow_speed)
                
                x = x + L.fast_len
                draw.line_to(w, x, y, epm, speed)
                
                x = L.min_x + L.line_span_x - overlap
                draw.line_to(w, x, y, epm, slow_speed)
            end
            
            draw.emit(w, firmware.set_pressure_advance(S.flavor, 0))
            
        elseif (i == 2 or i == 3) and S.draw_labels then
            -- Tisk čísel ve 2. a 3. vrstvě + zpevnění obvodu rámečku ve 2. vrstvě
            draw.emit(w, firmware.set_pressure_advance(S.flavor, 0))
            if i == 2 then
                local rim = {
                    perimeters = 1,
                    line_width = L.lw,
                    layer_height = L.h,
                    epm = epm,
                    speed = slow_speed,
                    layer_z = z,
                    fill = false,
                }
                draw.draw_box(w, L.min_x, L.frame_min_y, L.line_span_x, L.frame_h, rim)
            end

            local glyph_h = 4.0 * M.GLYPH_SCALE
            local opts = {
                epm = epm_glyph,
                speed = M.GLYPH_SPEED,
                layer_z = z,
                horizontal = true,
                scale = M.GLYPH_SCALE,
            }
            for j = 0, L.num_lines - 1 do
                local pa = S.pa_start + j * S.pa_step
                local y = L.min_y + j * L.pitch_y
                local x = L.min_x + L.line_span_x
                draw.draw_number(w, x + 2.5, y - glyph_h / 2, draw.fmt_value(pa), opts)
            end
        end

        draw.emit(w, "; park over the handle")
        draw.park_at(w, S.bed_w / 2, S.bed_d / 2, z)
        if not entry.retracted then draw.unretract(w) end

        table.insert(layers, {z = z, insert_z = (i - M.INSERT_Z_FRACTION) * L.h,
                              gcode = draw.gcode(w)})
    end

    return {
        handle = {size_xy = M.HANDLE_XY, height = L.layers * L.h},
        layers = layers,
        speed = speed,
        clamped = L.clamped,
        pa_end_effective = S.pa_start + (L.num_lines - 1) * S.pa_step,
        extents = {min_x = L.min_x, min_y = L.frame_min_y,
                   max_x = L.max_x, max_y = L.frame_min_y + L.frame_h},
    }
end

--------------------------------------------------------------------------------
-- MAIN ROUTER
--------------------------------------------------------------------------------

function M.build(S)
    assert(firmware.set_pressure_advance(S.flavor, 0),
           "flavor has no pressure-advance command: " .. tostring(S.flavor))
           
    if S.pattern == "lines" then
        return M.build_lines(S)
    else
        return M.build_ellis(S)
    end
end

return M