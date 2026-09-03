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

--- Writer options from a settings table: the profile's retraction values, and
--- the extruder state the slicer hands over (retracted at the layer change
--- unless retract_layer_change is off). A deretract speed of 0 means the
--- retract speed.
function M.writer_opts(S)
    local deretract = S.deretract_speed
    if deretract == 0 then deretract = nil end
    return {
        travel_speed = S.travel_speed,
        retract = S.retract, retract_speed = S.retract_speed,
        deretract_speed = deretract,
        zhop = S.zhop,
        retracted = S.retract_layer_change ~= false,
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

--- Plain primed XY move for gaps below the retract threshold, connecting
--- fill fragments the way slicers connect sub-minimum travels. The caller
--- must be unretracted (mid-fill).
function M.hop_to(w, x, y)
    M.emit(w, string.format("G1 X%s Y%s F%d", fmm(x), fmm(y),
                            math.floor(w.travel_speed * 60)))
    w.x, w.y = x, y
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

--- Serpentine fill: parallel diagonals connected along the border.
-- opts.angle: 45 (default) or 135. opts.spacing overrides the width-derived
-- line spacing (sparse fill passes a widened value).
function M.fill_zigzag(w, min_x, min_y, size_x, size_y, opts)
    if size_x <= 0 or size_y <= 0 then return end
    local spacing = opts.spacing
                    or opts.line_width - opts.layer_height * (1 - math.pi / 4)
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
    if opts.angle == 135 then
        -- mirror across the vertical centerline: 45-degree diagonals become
        -- 135-degree ones, sweep order preserved
        local mx = min_x + x1
        for _, s in ipairs(segs) do
            s[1], s[3] = mx - s[1], mx - s[3]
        end
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

M.HOP_LIMIT = 1.5   -- travels shorter than this stay unretracted [mm]

local function reverse_polyline(pl)
    for i = 1, #pl // 2 do
        pl[i], pl[#pl - i + 1] = pl[#pl - i + 1], pl[i]
    end
end

--- Archimedean-spiral fill clipped to a rectangle, in Orca's flow-calibration
--- order: corner chord fragments first (nearest-neighbor chained), the center
--- spiral last and inside-out, so the opposing meeting directions raise the
--- tactile lip the flow test reads. Returns an ordered list of polylines.
function M.archimedean_polylines(min_x, min_y, size_x, size_y, pitch, seg_len)
    local cx, cy = min_x + size_x / 2, min_y + size_y / 2
    local max_x, max_y = min_x + size_x, min_y + size_y
    local b = pitch / (2 * math.pi)
    local rmax = math.sqrt(size_x ^ 2 + size_y ^ 2) / 2 + pitch
    -- unwind the spiral into a polyline of ~seg_len segments
    local pts = {{cx, cy}}
    local theta = 0
    while b * theta <= rmax do
        theta = theta + seg_len / math.max(b * theta, seg_len)
        local r = b * theta
        table.insert(pts, {cx + r * math.cos(theta), cy + r * math.sin(theta)})
    end
    -- Liang-Barsky clip of each segment, gluing contiguous runs into polylines
    local polys, cur = {}, nil
    local function flush()
        if cur and #cur >= 2 then table.insert(polys, cur) end
        cur = nil
    end
    for i = 2, #pts do
        local p, q = pts[i - 1], pts[i]
        local dx, dy = q[1] - p[1], q[2] - p[2]
        local t0, t1, ok = 0.0, 1.0, true
        local pk = {-dx, dx, -dy, dy}
        local qk = {p[1] - min_x, max_x - p[1], p[2] - min_y, max_y - p[2]}
        for k = 1, 4 do
            if pk[k] == 0 then
                if qk[k] < 0 then ok = false end
            else
                local r = qk[k] / pk[k]
                if pk[k] < 0 then t0 = math.max(t0, r)
                else t1 = math.min(t1, r) end
            end
        end
        if ok and t0 <= t1 then
            if t0 > 0 or cur == nil then
                flush()
                cur = {{p[1] + t0 * dx, p[2] + t0 * dy}}
            end
            table.insert(cur, {p[1] + t1 * dx, p[2] + t1 * dy})
            if t1 < 1 then flush() end
        else
            flush()
        end
    end
    flush()
    if #polys <= 1 then return polys end
    -- the longest polyline is the center spiral; everything else is a chord
    local function length(pl)
        local d = 0
        for i = 2, #pl do
            d = d + math.sqrt((pl[i][1] - pl[i-1][1])^2
                              + (pl[i][2] - pl[i-1][2])^2)
        end
        return d
    end
    local li = 1
    for i = 2, #polys do
        if length(polys[i]) > length(polys[li]) then li = i end
    end
    local spiral = table.remove(polys, li)
    local function d2c(pt) return (pt[1] - cx)^2 + (pt[2] - cy)^2 end
    if d2c(spiral[1]) > d2c(spiral[#spiral]) then reverse_polyline(spiral) end
    -- chain chords nearest-endpoint-first, starting from the center
    local chained = {}
    local curx, cury = cx, cy
    while #polys > 0 do
        local best, bestd, bestrev = 1, math.huge, false
        for i, pl in ipairs(polys) do
            local dh = (pl[1][1] - curx)^2 + (pl[1][2] - cury)^2
            local dt = (pl[#pl][1] - curx)^2 + (pl[#pl][2] - cury)^2
            if dh < bestd then best, bestd, bestrev = i, dh, false end
            if dt < bestd then best, bestd, bestrev = i, dt, true end
        end
        local pl = table.remove(polys, best)
        if bestrev then reverse_polyline(pl) end
        table.insert(chained, pl)
        curx, cury = pl[#pl][1], pl[#pl][2]
    end
    table.insert(chained, spiral)
    return chained
end

--- Draw the archimedean top fill. opts as fill_zigzag, plus optional seg_len.
function M.fill_archimedean_chords(w, min_x, min_y, size_x, size_y, opts)
    local spacing = opts.spacing
                    or opts.line_width - opts.layer_height * (1 - math.pi / 4)
    local polys = M.archimedean_polylines(min_x, min_y, size_x, size_y,
                                          spacing, opts.seg_len or 0.8)
    for i, pl in ipairs(polys) do
        local d = math.sqrt((pl[1][1] - w.x)^2 + (pl[1][2] - w.y)^2)
        if i == 1 or d > M.HOP_LIMIT then
            M.travel_to(w, pl[1][1], pl[1][2], opts.layer_z)
        else
            M.hop_to(w, pl[1][1], pl[1][2])
        end
        for k = 2, #pl do
            M.line_to(w, pl[k][1], pl[k][2], opts.epm, opts.speed)
        end
    end
end

--- Concentric circular perimeters, innermost first (walls print inner-to-
--- outer). r is the outermost wall centerline radius; each loop starts and
--- closes at seam_deg. The first loop drawn enters with a full travel, later
--- loops hop the sub-threshold gap. Loops that would collapse through the
--- center are skipped.
function M.draw_circle(w, cx, cy, r, opts)
    local spacing = opts.line_width - opts.layer_height * (1 - math.pi / 4)
    local seg_len = opts.seg_len or 0.5
    local n = opts.perimeters
    local entered = false
    for k = n - 1, 0, -1 do
        local rk = r - k * spacing
        if rk > spacing / 2 then
            local steps = math.max(12, math.ceil(2 * math.pi * rk / seg_len))
            local a0 = math.rad(opts.seam_deg or 0)
            local sx = cx + rk * math.cos(a0)
            local sy = cy + rk * math.sin(a0)
            if entered then
                M.hop_to(w, sx, sy)
            else
                M.travel_to(w, sx, sy, opts.layer_z)
                entered = true
            end
            for s = 1, steps do
                local a = a0 + s * 2 * math.pi / steps
                M.line_to(w, cx + rk * math.cos(a), cy + rk * math.sin(a),
                          opts.epm, opts.speed)
            end
        end
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

--- Draw `str` as 7-segment strokes; every segment starts with a full
--- retracted travel, as Orca's glyphs do. Default orientation is rotated 90
--- degrees CCW — string advances +Y, glyph tops point -X, (ox, oy) the outer
--- edge of the first glyph's baseline. opts.horizontal advances +X with
--- upright glyphs, (ox, oy) the lower-left corner.
function M.draw_number(w, ox, oy, str, opts)
    local adv = 0
    local function map(u, v)
        if opts.horizontal then return ox + adv + u, oy + v end
        return ox - v, oy + adv + u
    end
    local function stroke(u0, v0, u1, v1)
        local x0, y0 = map(u0, v0)
        local x1, y1 = map(u1, v1)
        M.travel_to(w, x0, y0, opts.layer_z)
        M.line_to(w, x1, y1, opts.epm, opts.speed)
    end
    for i = 1, #str do
        local ch = str:sub(i, i)
        if ch == "." then
            stroke(0.7, 0, 0.7, 0.6)
        elseif GLYPHS[ch] then
            local segs = GLYPHS[ch]
            for k = 1, #segs do
                local sg = SEGS[segs:sub(k, k)]
                stroke(sg[1], sg[2], sg[3], sg[4])
            end
        end
        adv = adv + GLYPH_PITCH
    end
end

return M
