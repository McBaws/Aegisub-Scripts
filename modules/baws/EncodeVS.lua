-- version="1.0.1"
-- Copyright (c) 2026, McBaws
-- Ships encode_vs.py (the VapourSynth worker used by baws.Encode) and tells the macro where it is.

local haveDepCtrl, DependencyControl = pcall(require, "l0.DependencyControl")
local depctrl
if haveDepCtrl then
    depctrl = DependencyControl {
        name = "EncodeVS",
        version = "1.0.0",
        description = "VapourSynth worker for baws.Encode",
        author = "McBaws",
        url = "https://github.com/McBaws/Aegisub-Scripts",
        moduleName = "baws.EncodeVS",
        feed = "https://raw.githubusercontent.com/McBaws/Aegisub-Scripts/stable/DependencyControl.json"
    }
end

-- encode_vs.py sits in a folder named after this file, wherever DepCtrl put us
local here = debug.getinfo(1, "S").source:gsub("^@", "")
local dir = here:match("^(.*)[/\\][^/\\]+$") or "."
local sep = package.config:sub(1, 1)

local EncodeVS = {
    version = "1.0.0",
    script_path = dir .. sep .. "EncodeVS" .. sep .. "encode_vs.py"
}

if haveDepCtrl then
    return depctrl:register(EncodeVS)
end
return EncodeVS
