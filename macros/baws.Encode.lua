-- Copyright (c) 2026, McBaws
-- Copyright (c) 2020, petzku <petzku@zku.fi>
-- Copyright (c) 2020, The0x539 <the0x539@gmail.com>
--
-- Permission to use, copy, modify, and distribute this software for any
-- purpose with or without fee is hereby granted, provided that the above
-- copyright notice and this permission notice appear in all copies.
--
-- THE SOFTWARE IS PROVIDED 'AS IS' AND THE AUTHOR DISCLAIMS ALL WARRANTIES
-- WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
-- MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
-- ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
-- WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
-- ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
-- OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

script_name = 'Encode'
script_description = 'Encode various clips from the current selection'
script_author = 'McBaws'
script_namespace = "baws.Encode"
script_version = '1.0.0'

local haveDepCtrl, DependencyControl, depctrl = pcall(require, "l0.DependencyControl")
local ConfigHandler, config, petzku
if haveDepCtrl then
    depctrl = DependencyControl {
        feed="https://raw.githubusercontent.com/McBaws/Aegisub-Scripts/stable/DependencyControl.json",
        {
            {"petzku.util", version="0.5.2", url="https://github.com/petzku/Aegisub-Scripts",
             feed="https://raw.githubusercontent.com/petzku/Aegisub-Scripts/stable/DependencyControl.json"},
            {"a-mo.ConfigHandler", version="1.1.4", url="https://github.com/TypesettingTools/Aegisub-Motion",
             feed="https://raw.githubusercontent.com/TypesettingTools/Aegisub-Motion/DepCtrl/DependencyControl.json"}
        }
    }
    petzku, ConfigHandler = depctrl:requireModules()
else
    petzku = require 'petzku.util'
end

local LOGGER = petzku.io

-- ConfigHandler requires the schema to be structured exactly like Aegisub dialog elements
local config_schema = {
    gui = {
        video = {class="checkbox", value=true, config=true},
        subs = {class="checkbox", value=true, config=true},
        audio = {class="checkbox", value=true, config=true},
        context = {class="floatedit", value=0, config=true},
        tracking = {class="checkbox", value=false, config=true}
    },
    main = {
        mpv_exe = {class="edit", value="", config=true},
        output_path = {class="edit", value="?script", config=true},
        naming_base = {class="dropdown", value="Video", config=true},
        audio_encoder = {class="edit", value="", config=true},
        use_frames = {class="checkbox", value=true, config=true},
        extension = {class="dropdown", value="mkv", config=true},
        encoder = {class="dropdown", value="AVC", config=true},
        crf = {class="floatedit", value=-1, config=true},
        use_source_fps = {class="checkbox", value=true, config=true},
        force_fps = {class="edit", value="23.976", config=true},
        target_height = {class="intedit", value=-1, config=true},
        force_source_bitdepth = {class="checkbox", value=true, config=true},
        custom_bitdepth = {class="dropdown", value="8", config=true},
        force_square_pixels = {class="checkbox", value=false, config=true},
        two_pass = {class="checkbox", value=false, config=true},
        target_filesize = {class="intedit", value=0, config=true},
        strict_filesize = {class="checkbox", value=false, config=true},
        use_aid = {class="checkbox", value=false, config=true},
        aid = {class="intedit", value=2, config=true},
        video_command = {class="textbox", value="", config=true},
        audio_command = {class="textbox", value="", config=true}
    }
}

if haveDepCtrl then
    config = ConfigHandler(config_schema, depctrl.configFile, false, script_version, depctrl.configDir)
end

local function get_config(section)
    local c = {}
    for k, v in pairs(config_schema[section]) do
        c[k] = v.value
    end
    return c
end

local function update_config(section, new_values)
    for k, v in pairs(new_values) do
        if config_schema[section][k] then
            config_schema[section][k].value = v
        end
    end
    if haveDepCtrl then config:write() end
end

local function get_mpv(mpv_exe)
    if mpv_exe and mpv_exe ~= '' then
        LOGGER.trace("Found user-configured mpv: %s", mpv_exe)
        if mpv_exe:match(" ") and not mpv_exe:match("['\"]") then
            mpv_exe = '"'..mpv_exe..'"'
            LOGGER.trace("Added quotes around executable path: %s", mpv_exe)
        end
    else
        mpv_exe = 'mpv'
    end
    return mpv_exe
end

