-- Master-driven calibration sweep.
-- Walks the cart from lowest registered Y to highest. At each level, asks
-- floor stations at that Y to fire redstone on all sides; waits for one to
-- report `elevator_arrived` (with the side that received the pulse); records
-- that station as the floor's anchor.

local protocol = require("shared.protocol")
local log = require("shared.log").make("CALIBRATE")

local M = {}

local LEVEL_TIMEOUT = 30  -- seconds per level

-- Group floors by canonical Y (the bucketed level Y, set by master.rebucket).
-- Returns:
--   ys: sorted list of canonical Y values
--   groups[canonicalY] = { ids = {computerId, ...}, locYs = {locY, ...} }
local function groupByY(registry)
    local groups = {}
    for _, floor in pairs(registry) do
        local cy = floor.canonicalY or floor.locY
        if not groups[cy] then groups[cy] = { ids = {}, locYs = {}, locYSet = {} } end
        table.insert(groups[cy].ids, floor.computerId)
        if not groups[cy].locYSet[floor.locY] then
            groups[cy].locYSet[floor.locY] = true
            table.insert(groups[cy].locYs, floor.locY)
        end
    end
    local ys = {}
    for y, _ in pairs(groups) do table.insert(ys, y) end
    table.sort(ys)
    return ys, groups
end

local COMPETITOR_WINDOW = 2  -- seconds to keep listening after first arrival

-- Run a single level. canonicalY is the bucketed level Y; group.locYs are
-- all the per-computer locY values that fall in this bucket. We tell every
-- computer at any of those member Ys to fire its outputs.
local function calibrateLevel(canonicalY, group, registry)
    log("Calling cart to level Y=" .. canonicalY ..
        (#group.locYs > 1 and (" (members: " .. table.concat(group.locYs, ",") .. ")") or ""))
    protocol.broadcast({
        type = protocol.TYPES.CALIBRATE_CALL,
        targetY = canonicalY,
        targetYs = group.locYs,
        ts = os.epoch("utc"),
    })

    -- Match arrivals: senderId must be a member of this group (its registry
    -- entry's canonicalY equals canonicalY). Falls back to tbl.locY equality
    -- if the sender isn't in the registry.
    local memberIds = {}
    for _, id in ipairs(group.ids) do memberIds[id] = true end

    local first
    local competitors = {}
    local deadline = os.clock() + LEVEL_TIMEOUT
    while os.clock() < deadline do
        local remaining = deadline - os.clock()
        if remaining <= 0 then break end
        local senderId, tbl = protocol.receive(remaining)
        if tbl and tbl.type == protocol.TYPES.ELEVATOR_ARRIVED then
            local belongs = memberIds[senderId]
            if not belongs then
                -- Fall back to checking locY against member Ys
                for _, y in ipairs(group.locYs) do
                    if tbl.locY == y then belongs = true; break end
                end
            end
            if belongs then
                local entry = { computerId = senderId, sideIn = tbl.sideReceived, locY = tbl.locY }
                if not first then
                    first = entry
                    log("First arrival for level Y=" .. canonicalY ..
                        ": computer " .. senderId .. " (locY=" .. tbl.locY ..
                        ") side=" .. tostring(tbl.sideReceived))
                    deadline = os.clock() + COMPETITOR_WINDOW
                else
                    table.insert(competitors, entry)
                    log("  also responded: computer " .. senderId ..
                        " (locY=" .. tbl.locY .. ") side=" .. tostring(tbl.sideReceived))
                end
            end
        end
    end

    if not first then
        log("Timeout: no arrival at level Y=" .. canonicalY)
        return nil
    end
    if #competitors > 0 then
        log("WARNING: " .. (#competitors + 1) .. " computers responded at level Y=" .. canonicalY ..
            ". Picking the first (" .. first.computerId .. "). Use `setanchor` on master " ..
            "or `claim` on a floor to override.")
    end
    log("Anchor recorded for level Y=" .. canonicalY ..
        ": computer " .. first.computerId .. " on side " .. tostring(first.sideIn))
    return {
        computerId = first.computerId,
        sideIn = first.sideIn,
        locY = canonicalY,
    }
end

-- Run the full sweep. Registry entries should already have canonicalY set
-- (master calls rebucket() before invoking this).
-- Returns list of level entries: { floorNumber, locY, name, anchorComputerId, anchorSide }.
function M.run(registry)
    local ys, groups = groupByY(registry)
    if #ys == 0 then
        log("No floors registered, cannot calibrate.")
        return nil
    end

    log("Starting sweep across " .. #ys .. " level(s).")
    local levels = {}

    for i, y in ipairs(ys) do
        local result = calibrateLevel(y, groups[y], registry)
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
function M.runOne(canonicalY, registry)
    local _, groups = groupByY(registry)
    if not groups[canonicalY] then
        log("No registered floors at level Y=" .. canonicalY)
        return nil
    end
    return calibrateLevel(canonicalY, groups[canonicalY], registry)
end

return M
