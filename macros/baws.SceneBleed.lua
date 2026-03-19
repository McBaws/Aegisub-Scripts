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
script_version = "1.0.0"
script_namespace = "baws.SceneBleed"

local havedc, DependencyControl = pcall(require, "l0.DependencyControl")
local dep, ConfigHandler, config
if havedc then
    dep = DependencyControl{
        feed = "https://raw.githubusercontent.com/McBaws/Aegisub-Scripts/stable/DependencyControl.json",
        {
            {"a-mo.ConfigHandler", version = "1.1.4", url = "https://github.com/TypesettingTools/Aegisub-Motion",
             feed = "https://raw.githubusercontent.com/TypesettingTools/Aegisub-Motion/DepCtrl/DependencyControl.json"},
        }
    }
    ConfigHandler = dep:requireModules()
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

if havedc then
    config = ConfigHandler(config_diag, dep.configFile, false, script_version, dep.configDir)
end

local function get_configuration()
    if havedc then
        config:read()
        config:updateInterface("main")
    end
    local opts = {}
    for key, values in pairs(config_diag.main) do
        if values.config then
            opts[key] = values.value
        end
    end
    return opts
end

local function show_config_dialog()
    if havedc then
        config:read()
        config:updateInterface("main")
        local button, result = aegisub.dialog.display(config_diag.main)
        if button then
            config:updateConfiguration(result, 'main')
            config:write()
            config:updateInterface('main')
        end
    else
        -- Fallback if no DependencyControl: show dialog and keep stored while program running
        local button, result = aegisub.dialog.display(config_diag.main)
        if button then
            for k, v in pairs(result) do
                if config_diag.main[k] then
                    config_diag.main[k].value = v
                end
            end
        end
    end
end

local function process(subs, sel)
    local opts = get_configuration()
    local threshSB = aegisub.frame_from_ms(opts.thresholdStartBefore)
    local threshSA = aegisub.frame_from_ms(opts.thresholdStartAfter)
    local threshEB = aegisub.frame_from_ms(opts.thresholdEndBefore)
    local threshEA = aegisub.frame_from_ms(opts.thresholdEndAfter)
    local bleedString = opts.bleedString

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

                local bleedSB, bleedSA, bleedEB, bleedEA = false
                for _, frame in ipairs(keyframes) do
                    bleedSB = bleedSB or (start_frame < frame and start_frame >= frame - threshSB)
                    bleedSA = bleedSA or (start_frame > frame and start_frame < frame + threshSA)
                    bleedEB = bleedEB or (end_frame < frame and end_frame >= frame - threshEB)
                    bleedEA = bleedEA or (end_frame > frame and end_frame < frame + threshEA)

                    if end_frame < frame - (threshEB * 2) then
                        break
                    end
                end

                local is_bleed = false
                if bleedSB or bleedSA or bleedEB or bleedEA then
                    is_bleed = true
                end

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
                        if bleedSB then
                            line.effect = line.effect .. infoSB
                        end
                        if bleedSA then
                            line.effect = line.effect .. infoSA
                        end
                        if bleedEB then
                            line.effect = line.effect .. infoEB
                        end
                        if bleedEA then
                            line.effect = line.effect .. infoEA
                        end
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