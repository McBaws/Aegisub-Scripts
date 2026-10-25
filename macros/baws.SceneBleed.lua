-- Copyright (c) 2026, McBaws
--
-- Permission to use, copy, modify, and distribute this software for any
-- purpose with or without fee is hereby granted, provided that the above
-- copyright notice and this permission notice appear in all copies.
--
-- THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
-- WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
-- MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
-- ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
-- WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
-- ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
-- OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

script_name = "SceneBleed"
script_description = "Detects scenebleeds and marks them with an effect"
script_author = "McBaws"
script_version = "1.2.0"
script_namespace = "baws.SceneBleed"

local havedc, DependencyControl = pcall(require, "l0.DependencyControl")
local dep
if havedc then
    dep = DependencyControl{
        feed = "https://raw.githubusercontent.com/McBaws/Aegisub-Scripts/stable/DependencyControl.json",
    }
end

re = require('aegisub.re')

-- Define the configuration dialog layout and defaults
local config_diag = {
    main = {
        startlabel = {class = 'label', label = "--- Start ---                              ", x = 0, y = 0},
        label1 = {class = 'label', label = "'Before' threshold (ms):", x = 0, y = 1},
        thresholdStartBefore = {class = 'intedit', name = 'thresholdStartBefore', value = 350, config = true, min = 0, max = 216000000, x = 0, y = 2, hint = "Lines that start within this many ms before a keyframe will be detected as a scenebleed."},
        label2 = {class = 'label', label = "'After' threshold (ms):", x = 0, y = 3},
        thresholdStartAfter = {class = 'intedit', name = 'thresholdStartAfter', value = 100, config = true, min = 0, max = 216000000, x = 0, y = 4, hint = "Lines that start within this many ms after a keyframe will be detected as a scenebleed."},
        
        endlabel = {class = 'label', label = "--- End ---                               ", x = 1, y = 0},
        label3 = {class = 'label', label = "'Before' threshold (ms):", x = 1, y = 1},
        thresholdEndBefore = {class = 'intedit', name = 'thresholdEndBefore', value = 300, config = true, min = 0, max = 216000000, x = 1, y = 2, hint = "Lines that end within this many ms before a keyframe will be detected as a scenebleed."},
        label4 = {class = 'label', label = "'After' threshold (ms):", x = 1, y = 3},
        thresholdEndAfter = {class = 'intedit', name = 'thresholdEndAfter', value = 900, config = true, min = 0, max = 216000000, x = 1, y = 4, hint = "Lines that end within this many ms after a keyframe will be detected as a scenebleed."},
        
        label5 = {class = 'label', label = 'Effect marker string:', x = 0, y = 5},
        bleedString = {class = 'edit', name = 'bleedString', value = "bleed", config = true, x = 0, y = 6, width = 2, hint = "Text appended to the effect field."},
        extraInfo = {class = 'checkbox', label = 'Also mark scenebleed type', name = 'extraInfo', value = false, config = true, x = 0, y = 7, width = 2, hint = "Will add the type of scenebleed detected in brackets to the effects field. eg: bleed (start before)"},

        skipMarked = {class = 'checkbox', label = 'Skip already marked lines', name = 'skipMarked', value = false, config = true, x = 0, y = 9, width = 2, hint = "Don't process lines that are already marked. If disabled, will unmark lines that are no longer scenebleeds."}
    }
}

-- defaults come straight from the dialog, grabbed before anything changes its values
local DEFAULTS = {}
for key, values in pairs(config_diag.main) do
    if values.config then DEFAULTS[key] = values.value end
end

-- settings only keep what differs from the defaults, so changing a default later still reaches people
-- without dep they just live in here until aegisub closes
local config, session = nil, {}

local function store_settings(store)
    if not config then
        session = store
        return true
    end
    -- dep 0.6 only ever adds keys when it writes, so clear the section first or old values stick around
    local ok, err = config:delete()
    if not ok then return ok, err end
    if next(store) == nil then return true end
    for k, v in pairs(store) do config.c[k] = v end
    return config:write()
end

if havedc then
    config = dep:getConfigHandler(DEFAULTS, "settings")

    -- a-mo saved to <depctrl configDir>/<configFile>. newer depctrl doesn't expose configDir on the
    -- script's record, so there a-mo fell back to ?user, older depctrl gives ?user/config. check them all
    local function find_old_config()
        local okjson, json = pcall(require, "json")
        if not okjson then json = require("l0.dkjson") end
        local name = dep.configFile or (script_namespace .. ".json")
        local seen = {}
        for _, dir in ipairs({dep.configDir or "?user", "?user", "?user/config"}) do
            local path = aegisub.decode_path(dir .. "/" .. name)
            local f = not seen[path] and io.open(path, "r")
            seen[path] = true
            if f then
                local text = f:read("*a")
                f:close()
                local ok, old = pcall(json.decode, text)
                if ok and type(old) == "table" and old.__version ~= nil then return path, old end
            end
        end
    end

    -- one time move from the old a-mo file, which looks like {"main": {...}, "__version": ...}
    -- anything already saved with the new handler wins, the old values only fill in the rest
    local path, old = find_old_config()
    if path then
        local main = type(old.main) == "table" and old.main or {}
        local store = {}
        for k, v in pairs(DEFAULTS) do
            local now = config.userConfig and config.userConfig[k]
            if now ~= nil then
                store[k] = now
            elseif main[k] ~= nil and main[k] ~= v then
                store[k] = main[k]
            end
        end
        os.remove(path)
        store_settings(store)
    end
end

