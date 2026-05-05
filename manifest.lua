return {
    common = {
        "shared/log.lua",
        "shared/rednet_setup.lua",
        "shared/protocol.lua",
        "update.lua",
        "manifest.lua",
    },
    master = {
        "master/main.lua",
        "master/calibrate.lua",
        "master/setup_gui.lua",
        "master/startup.lua",
    },
    floor = {
        "floor/sync.lua",
        "floor/display.lua",
        "floor/startup.lua",
    },
}
