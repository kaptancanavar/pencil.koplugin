--[[--
Geometry utilities for Pencil plugin.
Pure functions for stroke geometry calculations.

@module pencil.lib.geometry
--]]--

local Geometry = {}

--- Squared distance from point (px, py) to the segment (ax, ay)-(bx, by).
function Geometry.distSqToSegment(px, py, ax, ay, bx, by)
    local vx, vy = bx - ax, by - ay
    local len_sq = vx * vx + vy * vy
    local t = 0
    if len_sq > 0 then
        t = ((px - ax) * vx + (py - ay) * vy) / len_sq
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
    end
    local cx, cy = ax + t * vx - px, ay + t * vy - py
    return cx * cx + cy * cy
end

--- Check if a point is near a stroke.
-- Measures the distance to the stroke's line segments, not just its sample
-- points: fast strokes have widely spaced points, and an eraser passing
-- between two of them must still hit the line drawn between them.
-- @param px X coordinate of point to check
-- @param py Y coordinate of point to check
-- @param stroke Table with points array
-- @param threshold Distance threshold (default 20)
-- @return boolean True if point is within threshold of the stroke
function Geometry.isPointNearStroke(px, py, stroke, threshold)
    if not stroke or not stroke.points then
        return false
    end
    local pts = stroke.points
    local n = #pts
    if n == 0 then return false end

    threshold = threshold or 20
    local threshold_sq = threshold * threshold

    if n == 1 then
        local dx, dy = px - pts[1].x, py - pts[1].y
        return dx * dx + dy * dy <= threshold_sq
    end
    for i = 2, n do
        local a, b = pts[i - 1], pts[i]
        if Geometry.distSqToSegment(px, py, a.x, a.y, b.x, b.y) <= threshold_sq then
            return true
        end
    end
    return false
end

--- Is (px, py) inside the polygon? Ray casting; the polygon is a list of
-- {x, y} points and is treated as closed.
function Geometry.pointInPolygon(px, py, poly)
    local inside = false
    local n = #poly
    local j = n
    for i = 1, n do
        local xi, yi = poly[i].x, poly[i].y
        local xj, yj = poly[j].x, poly[j].y
        if ((yi > py) ~= (yj > py))
                and (px < (xj - xi) * (py - yi) / (yj - yi) + xi) then
            inside = not inside
        end
        j = i
    end
    return inside
end

