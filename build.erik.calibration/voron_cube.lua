-- ABOUTME: Voron Test Cube plugin: adds Voron Design's 30 mm test cube to the plate,
-- ABOUTME: centered on the bed. The STL is GPL-3.0; see Voron_Design_Cube_v7-NOTICE.txt.

info = {
    id = "voron_cube",
    type = "project.plugin",
    title = "Voron Test Cube",
    menu = "Ultimate Calibration/Voron Test Cube",
}

local CUBE_STL = "Voron_Design_Cube_v7.stl"

function execute()
    local util = require("plugin_util")

    local ok, cube = pcall(api.load_stl, CUBE_STL)
    if not ok then
        util.show_error("Voron Test Cube", "VORON: NO CUBE")
        return
    end
    local bb = cube:bounds()

    -- add_object puts the mesh origin at bed center; the STL's origin is a corner
    api.project:add_object{
        mesh = cube,
        translate = {x = -(bb.min_x + bb.max_x) / 2, y = -(bb.min_y + bb.max_y) / 2, z = -bb.min_z},
    }
end