local function get_mkvmerge(mkvmerge_exe)
    if mkvmerge_exe and mkvmerge_exe ~= '' then
        LOGGER.trace("Found user-configured mkvmerge: %s", mkvmerge_exe)
        if mkvmerge_exe:match(" ") and not mkvmerge_exe:match("['\"]") then
            mkvmerge_exe = '"'..mkvmerge_exe..'"'
            LOGGER.trace("Added quotes around executable path: %s", mkvmerge_exe)
        end
    else
        mkvmerge_exe = 'mkvmerge'
    end
    return mkvmerge_exe
end

local function get_help_lines(option, cfg)
    local t = {}
    local mpv = get_mpv(cfg.mpv_exe)
    for line in petzku.io.run_cmd(mpv .. " --"..option.."=help", true):gmatch("[^\r\n]+") do
        table.insert(t, line)
    end
    local i = 0
    return function()
        i = i + 1
        if i <= #t then return t[i] end
    end
end

local audio_encoder = nil
local function get_audio_encoder(cfg)
    if audio_encoder ~= nil then return audio_encoder end
    if cfg.audio_encoder and cfg.audio_encoder ~= "" then return cfg.audio_encoder end

    local priorities = {aac = 0, libfdk_aac = 1, aac_mf = 2, aac_at = 3}
    local best = "aac"
    for line in get_help_lines("oac", cfg) do
        local enc = line:match("--oac=(%S*aac%S*)")
        if enc then
            if priorities[enc] and priorities[enc] > priorities[best] then
                best = enc
            end
        end
    end
    audio_encoder = best
    return best
end

local _should_encode_libx264 = nil
local function check_libx264_support(cfg)
    if _should_encode_libx264 then return _should_encode_libx264 end
    for line in get_help_lines("ovc", cfg) do
        if line:match("--ovc=libx264") then
            _should_encode_libx264 = true
            return _should_encode_libx264
        end
    end

    local btn = aegisub.dialog.display({
        {class="label", label="Warning: libx264 not found!", x=0, y=0},
        {class="label", label="Encoded clips will likely be broken.\nPlease install a version of mpv that supports libx264.", x=0, y=1}
    }, {"Encode anyway", "Cancel"})
    
    if btn == "Encode anyway" then
        _should_encode_libx264 = true
        return true
    end
    return false
end

local function gen_lavfi_cmd(dummystr)
    local fps, w, h, r, g, b = dummystr:match("dummy:([^:]+):[^:]+:([^:]+):([^:]+):([^:]+):([^:]+):([^:]+):")
    local color = string.format("0x%02x%02x%02x", r,g,b)
    fps = fps:gsub("\\", "/")
    return string.format("av://lavfi:color=c=%s:s=%dx%d:r=%s", color, w, h, fps)
end

local function is_ascii(str)
    for i=1, #str do
        if str:byte(i) > 128 then return false end
    end
    return true
end

local function run_cmd(cmd)
    local output = petzku.io.run_cmd(cmd)
    local WINDOWS_ASCII_ERROR_TEXT = "No such file or directory"
    if output:find(WINDOWS_ASCII_ERROR_TEXT) and not is_ascii(cmd) then
        LOGGER.warn("")
        LOGGER.warn("It looks like some of your input or output file names contain non-ASCII characters, which can break on some systems.")
        LOGGER.warn("Setting your system to use UTF-8 codepages may solve this issue; see https://superuser.com/a/1451686.")
        LOGGER.warn("")
    end
end

local function get_filename(path)
    if not path or path == "" then return "" end
    local name = path:match("^.+[/\\](.-)$") or path
    return name:gsub('%.[^.]+$', '')
end

local COMMON_FPS = {
    { value = 24000/1001, label = "24000/1001p" }, -- 23.976
    { value = 24,         label = "24p" },
    { value = 25,         label = "25p" },
    { value = 30000/1001, label = "30000/1001p" }, -- 29.97
    { value = 30,         label = "30p" },
    { value = 48000/1001, label = "48000/1001p" }, -- 47.952
    { value = 48,         label = "48p" },
    { value = 50,         label = "50p" },
    { value = 60000/1001, label = "60000/1001p" }, -- 59.94
    { value = 60,         label = "60p" },
    { value = 120000/1001,label = "120000/1001p" },-- 119.88
    { value = 120,        label = "120p" },
}

local function get_fps_label(fps, tolerance)
    if not fps or fps == -1 then return nil end
    tolerance = tolerance or 0.08

    local best_label, min_diff = nil, math.huge
    for _, entry in ipairs(COMMON_FPS) do
        local diff = math.abs(fps - entry.value)
        if diff < min_diff then
            min_diff = diff
            best_label = entry.label
        end
    end

    if min_diff <= tolerance then
        return best_label
    end
    -- no confident match: fall back to a raw decimal label
    return string.format("%.3fp", fps)
