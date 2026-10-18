-- ABOUTME: Plans Orca's max-volumetric-flow tower: bead geometry, one wall speed per
-- ABOUTME: layer so flow climbs start + z * step, validation, and badge text. Pure.

local draw = require("draw")

local M = {}

M.LAYER_RATIO = 0.8        -- layer height per nozzle diameter (Orca's)
M.WIDTH_RATIO = 1.75       -- external perimeter width per nozzle diameter (Orca's)
M.MAX_LAYERS = 300         -- one modifier volume per layer; trial-tested limit
M.COMB_SVG = "max_volumetric_flow_comb.svg"
M.COMB_W = 180.0           -- comb outline width [mm]
M.MIN_BED_W = 200          -- comb + 5 mm brim each side + margin [mm]
M.MODIFIER_MARGIN = 1.0    -- speed modifier overhang past the comb [mm]
M.BADGE_GAP = 3.0          -- clearance between the badge and the comb [mm]
M.BADGE_PAD = 1.0          -- badge background margin around the text [mm]
M.BADGE_LINE_HEIGHT = 7.0  -- badge text height [mm]; below 7 a 0.4 nozzle drops the periods

--- Layer height, external perimeter width, and bead cross-section [mm^2].
function M.bead(nozzle)
    local h = M.LAYER_RATIO * nozzle
    local w = M.WIDTH_RATIO * nozzle
    return h, w, draw.bead_area(w, h)
end

--- Orca's tower height (end - start + 1) / step, in whole layers.
function M.layer_count(S, h)
    return math.floor((S.flow_end - S.flow_start + 1) / S.flow_step / h + 0.5)
end

--- Wall speed per layer [mm/s]: layer k at z = k * h extrudes start + z * step.
function M.speeds(S, h, area, n)
    local speeds = {}
    for k = 1, n do
        local flow = S.flow_start + k * h * S.flow_step
        speeds[k] = math.floor(flow / (area * S.flow_mult) + 0.5)
    end
    return speeds
end

--- Flow at the top layer [mm^3/s].
function M.top_flow(S, h, n)
    return S.flow_start + n * h * S.flow_step
end

--- The conditions that make the print readable later: temperature, nozzle,
--- flow range, and step on the first line, the note (if any) on the second.
function M.badge_text(S, top_flow)
    local parts = {}
    if type(S.temperature) == "number" then
        table.insert(parts, string.format("%dC", math.floor(S.temperature)))
    end
    table.insert(parts, string.format("%g", S.nozzle) .. (S.high_flow == true and "HF" or ""))
    table.insert(parts, string.format("%g-%g mm3/s", S.flow_start,
                                      math.floor(top_flow * 10 + 0.5) / 10))
    table.insert(parts, string.format("+%g/mm", S.flow_step))
    local text = table.concat(parts, "  ")
    if S.note and S.note ~= "" then text = text .. "\n" .. S.note end
    return text
end

--- The whole plan, or {error = "MAXFLOW: ..."}. S is the settings table (see tests).
function M.build(S)
    local h, w, area = M.bead(S.nozzle)
    if S.flow_start <= 0 or S.flow_step <= 0
       or S.flow_end < S.flow_start + S.flow_step - 1e-9 then
        return {error = "MAXFLOW: BAD RANGE"}
    end
    local n = M.layer_count(S, h)
    if n > M.MAX_LAYERS then return {error = "MAXFLOW: BAD RANGE"} end
    if S.bed_w < M.MIN_BED_W then return {error = "MAXFLOW: BED TOO SMALL"} end
    local top = M.top_flow(S, h, n)
    return {
        h = h, w = w, area = area,
        layers = n, height = n * h,
        speeds = M.speeds(S, h, area, n),
        top_flow = top,
        badge_text = M.badge_text(S, top),
    }
end

return M
