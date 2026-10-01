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
script_version = '2.0.0'

local haveDepCtrl, DependencyControl, depctrl = pcall(require, "l0.DependencyControl")
local ConfigHandler, config
if haveDepCtrl then
    depctrl = DependencyControl {
        feed="https://raw.githubusercontent.com/McBaws/Aegisub-Scripts/stable/DependencyControl.json",
        {
            {"a-mo.ConfigHandler", version="1.1.4", url="https://github.com/TypesettingTools/Aegisub-Motion",
             feed="https://raw.githubusercontent.com/TypesettingTools/Aegisub-Motion/DepCtrl/DependencyControl.json"}
        }
    }
    ConfigHandler = depctrl:requireModules()
end

local is_windows = package.config:sub(1, 1) == "\\"
local pathsep = is_windows and "\\" or "/"

-- ConfigHandler requires the schema to be structured exactly like Aegisub dialog elements
local config_schema = {
    gui = {
        video = {class="checkbox", value=true, config=true},
        subs = {class="checkbox", value=true, config=true},
        audio = {class="checkbox", value=true, config=true},
        context = {class="floatedit", value=0, config=true},
        tracking = {class="checkbox", value=false, config=true},
        output = {class="dropdown", value="Video", config=true}
    },
    main = {
        python_exe = {class="edit", value="", config=true},
        script_path = {class="edit", value="", config=true},
        ffmpeg_exe = {class="edit", value="", config=true},
        indexer = {class="dropdown", value="Auto", config=true},
        output_path = {class="edit", value="?script", config=true},
        naming_base = {class="dropdown", value="Video", config=true},
        audio_encoder = {class="edit", value="", config=true},
        use_frames = {class="checkbox", value=true, config=true},
        extension = {class="dropdown", value="mkv", config=true},
        encoder = {class="dropdown", value="AVC", config=true},
        crf = {class="floatedit", value=-1, config=true},
        use_source_fps = {class="checkbox", value=true, config=true},
        force_fps = {class="edit", value="24000/1001", config=true},
        target_height = {class="intedit", value=-1, config=true},
        force_source_bitdepth = {class="checkbox", value=true, config=true},
        custom_bitdepth = {class="dropdown", value="8", config=true},
        force_square_pixels = {class="checkbox", value=false, config=true},
        two_pass = {class="checkbox", value=false, config=true},
        target_filesize = {class="intedit", value=0, config=true},
        strict_filesize = {class="checkbox", value=false, config=true},
        use_aid = {class="checkbox", value=false, config=true},
        aid = {class="intedit", value=1, config=true},
        image_format = {class="dropdown", value="jpg", config=true},
        jpeg_quality = {class="intedit", value=95, config=true},
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

local function strip_slash(p)
    return (p:gsub("[/\\]+$", ""))
end

local function quote(p)
    if p:match('^".*"$') then return p end
    return '"' .. p .. '"'
end

local function file_exists(p)
    local f = io.open(p, "rb")
    if f then f:close() return true end
    return false
end

local function get_filename(path)
    if not path or path == "" then return "" end
    local name = path:match("^.+[/\\](.-)$") or path
    return (name:gsub('%.[^.]+$', ''))
end

-- tiny json writer, only needs to handle what we put in the job file
local function json_encode(v)
    local t = type(v)
    if t == "table" then
        local parts = {}
        if v[1] ~= nil then
            for _, x in ipairs(v) do table.insert(parts, json_encode(x)) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        for k, x in pairs(v) do
            table.insert(parts, json_encode(tostring(k)) .. ":" .. json_encode(x))
        end
        return "{" .. table.concat(parts, ",") .. "}"
    elseif t == "string" then
        local esc = {['"']='\\"', ['\\']='\\\\', ['\n']='\\n', ['\r']='\\r', ['\t']='\\t'}
        return '"' .. v:gsub('[%c"\\]', function(c)
            return esc[c] or string.format("\\u%04x", c:byte())
        end) .. '"'
    elseif t == "number" then
        if v == math.floor(v) and math.abs(v) < 2^53 then return string.format("%d", v) end
        return string.format("%.17g", v)
    elseif t == "boolean" then
        return v and "true" or "false"
    end
    return "null"
end

local function estimate_fps()
    local ms0 = aegisub.ms_from_frame(0)
    local ms1 = aegisub.ms_from_frame(100000)
    if not ms0 or not ms1 or ms1 <= ms0 then return nil end
    return string.format("%.6f", 100000 * 1000 / (ms1 - ms0))
end

local function default_script_path()
    return aegisub.decode_path("?user/automation/include/baws/encode_vs.py")
end

-- turns line times into frames the same way aegisub-motion does: first visible frame, exclusive end frame
local function make_range(start_ms, end_ms, ctx)
    if ctx > 0 then
        start_ms = math.max(0, start_ms - ctx * 1000)
        end_ms = end_ms + ctx * 1000
    end
    local r = {start_ms = math.floor(start_ms), end_ms = math.floor(end_ms)}
    local first = aegisub.frame_from_ms(r.start_ms)
    if first then
        r.first = math.max(0, first)
        r["end"] = aegisub.frame_from_ms(r.end_ms)
        r.aegi_first_ms = aegisub.ms_from_frame(r.first)
    end
    return r
end

local function run_job(cfg, job)
    local temp = strip_slash(aegisub.decode_path("?temp"))
    local job_path = string.format("%s%sbaws_encode_%d_%d.json", temp, pathsep, os.time(), math.random(1, 1000000))
    local cancel_path = job_path .. ".cancel"

    local script = cfg.script_path ~= "" and cfg.script_path or default_script_path()
    if not file_exists(script) then
        aegisub.log(0, "Can't find the worker script at:\n%s\nPut encode_vs.py there or set its path in Config.\n", script)
        return
    end

    local f = io.open(job_path, "wb")
    if not f then
        aegisub.log(0, "Couldn't write the job file to %s\n", job_path)
        return
    end
    f:write(json_encode(job))
    f:close()

    local py = cfg.python_exe ~= "" and cfg.python_exe or (is_windows and "python" or "python3")
    local cmd = string.format('%s -u %s %s 2>&1', quote(py), quote(script), quote(job_path))
    -- cmd.exe eats the outer quotes when a command starts with one, so wrap the whole thing
    if is_windows then cmd = '"' .. cmd .. '"' end

    local status
    local cancel_sent = false
    local p = io.popen(cmd, "r")
    if p then
        for line in p:lines() do
            line = line:gsub("\r$", "")
            local pct = line:match("^@@PROGRESS (%S+)")
            if pct then
                aegisub.progress.set(tonumber(pct) or 0)
            elseif line:sub(1, 7) == "@@TASK " then
                aegisub.progress.task(line:sub(8))
            elseif line == "@@OK" or line == "@@FAILED" or line == "@@CANCELLED" then
                status = line:sub(3)
            elseif line ~= "" then
                aegisub.log("%s\n", line)
            end
            if not cancel_sent and aegisub.progress.is_cancelled() then
                -- python checks for this file and bails out
                local c = io.open(cancel_path, "wb")
                if c then c:close() end
                cancel_sent = true
            end
        end
        p:close()
    end

    os.remove(job_path)
    os.remove(cancel_path)

    if not status then
        aegisub.log(0, "The worker didn't run properly. Check the Python path in Config (it needs vapoursynth installed).\n")
    elseif status == "FAILED" then
        aegisub.log(0, "Encode failed, see above.\n")
    end
end

local function do_encode(subs, sel, gui, each_line)
    local cfg = get_config("main")
    local props = aegisub.project_properties()
    local vidfile = props.video_file or ""
    local audiofile = props.audio_file or ""

    local mode = "video"
    if gui.output == "Image sequence" then
        mode = "images"
    elseif not gui.video then
        mode = "audio"
    end

    if mode ~= "audio" and vidfile == "" then
        aegisub.log(0, "No video loaded.\n")
        return
    end
    if mode == "audio" and vidfile == "" and audiofile == "" then
        aegisub.log(0, "No audio or video loaded.\n")
        return
    end

    local script_dir = aegisub.decode_path("?script")
    local hardsub = gui.subs and mode ~= "audio"
    local subfile = ""
    if hardsub then
        if script_dir == "?script" or not aegisub.file_name() then
            aegisub.log(0, "Save the subtitle file first, hardsubbing reads it from disk.\n")
            return
        end
        subfile = script_dir .. pathsep .. aegisub.file_name()
        if aegisub.gui and aegisub.gui.is_modified and aegisub.gui.is_modified() then
            local btn = aegisub.dialog.display({
                {class="label", label="File not saved!", x=0, y=0},
                {class="label", label="Current script file has not been saved.\nYou probably wanted to save first.", x=0, y=1}
            }, {"Encode anyway", "Cancel"})
            if btn ~= "Encode anyway" then return end
        end
    end

    local spans = {}
    if each_line then
        for _, i in ipairs(sel) do
            local s, e = subs[i].start_time, subs[i].end_time
            local dup = false
            for _, u in ipairs(spans) do
                if u[1] == s and u[2] == e then dup = true break end
            end
            if not dup then table.insert(spans, {s, e}) end
        end
    else
        local s, e = math.huge, 0
        for _, i in ipairs(sel) do
            s = math.min(s, subs[i].start_time)
            e = math.max(e, subs[i].end_time)
        end
        if s < e then table.insert(spans, {s, e}) end
    end

    local out_dir = aegisub.decode_path(cfg.output_path ~= "" and cfg.output_path or "?script")
    if out_dir == "" or out_dir:sub(1, 1) == "?" then out_dir = script_dir end
    out_dir = strip_slash(out_dir)

    local is_dummy = vidfile:sub(1, 7) == "?dummy:"
    local vid_name = get_filename(vidfile)
    local sub_name = get_filename(aegisub.file_name())
    if sub_name == "" then sub_name = "clip" end
    local base_name
    if cfg.naming_base == "Subtitle" or is_dummy or vid_name == "" then
        base_name = sub_name
    else
        base_name = vid_name
    end
    base_name = out_dir .. pathsep .. base_name

    local tags = ""
    if hardsub then tags = tags .. "[Hardsub]" end
    if mode == "video" and not gui.audio and not is_dummy then tags = tags .. "[NoAudio]" end

    local ranges = {}
    for _, sp in ipairs(spans) do
        local r = make_range(sp[1], sp[2], gui.context)
        if mode ~= "audio" and not r.first then
            aegisub.log(0, "Aegisub has no timecodes loaded, can't work out frame numbers.\n")
            return
        end
        if mode ~= "audio" and r["end"] <= r.first then
            aegisub.log(2, "Skipping %d-%d ms, it doesn't cover a whole frame.\n", sp[1], sp[2])
        else
            local suffix
            if gui.context > 0 or not cfg.use_frames or not r.first then
                suffix = string.format("[%.3f-%.3f]", r.start_ms / 1000, r.end_ms / 1000)
            else
                suffix = string.format("[%d-%d]", r.first, r["end"])
            end
            if mode == "images" then
                r.outdir = base_name .. tags .. suffix
            else
                local ext = mode == "audio" and "m4a" or cfg.extension
                r.outfile = string.format("%s%s%s.%s", base_name, tags, suffix, ext)
            end
            table.insert(ranges, r)
        end
    end
    if #ranges == 0 then return end

    local job = {
        mode = mode,
        video = vidfile,
        video_dir = aegisub.decode_path("?video"),
        audio_file = (audiofile ~= vidfile) and audiofile or "",
        subfile = subfile,
        vscache = aegisub.decode_path("?local/vscache"),
        data_dir = aegisub.decode_path("?data"),
        user_dir = aegisub.decode_path("?user"),
        temp_dir = strip_slash(aegisub.decode_path("?temp")),
        indexer = cfg.indexer,
        fallback_fps = estimate_fps() or "",
        gui = {subs = hardsub, audio = gui.audio, tracking = gui.tracking},
        settings = cfg,
        ranges = ranges
    }
    run_job(cfg, job)
end

local function show_config_dialog()
    local c = get_config("main")

    local c_def = {
        { class='label', label='Python path:', x=0, y=0 },
        { class='edit', name='python_exe', value=c.python_exe, x=1, y=0, width=3, hint=[[Python that has vapoursynth + vsjetpack installed.
If left blank, uses python from PATH.]] },

        { class='label', label='Worker script:', x=0, y=1 },
        { class='edit', name='script_path', value=c.script_path, x=1, y=1, width=3, hint=[[Path to encode_vs.py.
If left blank, uses ?user/automation/include/baws/encode_vs.py]] },

        { class='label', label='ffmpeg path:', x=0, y=2 },
        { class='edit', name='ffmpeg_exe', value=c.ffmpeg_exe, x=1, y=2, width=3, hint=[[Path to the ffmpeg executable (encoding + muxing).
If left blank, searches system PATH.]] },

        { class='label', label='Indexer:', x=0, y=3 },
        { class='dropdown', name='indexer', items={"Auto", "LSMASH", "BestSource", "FFMS2"}, value=c.indexer, x=1, y=3, width=3, hint=[[Auto picks whatever matches Aegisub's video provider.
With Aegisub's VapourSynth provider, LSMASH reuses Aegisub's own index.]] },

        { class='label', label='Output Path:', x=0, y=4 },
        { class='edit', name='output_path', value=c.output_path, x=1, y=4, width=3, hint='Use ?script for current folder' },

        { class='label', label='Base Filename:', x=0, y=5 },
        { class='dropdown', name='naming_base', items={"Video", "Subtitle"}, value=c.naming_base, x=1, y=5, width=3 },

        { class='label', label='Extension:', x=0, y=6 },
        { class='dropdown', name='extension', items={"mp4", "mkv"}, value=c.extension, x=1, y=6, width=3 },

        { class='checkbox', name='use_frames', label='Use frames in filename', value=c.use_frames, x=0, y=7, width=4, hint=[[Will use timestamps otherwise.]] },

        { class='label', label='Video Encoder:', x=0, y=8 },
        { class='dropdown', name='encoder', items={"AVC", "AVC-NVENC", "HEVC", "AV1"}, value=c.encoder, x=1, y=8, width=3, hint=[[AVC = libx264, HEVC = libx265, AV1 = libsvtav1 (all via ffmpeg)]] },

        { class='label', label='CRF (-1 for default):', x=0, y=9 },
        { class='floatedit', name='crf', value=c.crf, x=1, y=9, width=3, hint=[[Default is reasonably high quality (eg. crf18 for AVC). Sets cq for AVC-NVENC.]] },

        { class='label', label='Audio Encoder:', x=0, y=10 },
        { class='edit', name='audio_encoder', value=c.audio_encoder, x=1, y=10, width=3, hint=[[ffmpeg audio encoder name.
If left blank, picks the best AAC encoder your ffmpeg has.]] },

        { class='checkbox', name='use_aid', label='Force Audio ID:', value=c.use_aid, x=0, y=11, hint=[[Pick which audio track to use, otherwise the first one.]] },
        { class='intedit', name='aid', value=c.aid, x=1, y=11, min=1, hint=[[Audio track to use, counting audio tracks only, starting from 1.]] },

        { class='checkbox', name='use_source_fps', label='Use source FPS', value=c.use_source_fps, x=0, y=12 },
        { class='label', label='Or label FPS as:', x=1, y=12 },
        { class='edit', name='force_fps', value=c.force_fps, x=2, y=12, width=2, hint=[[e.g. 24000/1001. Only relabels the output rate, frames are never added or dropped.]] },

        { class='checkbox', name='force_source_bitdepth', label='Use source bit depth', value=c.force_source_bitdepth, x=0, y=13 },
        { class='label', label='Or custom depth:', x=1, y=13 },
        { class='dropdown', name='custom_bitdepth', items={"8", "10", "12"}, value=c.custom_bitdepth, x=2, y=13, width=2 },

        { class='label', label='Target Filesize (KB, 0=off):', x=0, y=14 },
        { class='intedit', name='target_filesize', value=c.target_filesize, x=1, y=14 },
        { class='checkbox', name='strict_filesize', label='Strict Constraint', value=c.strict_filesize, x=2, y=14, width=2 },

        { class='label', label='Output Height (-1 is original):', x=0, y=15 },
        { class='intedit', name='target_height', value=c.target_height, x=1, y=15 },
        { class='checkbox', name='force_square_pixels', label='Force square pixels', value=c.force_square_pixels, x=2, y=15, width=2 },

        { class='checkbox', name='two_pass', label='Two Pass', value=c.two_pass, x=0, y=16, width=4 },

        { class='label', label='Image Format:', x=0, y=17 },
        { class='dropdown', name='image_format', items={"jpg", "png"}, value=c.image_format, x=1, y=17 },
        { class='label', label='JPEG Quality:', x=2, y=17 },
        { class='intedit', name='jpeg_quality', value=c.jpeg_quality, x=3, y=17, min=1, max=100, hint=[[1-100, used for jpg image sequences.]] },

        { class='label', label='Custom Video Options:', x=0, y=18, width=4 },
        { class='textbox', name='video_command', value=c.video_command, x=0, y=19, width=4, height=2, hint=[[Extra ffmpeg output options for video encodes, e.g. -tune animation
These used to be mpv options; anything starting with -- gets ignored.]] },

        { class='label', label='Custom Audio-Only Options:', x=0, y=21, width=4 },
        { class='textbox', name='audio_command', value=c.audio_command, x=0, y=22, width=4, height=2, hint=[[Extra ffmpeg output options when encoding only audio.]] },
    }

    local btn, result = aegisub.dialog.display(c_def, {"Save", "Cancel"}, {ok="Save", cancel="Cancel"})
    if btn == "Save" then
        update_config("main", result)
    end
end

local function show_dialog(subs, sel)
    local g = get_config("gui")

    local gui_def = {
        { class='label', label='Output:', x=0, y=0 },
        { class='dropdown', name='output', items={"Video", "Image sequence"}, value=g.output, x=1, y=0 },
        { class='checkbox', name='video', label='Include Video', value=g.video, x=0, y=1, hint='Untick for audio only' },
        { class='checkbox', name='subs', label='Include Hardsubs', value=g.subs, x=0, y=2 },
        { class='checkbox', name='audio', label='Include Audio', value=g.audio, x=0, y=3 },
        { class='label', label='Include Context (sec):', x=0, y=4 },
        { class='floatedit', name='context', value=g.context, x=1, y=4, hint=[[Extra duration (in seconds) to add at the start and end of a clip.]] },
        { class='checkbox', name='tracking', label='Tracking Mode (AVC 8bit SAR 1:1)', value=g.tracking, x=0, y=5, width=2, hint='High compatibility encode settings. Ignores quality settings.' }
    }

    local buttons = {"Encode", "Encode Each Line", "Config", "Cancel"}
    local btn, result = aegisub.dialog.display(gui_def, buttons, {ok="Encode", cancel="Cancel"})

    if not btn or btn == "Cancel" then return end

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