end

local function estimate_fps()
    local ms_start = aegisub.ms_from_frame(0)
    local last_frame = 100000
    local ms_end = aegisub.ms_from_frame(last_frame)
    local est_fps = last_frame * 1000 / (ms_end - ms_start)
    return est_fps
end

-- local function estimate_fps_from_ffprobe()
--     local props = aegisub.project_properties()
--     local video_file = props and props.video_file
--     if not video_file or video_file == "" then return nil end

--     local cmd = string.format('ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=nw=1:nk=1 "%s"', video_file)

--     local output = run_cmd(cmd)
--     if not output then return nil end

--     local num, den = output:match("(%d+)/(%d+)")
--     if num and den then
--         local n, d = tonumber(num), tonumber(den)
--         if n and d and d > 0 then
--             return n / d
--         end
--     end
--     local single = tonumber(output:match("[%d%.]+"))
--     return single
-- end

local function get_source_fps()
    return estimate_fps()
end

local function make_clip(subs, t1, t2, gui, cfg, src_fps)
    if not check_libx264_support(cfg) then return end

    local props = aegisub.project_properties()
    local vidfile = props.video_file
    local audiofile = props.audio_file
    local script_path = aegisub.decode_path("?script")
    local subfile = script_path .. petzku.io.pathsep .. aegisub.file_name()

    local is_audio_only = not gui.video
    
    local input_file = vidfile
    if is_audio_only and audiofile ~= "" then
        input_file = audiofile
    end

    local is_dummy = false
    if input_file:sub(1,7) == "?dummy:" then
        input_file = gen_lavfi_cmd(input_file)
        is_dummy = true
    end

    if gui.subs and not is_audio_only and is_dummy and subfile == "" then
        LOGGER.warn("Cannot hardsub dummy video without saved script!")
        return
    end

    if gui.subs and not is_audio_only and aegisub.gui and aegisub.gui.is_modified and aegisub.gui.is_modified() then
        local btn = aegisub.dialog.display({
            {class="label", label="File not saved!", x=0, y=0},
            {class="label", label="Current script file has not been saved.\nYou probably wanted to save first.", x=0, y=1}
        }, {"Encode anyway", "Cancel"})
        if btn ~= "Encode anyway" then return end
    end

    local out_dir = aegisub.decode_path(cfg.output_path or "?script")
    if out_dir == "" then out_dir = script_path end

    local base_name = ""
    local vid_name = get_filename(vidfile)
    local sub_name = get_filename(aegisub.file_name())
    if sub_name == "" then sub_name = "clip" end

    if cfg.naming_base == "Subtitle" then
        base_name = sub_name
    else
        base_name = (vid_name ~= "" and not is_dummy) and vid_name or sub_name
    end

    base_name = out_dir .. petzku.io.pathsep .. base_name

    local tags = ""
    if gui.subs and not is_audio_only then tags = tags .. "[Hardsub]" end
    if not gui.audio and not is_audio_only and (audiofile ~= "" or (vidfile ~= "" and not is_dummy)) then 
        tags = tags .. "[NoAudio]" 
    end

    local suffix = ""
    if gui.context > 0 or not cfg.use_frames then
        suffix = string.format("[%s-%s]", petzku.io.time_str(t1), petzku.io.time_str(t2))
        suffix = string.format("[%.3f-%.3f]", t1, t2)
    else
        local f1 = aegisub.frame_from_ms(math.floor(t1 * 1000)) or 0
        local f2 = aegisub.frame_from_ms(math.floor(t2 * 1000)) or 0
        suffix = string.format("[%d-%d]", f1, f2)
    end

    local ext = is_audio_only and "m4a" or cfg.extension
    local outfile = string.format("%s%s%s.%s", base_name, tags, suffix, ext)
    local outfile_temp = string.format("%s%s%s_TEMP.%s", base_name, tags, suffix, ext)

    local do_fps_remux = use_source_fps or cfg.force_fps ~= "-1" and cfg.extension == "mkv"
    local target_fps = use_source_fps and src_fps or cfg.force_fps

    local video_opts = {}
    local audio_opts = {}
    local sub_opts = {}
    local vf_filters = {}

    if is_audio_only then
        table.insert(video_opts, "--video=no")
    else
        table.insert(video_opts, "--profile=high-quality")
        local encoder_map = {
            ["AVC"] = "libx264",
            ["AVC-NVENC"] = "h264_nvenc",
            ["HEVC"] = "libx265",
            ["AV1"] = "libaom-av1"
        }
        
        if gui.tracking then
            table.insert(video_opts, "--ovc=libx264")
            table.insert(video_opts, '--ovcopts="profile=baseline,crf=18,preset=fast"')
            table.insert(vf_filters, "format=yuv420p")
            table.insert(vf_filters, "scale=iw*sar:ih")
        else
            local enc = encoder_map[cfg.encoder] or "libx264"
            table.insert(video_opts, "--ovc=" .. enc)
            
            local ovcopts = {}
            if cfg.target_filesize > 0 then
                local dur = t2 - t1
                if dur <= 0 then dur = 1 end
                local target_kb = cfg.target_filesize * 8
                if gui.audio then target_kb = target_kb - (dur * (cfg.strict_filesize and 64 or 128)) end
                local vb = math.floor(target_kb / dur)
                if vb < 0 then vb = 0 end
                
                table.insert(ovcopts, "b="..vb.."k")
                if cfg.strict_filesize then
                    table.insert(ovcopts, "minrate="..vb.."k")
                    table.insert(ovcopts, "maxrate="..vb.."k")
                end
            else
                if cfg.crf == -1 then
                    if enc == "libx264" or enc == "libx265" then
                        table.insert(ovcopts, "crf=18,preset=slow")
                    elseif enc == "libaom-av1" then
                        table.insert(ovcopts, "crf=20,cpu-used=4")
                    elseif enc == "h264_nvenc" then
                        table.insert(ovcopts, "cq=18,preset=p6")
                    end
                else
                    if enc == "h264_nvenc" then
                        table.insert(ovcopts, "cq="..cfg.crf)
                    else
                        table.insert(ovcopts, "crf="..cfg.crf)
                    end
                end
            end
            if #ovcopts > 0 then
                table.insert(video_opts, '--ovcopts="'..table.concat(ovcopts, ",")..'"')
            end

            if cfg.target_height > 0 then table.insert(vf_filters, "scale=-2:"..cfg.target_height) end
            if cfg.force_square_pixels then table.insert(vf_filters, "scale=iw*sar:ih") end
            if not cfg.force_source_bitdepth then
                local fmt = "yuv420p"
                if cfg.custom_bitdepth == "10" then fmt = "yuv420p10" end
                if cfg.custom_bitdepth == "12" then fmt = "yuv420p12" end
                table.insert(vf_filters, "format="..fmt)
            end
            
            if not do_fps_remux and cfg.use_source_fps then
                table.insert(vf_filters, "fps="..src_fps)
            elseif not do_fps_remux and cfg.force_fps ~= "-1" then
                table.insert(vf_filters, "fps="..cfg.force_fps)
            end
        end
        
        if #vf_filters > 0 then
            table.insert(video_opts, '--vf-add='..table.concat(vf_filters, ","))
        end
    end

    if gui.audio then
        local a_enc = cfg.audio_encoder
        if a_enc == "" then a_enc = get_audio_encoder(cfg) end
        table.insert(audio_opts, "--oac=" .. a_enc)
        
        local ab = (cfg.target_filesize > 0 and cfg.strict_filesize) and 64 or 256
        table.insert(audio_opts, '--oacopts="b='..ab..'k,frame_size=1024"')
        
        if cfg.use_aid then table.insert(audio_opts, "--aid=" .. cfg.aid) end
        if audiofile ~= "" and audiofile ~= vidfile and not is_audio_only then
            table.insert(audio_opts, string.format('--audio-file="%s"', audiofile))
        end
    else
        table.insert(audio_opts, "--audio=no")
    end

    if gui.subs and not is_audio_only then
        table.insert(sub_opts, string.format('--sub-file="%s"', subfile))
    else
        table.insert(sub_opts, "--sid=no")
    end

    local base_cmd = string.format('%s --no-config --start=%.3f --end=%.3f "%s" --o="%s"', get_mpv(cfg.mpv_exe), t1, t2, input_file, do_fps_remux and outfile_temp or outfile)
    
    local all_opts = {}
    for _,o in ipairs(video_opts) do table.insert(all_opts, o) end
    for _,o in ipairs(audio_opts) do table.insert(all_opts, o) end
    for _,o in ipairs(sub_opts) do table.insert(all_opts, o) end

    local custom = is_audio_only and cfg.audio_command or cfg.video_command
    if custom and custom ~= "" then
        table.insert(all_opts, (custom:gsub("\n", " ")))
    end

    local final_cmd = base_cmd .. " " .. table.concat(all_opts, " ")
    
    if not is_audio_only and cfg.two_pass and cfg.target_filesize > 0 then
        LOGGER.trace("Running Pass 1")
        run_cmd(final_cmd .. " --ovcopts-add=flags=+pass1")
        LOGGER.trace("Running Pass 2")
        run_cmd(final_cmd .. " --ovcopts-add=flags=+pass2")
    else
        run_cmd(final_cmd)
    end

    if do_fps_remux then
        run_cmd(string.format('%s --output "%s" --default-duration 1:%s "%s"', get_mkvmerge(cfg.mkvmerge_exe), outfile, get_fps_label(target_fps), outfile_temp))
        
        local success, reason = os.remove(outfile_temp)
        if success then
            print("File deleted successfully")
        else
            LOGGER.Error("Error: " .. reason)
        end
    end
