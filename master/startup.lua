-- Master startup: pull latest from GitHub, then launch master/main.lua.

package.path = package.path .. ";/?.lua;/?/init.lua"

local ok, update = pcall(require, "update")
if ok then
    pcall(update.pull)
else
    print("[startup] update module missing - running on-disk code")
end

shell.run("master/main.lua")