local function get_configuration()
    local c = {}
    for k, v in pairs(DEFAULTS) do
        if config then
            c[k] = config.c[k]
        elseif session[k] ~= nil then
            c[k] = session[k]
        else
            c[k] = v
        end
    end
    return c
end

-- new values go over the current ones, anything the script doesn't know about is ignored
local function save_configuration(new)
    local store = {}
    for k, v in pairs(get_configuration()) do
        if new[k] ~= nil then v = new[k] end
        if v ~= DEFAULTS[k] then store[k] = v end
    end
    return store_settings(store)
end

local function show_config_dialog()
    for k, v in pairs(get_configuration()) do
        config_diag.main[k].value = v
    end
    local button, result = aegisub.dialog.display(config_diag.main)
    if button then
        local ok, err = save_configuration(result)
        if not ok then aegisub.log(2, "Couldn't save the settings: " .. tostring(err) .. "\n") end
    end
end

local function process(subs, sel)
    local opts = get_configuration()
    local threshSB = aegisub.frame_from_ms(opts.thresholdStartBefore)
    local threshSA = aegisub.frame_from_ms(opts.thresholdStartAfter)
    local threshEB = aegisub.frame_from_ms(opts.thresholdEndBefore)
    local threshEA = aegisub.frame_from_ms(opts.thresholdEndAfter)
    local bleedString = opts.bleedString

    local max_thresh = math.max(threshSB, threshSA, threshEB, threshEA)

    local keyframes = aegisub.keyframes()
    if not keyframes or #keyframes == 0 then
        aegisub.log(2, "Warning: No keyframes found. Scenebleed detection requires video/keyframes to be loaded.\n")
        aegisub.cancel()
    end

    local bleed_count = 0
    local lines_edited = false
    for j, i in ipairs(sel) do
        local line = subs[i]
        if line.class == "dialogue" and not line.comment then
            if not (opts.skipMarked and line.effect:match(bleedString)) then
                local start_frame = aegisub.frame_from_ms(line.start_time)
                local end_frame = aegisub.frame_from_ms(line.end_time)

                local bleedSB, bleedSA, bleedEB, bleedEA = false, false, false, false
                -- Track perfect snaps
                local snapped_start, snapped_end = false, false

                for _, frame in ipairs(keyframes) do
                    -- Check if the line perfectly aligns with this keyframe
                    if start_frame == frame then snapped_start = true end
                    if end_frame == frame then snapped_end = true end

                    -- Check for proximity to the keyframe
                    bleedSB = bleedSB or (start_frame < frame and start_frame >= frame - threshSB)
                    bleedSA = bleedSA or (start_frame > frame and start_frame < frame + threshSA)
                    bleedEB = bleedEB or (end_frame < frame and end_frame >= frame - threshEB)
                    bleedEA = bleedEA or (end_frame > frame and end_frame < frame + threshEA)

                    -- Safely break once the keyframe is out of the max threshold range
                    if end_frame < frame - (max_thresh * 2) then
                        break
                    end
                end

                if snapped_start then
                    bleedSB = false
                    bleedSA = false
                end
                if snapped_end then
                    bleedEB = false
                    bleedEA = false
                end

                local is_bleed = bleedSB or bleedSA or bleedEB or bleedEA

                -- clear past marks
                if line.effect:match(bleedString) then
                    -- first get rid of extra info, if it exists
                    if line.effect:match(bleedString .. " %(") then
                        line.effect = re.sub(line.effect, bleedString .. " \\(.*?\\)", bleedString)
                    end

                    -- then get rid of bleedstring itself
                    line.effect = line.effect:gsub("; " .. bleedString, "")
                    line.effect = line.effect:gsub(bleedString, "")
                end

                local infoSB = "start before, "
                local infoSA = "start after, "
                local infoEB = "end before, "
                local infoEA = "end after, "

                if is_bleed then
                    if line.effect == "" then
                        line.effect = bleedString
                    else
                        line.effect = line.effect .. "; " .. bleedString
                    end

                    if opts.extraInfo then
                        line.effect = line.effect .. " ("
                        if bleedSB then line.effect = line.effect .. infoSB end
                        if bleedSA then line.effect = line.effect .. infoSA end
                        if bleedEB then line.effect = line.effect .. infoEB end
                        if bleedEA then line.effect = line.effect .. infoEA end
                        
                        -- remove final comma and space
                        line.effect = line.effect:sub(1, -3)

                        line.effect = line.effect .. ")"
                    end

                    bleed_count = bleed_count + 1
                end

                if subs[i] ~= line then
                    lines_edited = true
                end

                subs[i] = line
            end
        end
    end
    
    aegisub.log(3, bleed_count .. " scenebleeds found.\n")

    if lines_edited then
        aegisub.set_undo_point(script_name)
    end
    
    return sel
end

local function all_lines(subs)

    local sel = {}
    for i = 1, #subs do
        local line = subs[i]
        if line.class == "dialogue" then
            sel[#sel + 1] = i
        end
    end

    process(subs, sel)
end
    
local function sel_lines(subs, sel)
    process(subs, sel)
end

local macros = {
    {"Detect in Entire Script", script_description, all_lines},
    {"Detect in Selected Lines", script_description, sel_lines},
    {"Setup Config", "Open configuration menu", show_config_dialog}
}

if havedc then
    dep:registerMacros(macros)
else
    for _, macro in ipairs(macros) do
        local name, desc, fun, cond = unpack(macro)
        aegisub.register_macro(script_name .. '/' .. name, desc, fun, cond)
    end
end