end

local function do_encode(subs, sel, gui_vals, each_line)
    local c = get_config("main")
    local src_fps = get_source_fps()
    
    local ranges = {}
    if each_line then
        for _, i in ipairs(sel) do
            local t1 = subs[i].start_time / 1000
            local t2 = subs[i].end_time / 1000
            table.insert(ranges, {t1=t1, t2=t2})
        end
        local uniq = {}
        for _, r in ipairs(ranges) do
            local dup = false
            for _, u in ipairs(uniq) do
                if r.t1 == u.t1 and r.t2 == u.t2 then dup = true break end
            end
            if not dup then table.insert(uniq, r) end
        end
        ranges = uniq
    else
        local t1, t2 = math.huge, 0
        for _, i in ipairs(sel) do
            t1 = math.min(t1, subs[i].start_time / 1000)
            t2 = math.max(t2, subs[i].end_time / 1000)
        end
        if t1 < t2 then
            table.insert(ranges, {t1=t1, t2=t2})
        end
    end
    
    for _, r in ipairs(ranges) do
        local t1 = r.t1
        local t2 = r.t2
        if gui_vals.context > 0 then
            t1 = math.max(0, t1 - gui_vals.context)
            t2 = t2 + gui_vals.context
        end
        make_clip(subs, t1, t2, gui_vals, c, src_fps)
    end
