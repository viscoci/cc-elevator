-- Master-driven calibration sweep.
-- Walks the cart from lowest registered Y to highest. At each level, asks
-- floor stations at that Y to fire redstone on all sides; waits for one to
-- report `elevator_arrived` (with the side that received the pulse); records
-- that station as the floor's anchor.

local protocol = require("shared.protocol")
local log = require("shared.log").make("CALIBRATE")

local M = {}

local LEVEL_TIMEOUT = 30  -- seconds per level

-- Group floors by locY → list of computer IDs at that Y.
local function groupByY(registry)
    local groups = {}
    for _, floor in pairs(registry) do
        local y = floor.locY
        if not groups[y] then groups[y] = {} end
        table.insert(groups[y], floor.computerId)
    end
    local ys = {}
    for y, _ in pairs(groups) do table.insert(ys, y) end
    table.sort(ys)
    return ys, groups
end

local COMPETITOR_WINDOW = 2  -- seconds to keep listening after first arrival

-- Run a single level: tell floors at targetY to fire all sides, wait for arrival.
-- Returns { computerId, sideIn, locY } on success, or nil on timeout.
-- After receiving the first arrival, keeps listening for COMPETITOR_WINDOW
-- seconds and logs any other computers that also report arrival at the same Y
-- (so the user can see if multiple computers think they're the anchor).
local function calibrateLevel(targetY, computerIds)
    log("Calling cart to Y=" .. targetY)
    protocol.broadcast({
        type = protocol.TYPES.CALIBRATE_CALL,
        targetY = targetY,
        ts = os.epoch("utc"),
    })

    local first
    local competitors = {}
    local deadline = os.clock() + LEVEL_TIMEOUT
    while os.clock() < deadline do
        local remaining = deadline - os.clock()
        if remaining <= 0 then break end
        local senderId, tbl = protocol.receive(remaining)
        if tbl and tbl.type == protocol.TYPES.ELEVATOR_ARRIVED and tbl.locY == targetY then
            local entry = { computerId = senderId, sideIn = tbl.sideReceived }
            if not first then
                first = entry
                log("First arrival for Y=" .. targetY ..
                    ": computer " .. senderId .. " side=" .. tostring(tbl.sideReceived))
                -- Keep listening briefly for competitors.
                deadline = os.clock() + COMPETITOR_WINDOW
            else
                table.insert(competitors, entry)
                log("  also responded: computer " .. senderId ..
                    " side=" .. tostring(tbl.sideReceived))
            end
        end
    end

    if not first then
        log("Timeout: no arrival at Y=" .. targetY)
        return nil
    end
    if #competitors > 0 then
        log("WARNING: " .. (#competitors + 1) .. " computers responded at Y=" .. targetY ..
            ". Picking the first (" .. first.computerId .. "). Use `setanchor` on master " ..
            "or `claim` on a floor to override.")
    end
    log("Anchor recorded for Y=" .. targetY ..
        ": computer " .. first.computerId .. " on side " .. tostring(first.sideIn))
    return {
        computerId = first.computerId,
        sideIn = first.sideIn,
        locY = targetY,
    }
end

-- Run the full sweep. registry is master's floors-by-locY table.
-- Returns list of level entries: { floorNumber, locY, name, anchorComputerId, anchorSide }.
function M.run(registry)
    local ys, _ = groupByY(registry)
    if #ys == 0 then
        log("No floors registered, cannot calibrate.")
        return nil
    end

    log("Starting sweep across " .. #ys .. " level(s).")
    local levels = {}

    for i, y in ipairs(ys) do
        local result = calibrateLevel(y, _ and _[y] or {})
        local level = {
            floorNumber = i,
            locY = y,
            name = "Floor " .. i,
            anchorComputerId = result and result.computerId or nil,
            anchorSide = result and result.sideIn or nil,
        }
        table.insert(levels, level)
        if result then
            log("Level " .. i .. " (Y=" .. y .. ") calibrated.")
        else
            log("Level " .. i .. " (Y=" .. y .. ") SKIPPED - check redstone wiring.")
        end
        sleep(1)  -- let the cart settle before next call
    end

    log("Sweep complete. " .. #levels .. " level(s) processed.")
    return levels
end

-- Calibrate just one level (for `recalibrate <Y>`).
function M.runOne(targetY, registry)
    local _, groups = groupByY(registry)
    return calibrateLevel(targetY, groups[targetY] or {})
end

return M