--- Insert extra points on long segments so that no two consecutive points
-- are more than `step` apart. Used before a partial erase, so the cut follows
-- the eraser instead of the (possibly sparse) original sample points.
function Geometry.densifyPoints(points, step)
    local out = {}
    local n = #points
    if n == 0 then return out end
    out[1] = points[1]
    for i = 2, n do
        local a, b = points[i - 1], points[i]
        local dx, dy = b.x - a.x, b.y - a.y
        local dist = math.sqrt(dx * dx + dy * dy)
        local k = math.floor(dist / step)
        for j = 1, k do
            local t = j / (k + 1)
            out[#out + 1] = {
                x = math.floor(a.x + dx * t + 0.5),
                y = math.floor(a.y + dy * t + 0.5),
            }
        end
        out[#out + 1] = b
    end
    return out
end

-- Rotation mode constants (matches KOReader's framebuffer constants)
Geometry.ROTATION_UPRIGHT = 0
Geometry.ROTATION_CLOCKWISE = 1
Geometry.ROTATION_UPSIDE_DOWN = 2
Geometry.ROTATION_COUNTER_CLOCKWISE = 3

--- Transform coordinates based on screen rotation.
-- Converts from hardware/physical coordinate space to logical/display space.
-- @param x Raw X coordinate from hardware
-- @param y Raw Y coordinate from hardware
-- @param rotation Rotation mode (0=upright, 1=CW, 2=upside-down, 3=CCW)
-- @param screen_width Current logical screen width
-- @param screen_height Current logical screen height
-- @return number, number Transformed X and Y coordinates
function Geometry.transformForRotation(x, y, rotation, screen_width, screen_height)
    if rotation == Geometry.ROTATION_UPRIGHT then
        return x, y
    elseif rotation == Geometry.ROTATION_CLOCKWISE then
        return screen_width - y, x
    elseif rotation == Geometry.ROTATION_UPSIDE_DOWN then
        return screen_width - x, screen_height - y
    elseif rotation == Geometry.ROTATION_COUNTER_CLOCKWISE then
        return y, screen_height - x
    end
    return x, y  -- fallback for unknown rotation
end

--- Compute the bounding box of a stroke from its points array.
-- @param stroke Table with points array (each point has x, y)
-- @return table {x0, y0, x1, y1} or nil if no points
function Geometry.computeStrokeBbox(stroke)
    if not stroke or not stroke.points or #stroke.points == 0 then
        return nil
    end
    local p = stroke.points[1]
    local x0, y0, x1, y1 = p.x, p.y, p.x, p.y
    for i = 2, #stroke.points do
        p = stroke.points[i]
        if p.x < x0 then x0 = p.x end
        if p.y < y0 then y0 = p.y end
        if p.x > x1 then x1 = p.x end
        if p.y > y1 then y1 = p.y end
    end
    return { x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
end

--- Compute minimum pixel distance between two bounding boxes.
-- Returns 0 if the boxes overlap.
-- @param a table {x0, y0, x1, y1}
-- @param b table {x0, y0, x1, y1}
-- @return number minimum distance in pixels
function Geometry.bboxDistance(a, b)
    -- Compute gap on each axis (negative means overlap)
    local dx = math.max(a.x0 - b.x1, b.x0 - a.x1, 0)
    local dy = math.max(a.y0 - b.y1, b.y0 - a.y1, 0)
    if dx == 0 and dy == 0 then
        return 0  -- overlapping
    elseif dx == 0 then
        return dy
    elseif dy == 0 then
        return dx
    else
        return math.sqrt(dx * dx + dy * dy)
    end
end

--- Compute the union of two bounding boxes.
-- @param a table {x0, y0, x1, y1}
-- @param b table {x0, y0, x1, y1}
-- @return table {x0, y0, x1, y1}
function Geometry.bboxUnion(a, b)
    return {
        x0 = math.min(a.x0, b.x0),
        y0 = math.min(a.y0, b.y0),
        x1 = math.max(a.x1, b.x1),
        y1 = math.max(a.y1, b.y1),
    }
end

--- Expand a bounding box by margin pixels on each side.
-- @param bbox table {x0, y0, x1, y1}
-- @param margin number pixels to expand on each side
-- @return table {x0, y0, x1, y1}
function Geometry.bboxExpand(bbox, margin)
    return {
        x0 = bbox.x0 - margin,
        y0 = bbox.y0 - margin,
        x1 = bbox.x1 + margin,
        y1 = bbox.y1 + margin,
    }
end

--- Clamp a bounding box to fit within screen bounds.
-- @param bbox table {x0, y0, x1, y1}
-- @param sw number screen width
-- @param sh number screen height
-- @return table {x0, y0, x1, y1}
function Geometry.bboxClampToScreen(bbox, sw, sh)
    return {
        x0 = math.max(0, math.min(bbox.x0, sw)),
        y0 = math.max(0, math.min(bbox.y0, sh)),
        x1 = math.max(0, math.min(bbox.x1, sw)),
        y1 = math.max(0, math.min(bbox.y1, sh)),
    }
end

--- Compute a full-screen-width capture strip rect for an annotation bbox.
-- The strip vertically encloses the bbox plus v_margin on each side, is
-- floored at min_h px tall (extending around the bbox center), and is
-- shifted back onto the screen if a side runs off so the min-height
-- contract is preserved. Finally clamped to the screen.
-- @param bbox table {y0, y1} (x ignored; strip is always full-width)
-- @param sw number screen width
-- @param sh number screen height
-- @param v_margin number padding above/below the bbox before min_h applies
-- @param min_h number minimum strip height (legibility floor)
-- @return table {x0, y0, x1, y1} where x0=0 and x1=sw
function Geometry.captureStripRect(bbox, sw, sh, v_margin, min_h)
    local bbox_h = bbox.y1 - bbox.y0
    local strip_h = math.max(bbox_h + 2 * v_margin, min_h)
    strip_h = math.min(strip_h, sh)
    local cy = (bbox.y0 + bbox.y1) / 2
    local y0 = math.floor(cy - strip_h / 2)
    local y1 = math.floor(cy + strip_h / 2)
    -- Shift back onscreen rather than clamp-and-chop, so a near-edge bbox
    -- still produces a min_h-tall strip (when screen has room for it).
    if y0 < 0 then
        y1 = y1 - y0
        y0 = 0
    end
    if y1 > sh then
        y0 = y0 - (y1 - sh)
        y1 = sh
    end
    y0 = math.max(0, y0)
    y1 = math.min(sh, y1)
    return { x0 = 0, y0 = y0, x1 = sw, y1 = y1 }
end

return Geometry