end

local function show_config_dialog()
    local c = get_config("main")
    
    local c_def = {
        { class='label', label='mpv path:', x=0, y=0 },
        { class='edit', name='mpv_exe', value=c.mpv_exe, x=1, y=0, width=3, hint=[[Path to the mpv executable.
If left blank, searches system PATH.]] },

        { class='label', label='mkvmerge path:', x=0, y=1 },
        { class='edit', name='mkvmerge_exe', value=c.mkvmerge_exe, x=1, y=1, width=3, hint=[[Path to the mkvmerge executable.
If left blank, searches system PATH.]] },
        
        { class='label', label='Output Path:', x=0, y=2 },
        { class='edit', name='output_path', value=c.output_path, x=1, y=2, width=3, hint='Use ?script for current folder' },

        { class='label', label='Base Filename:', x=0, y=3 },
        { class='dropdown', name='naming_base', items={"Video", "Subtitle"}, value=c.naming_base, x=1, y=3, width=3 },

        { class='label', label='Extension:', x=0, y=4 },
        { class='dropdown', name='extension', items={"mp4", "mkv"}, value=c.extension, x=1, y=4, width=3 },

        { class='checkbox', name='use_frames', label='Use frames in filename', value=c.use_frames, x=0, y=5, width=4, hint=[[Will use timestamps otherwise.]] },

        { class='label', label='Video Encoder:', x=0, y=6 },
        { class='dropdown', name='encoder', items={"AVC", "AVC-NVENC", "HEVC", "AV1"}, value=c.encoder, x=1, y=6, width=3 },

        { class='label', label='CRF (-1 for default):', x=0, y=7 },
        { class='floatedit', name='crf', value=c.crf, x=1, y=7, width=3, hint=[[Default is reasonably high quality (eg. crf18 for AVC). Sets cq for AVC-NVENC.]] },
        
        { class='label', label='Audio Encoder:', x=0, y=8 },
        { class='edit', name='audio_encoder', value=c.audio_encoder, x=1, y=8, width=3, hint=[[Audio encoder to use.
If left blank, automatically picks the best available AAC encoder.
Note that you may need to change --oacopts if you use a non-AAC encoder.]] },

        { class='checkbox', name='use_aid', label='Force Audio ID:', value=c.use_aid, x=0, y=9, hint=[[Enable forcing audio track.
If unset, mpv will fallback to its defaults (which might decide based on user locale), unless the settings above override it.
If set, the value given to the right will be supplied to --aid.]] },
        { class='intedit', name='aid', value=c.aid, x=1, y=9, hint=[[Audio track ID to use.
Supplied to mpv as --aid, so this is indexed starting from 1. Supplying an out-of-bounds track ID will cause no audio to be included.
If you want to consistently select by language, just use --alang in the config sections above.]] },

        { class='checkbox', name='use_source_fps', label='Use source FPS', value=c.use_source_fps, x=0, y=10 },
        { class='label', label='Or force FPS to:', x=1, y=10 },
        { class='edit', name='force_fps', value=c.force_fps, x=2, y=10, width=2 },

        { class='checkbox', name='force_source_bitdepth', label='Use source bit depth', value=c.force_source_bitdepth, x=0, y=11 },
        { class='label', label='Or custom depth:', x=1, y=11 },
        { class='dropdown', name='custom_bitdepth', items={"8", "10", "12"}, value=c.custom_bitdepth, x=2, y=11, width=2 },

        { class='label', label='Target Filesize (KB, 0=off):', x=0, y=12 },
        { class='intedit', name='target_filesize', value=c.target_filesize, x=1, y=12 },
        { class='checkbox', name='strict_filesize', label='Strict Constraint', value=c.strict_filesize, x=2, y=12, width=2 },

        { class='label', label='Output Height (-1 is original):', x=0, y=13 },
        { class='intedit', name='target_height', value=c.target_height, x=1, y=13 },
        { class='checkbox', name='force_square_pixels', label='Force square pixels', value=c.force_square_pixels, x=2, y=13, width=2 },

        { class='checkbox', name='two_pass', label='Two Pass', value=c.two_pass, x=0, y=14, width=4 },

        { class='label', label='Custom Video Options:', x=0, y=15, width=4 },
        { class='textbox', name='video_command', value=c.video_command, x=0, y=16, width=4, height=2, hint=[[Custom command line options passed to mpv when encoding video.
You can put options on separate lines, but all options must be prefixed with --. (e.g. "--aid=2" to pick the second audio track in the file)]] },

        { class='label', label='Custom Audio-Only Options:', x=0, y=18, width=4 },
        { class='textbox', name='audio_command', value=c.audio_command, x=0, y=19, width=4, height=2, hint=[[Custom command line options passed to mpv when encoding only audio.
Options here do NOT get applied when encoding video, whether it has audio or not.]] },
    }
    
    local btn, result = aegisub.dialog.display(c_def, {"Save", "Cancel"}, {ok="Save", cancel="Cancel"})
    if btn == "Save" then
        update_config("main", result)
    end
