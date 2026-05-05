-- Pulls the latest scripts from GitHub for this computer's role.
-- Falls back to whatever is on disk if HTTP fails so a CC won't brick on outage.

local M = {}

local function readConfig()
    if not fs.exists("elevator_config.json") then return nil end
    local f = fs.open("elevator_config.json", "r")
    local raw = f.readAll()
    f.close()
    return textutils.unserializeJSON(raw)
end

local function rawUrl(cfg, path)
    return "https://raw.githubusercontent.com/" .. cfg.repoOwner ..
           "/" .. cfg.repoName .. "/" .. cfg.repoBranch .. "/" .. path
end

local function ensureDir(path)
    local dir = fs.getDir(path)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
end

local function fetchOne(url, dest)
    local resp = http.get(url)
    if not resp then return false end
    local body = resp.readAll()
    resp.close()
    if not body or #body == 0 then return false end
    ensureDir(dest)
    local f = fs.open(dest, "w")
    f.write(body)
    f.close()
    return true
end

-- Pull all files for the given role. Returns count of files updated.
function M.pull(cfg)
    if not cfg then cfg = readConfig() end
    if not cfg then
        print("[update] No elevator_config.json — skipping update.")
        return 0
    end
    if cfg.autoUpdate == false then
        return 0
    end

    -- Pull manifest first so we always have the latest file list.
    local manifestUrl = rawUrl(cfg, "manifest.lua")
    if not fetchOne(manifestUrl, "manifest.lua") then
        print("[update] Could not fetch manifest — using on-disk files.")
        return 0
    end

    local ok, manifest = pcall(dofile, "manifest.lua")
    if not ok or type(manifest) ~= "table" then
        print("[update] manifest.lua malformed — aborting update.")
        return 0
    end

    local files = {}
    for _, p in ipairs(manifest.common or {}) do table.insert(files, p) end
    for _, p in ipairs(manifest[cfg.role] or {}) do table.insert(files, p) end

    local updated, failed = 0, 0
    for _, path in ipairs(files) do
        if path ~= "manifest.lua" then  -- already fetched
            if fetchOne(rawUrl(cfg, path), path) then
                updated = updated + 1
            else
                failed = failed + 1
                print("[update] Failed: " .. path)
            end
        end
    end
    print("[update] Pulled " .. updated .. " file(s)" ..
          (failed > 0 and (", " .. failed .. " failed") or ""))
    return updated
end

return M
