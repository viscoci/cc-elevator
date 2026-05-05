-- Floor startup: pull latest from GitHub, then run sync + display in parallel
-- (subset based on elevator_config.json runSync / runDisplay flags).

package.path = package.path .. ";/?.lua;/?/init.lua"

local ok, update = pcall(require, "update")
if ok then
    pcall(update.pull)
else
    print("[startup] update module missing - running on-disk code")
end

local function readJson(path)
    if not fs.exists(path) then return nil end
    local f = fs.open(path, "r"); local raw = f.readAll(); f.close()
    return textutils.unserializeJSON(raw)
end

local cfg = readJson("elevator_config.json") or {}

local tasks = {}
if cfg.runSync ~= false then
    table.insert(tasks, function() shell.run("floor/sync.lua") end)
end
if cfg.runDisplay ~= false then
    table.insert(tasks, function() shell.run("floor/display.lua") end)
end

if #tasks == 0 then
    error("Both runSync and runDisplay are disabled - nothing to do.", 0)
elseif #tasks == 1 then
    tasks[1]()
else
    parallel.waitForAll(table.unpack(tasks))
end
