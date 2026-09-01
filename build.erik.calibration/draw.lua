-- ABOUTME: G-code drawing library for calibration plugins that hand-generate toolpaths.
-- ABOUTME: Tracks position and emits relative-E extrusions, travels, boxes, and digits.

local M = {}

local function fmm(v) return string.format("%.3f", v) end

function M.new(opts)
    local retract_speed = opts.retract_speed or 35
    return {
        x = 0, y = 0,
        travel_speed = opts.travel_speed or 150,
        retract = opts.retract or 0.8,
        retract_speed = retract_speed,
        deretract_speed = opts.deretract_speed or retract_speed,
        zhop = opts.zhop or 0.5,
        retracted = opts.retracted or false,   -- extruder state on entry
        out = {},
    }
end

function M.emit(w, line)
    table.insert(w.out, line)
end

function M.gcode(w)
    return table.concat(w.out, "\n") .. "\n"
end

--- Cross-section area of one extruded bead: rectangle with semicircular ends.
function M.bead_area(line_width, layer_height)
    local bw, h = line_width, layer_height
    return h * bw - h * h + math.pi * h * h / 4
end

--- Relative E per millimeter of XY travel.
function M.e_per_mm(line_width, layer_height, filament_d, flow_mult)
    return M.bead_area(line_width, layer_height) * flow_mult
           / (math.pi * (filament_d / 2) ^ 2)
end

--- Pull the retract length back; no-op when already retracted.
function M.retract(w)
    if w.retracted then return end
    M.emit(w, string.format("G1 E-%.3f F%d", w.retract, math.floor(w.retract_speed * 60)))
    w.retracted = true
end

--- Feed the retract length back in; no-op when already primed.
function M.unretract(w)
    if not w.retracted then return end
    M.emit(w, string.format("G1 E%.3f F%d", w.retract, math.floor(w.deretract_speed * 60)))
    w.retracted = false
end

--- Retract, z-hop, travel to (x, y), drop to layer_z; leaves the extruder retracted.
function M.park_at(w, x, y, layer_z)
    local f_travel = math.floor(w.travel_speed * 60)
    M.retract(w)
    if w.zhop > 0 then
        M.emit(w, string.format("G1 Z%s F%d", fmm(layer_z + w.zhop), f_travel))
    end
    M.emit(w, string.format("G1 X%s Y%s F%d", fmm(x), fmm(y), f_travel))
    if w.zhop > 0 then
        M.emit(w, string.format("G1 Z%s F%d", fmm(layer_z), f_travel))
    end
    w.x, w.y = x, y
end

--- Travel with retract and z-hop; ends at (x, y, layer_z), unretracted.
function M.travel_to(w, x, y, layer_z)
    M.park_at(w, x, y, layer_z)
    M.unretract(w)
end

--- Extruding move from the current position; epm from M.e_per_mm, speed in mm/s.
function M.line_to(w, x, y, epm, speed)
    local d = math.sqrt((x - w.x) ^ 2 + (y - w.y) ^ 2)
    M.emit(w, string.format("G1 X%s Y%s E%.5f F%d",
                            fmm(x), fmm(y), d * epm, math.floor(speed * 60)))
    w.x, w.y = x, y
end

--- Concentric rectangular perimeters, optionally 45-degree zigzag filled.
-- opts: perimeters, line_width, layer_height, epm, speed, layer_z, fill.
function M.draw_box(w, min_x, min_y, size_x, size_y, opts)
    local spacing = opts.line_width - opts.layer_height * (1 - math.pi / 4)
    local n = opts.perimeters
    local max_n = math.max(1, math.floor(math.min(size_x, size_y) / 2 / spacing))
    if n > max_n then n = max_n end
    for k = 0, n - 1 do
        local o = k * spacing
        local x0, y0 = min_x + o, min_y + o
        local x1, y1 = min_x + size_x - o, min_y + size_y - o
        M.travel_to(w, x0, y0, opts.layer_z)
        M.line_to(w, x1, y0, opts.epm, opts.speed)
        M.line_to(w, x1, y1, opts.epm, opts.speed)
        M.line_to(w, x0, y1, opts.epm, opts.speed)
        M.line_to(w, x0, y0, opts.epm, opts.speed)
    end
    if opts.fill then
        local o = n * spacing
        M.fill_zigzag(w, min_x + o, min_y + o, size_x - 2 * o, size_y - 2 * o, opts)
    end