end

local function show_dialog(subs, sel)
    local g = get_config("gui")
    
    local gui_def = {
        { class='checkbox', name='video', label='Include Video', value=g.video, x=0, y=0 },
        { class='checkbox', name='subs', label='Include Hardsubs', value=g.subs, x=0, y=1 },
        { class='checkbox', name='audio', label='Include Audio', value=g.audio, x=0, y=2 },
        { class='label', label='Include Context (sec):', x=0, y=3 },
        { class='floatedit', name='context', value=g.context, x=1, y=3, hint=[[Extra duration (in seconds) to add at the start and end of a clip. Limited to 30 seconds.]] },
        { class='checkbox', name='tracking', label='Tracking Mode (AVC 8bit SAR 1:1)', value=g.tracking, x=0, y=4, hint='High compatibility encode settings. Ignores quality settings.' }
    }
    
    local buttons = {"Encode", "Encode Each Line", "Config", "Cancel"}
    local btn, result = aegisub.dialog.display(gui_def, buttons, {ok="Encode", cancel="Cancel"})
    
    if btn == "Cancel" then return end
    
    if btn == "Config" then
        show_config_dialog()
        show_dialog(subs, sel)
        return
    end
    
    update_config("gui", result)
    
    if btn == "Encode" then
        do_encode(subs, sel, result, false)
    elseif btn == "Encode Each Line" then
        do_encode(subs, sel, result, true)
    end
end

if haveDepCtrl then
    depctrl:registerMacro(show_dialog)
else
    aegisub.register_macro(script_name, script_description, show_dialog)
end