end

--- 45-degree zigzag fill: parallel diagonals connected along the border.
function M.fill_zigzag(w, min_x, min_y, size_x, size_y, opts)
    if size_x <= 0 or size_y <= 0 then return end
    local spacing = opts.line_width - opts.layer_height * (1 - math.pi / 4)
    local step = spacing * math.sqrt(2)
    local x1, y1 = min_x + size_x, min_y + size_y
    -- diagonals are x = y + c; sweep c across the rectangle
    local segs = {}
    local c = min_x - y1 + step
    while c < x1 - min_y do
        local ax, ay                       -- lower end of the diagonal
        if min_y + c >= min_x then ax, ay = min_y + c, min_y
        else ax, ay = min_x, min_x - c end
        local bx, by                       -- upper end
        if y1 + c <= x1 then bx, by = y1 + c, y1
        else bx, by = x1, x1 - c end
        table.insert(segs, {ax, ay, bx, by})
        c = c + step
    end
    for i, s in ipairs(segs) do
        local sx, sy, ex, ey = s[1], s[2], s[3], s[4]
        if i % 2 == 0 then sx, sy, ex, ey = ex, ey, sx, sy end
        if i == 1 then
            M.travel_to(w, sx, sy, opts.layer_z)
        else
            M.line_to(w, sx, sy, opts.epm, opts.speed)   -- connect along the border
        end
        M.line_to(w, ex, ey, opts.epm, opts.speed)
    end
end

-- 7-segment glyphs on a 2 x 4 mm cell. Segments in glyph space {x0, y0, x1, y1}.
local SEGS = {
    a = {0, 4, 2, 4}, b = {2, 2, 2, 4}, c = {2, 0, 2, 2}, d = {0, 0, 2, 0},
    e = {0, 0, 0, 2}, f = {0, 2, 0, 4}, g = {0, 2, 2, 2},
}
local GLYPHS = {
    ["0"] = "abcdef", ["1"] = "bc", ["2"] = "abged", ["3"] = "abgcd",
    ["4"] = "fgbc", ["5"] = "afgcd", ["6"] = "afgecd", ["7"] = "abc",
    ["8"] = "abcdefg", ["9"] = "abcdfg",
}
local GLYPH_PITCH = 3.0

--- Format a number to at most 5 glyphs.
function M.fmt_value(v)
    local s = string.format("%.4g", v)
    if #s > 5 then s = string.format("%.3g", v) end
    if #s > 5 then s = string.format("%.2g", v) end
    return s
end

--- Draw `str` rotated 90 degrees CCW: string advances in +Y, glyph tops point
--- in -X. (ox, oy) is the outer edge of the first glyph's baseline. Every
--- segment starts with a full retracted travel, as Orca's glyphs do.
function M.draw_number(w, ox, oy, str, opts)
    local adv = 0
    for i = 1, #str do
        local ch = str:sub(i, i)
        if ch == "." then
            M.travel_to(w, ox, oy + adv + 0.7, opts.layer_z)
            M.line_to(w, ox - 0.6, oy + adv + 0.7, opts.epm, opts.speed)
        elseif GLYPHS[ch] then
            local segs = GLYPHS[ch]
            for k = 1, #segs do
                local sg = SEGS[segs:sub(k, k)]
                -- glyph (u, v) -> world (ox - v, oy + adv + u)
                M.travel_to(w, ox - sg[2], oy + adv + sg[1], opts.layer_z)
                M.line_to(w, ox - sg[4], oy + adv + sg[3], opts.epm, opts.speed)
            end
        end
        adv = adv + GLYPH_PITCH
    end
end

return M
