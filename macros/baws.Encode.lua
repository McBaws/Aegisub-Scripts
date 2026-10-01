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
script_description = 'Encode clips, audio or image sequences from the current selection'
script_author = 'McBaws'
script_namespace = "baws.Encode"
script_version = '2.0.0'

local haveDepCtrl, DependencyControl, depctrl = pcall(require, "l0.DependencyControl")
local ConfigHandler, EncodeVS, config
if haveDepCtrl then
    depctrl = DependencyControl {
        feed="https://raw.githubusercontent.com/McBaws/Aegisub-Scripts/stable/DependencyControl.json",
        {
            {"a-mo.ConfigHandler", version="1.1.4", url="https://github.com/TypesettingTools/Aegisub-Motion",
             feed="https://raw.githubusercontent.com/TypesettingTools/Aegisub-Motion/DepCtrl/DependencyControl.json"},
            {"baws.EncodeVS", version="1.0.0", url="https://github.com/McBaws/Aegisub-Scripts",
             feed="https://raw.githubusercontent.com/McBaws/Aegisub-Scripts/stable/DependencyControl.json"}
        }
    }
    ConfigHandler, EncodeVS = depctrl:requireModules()
else
    local ok, mod = pcall(require, "baws.EncodeVS")
    if ok then EncodeVS = mod end
end

local is_windows = package.config:sub(1, 1) == "\\"
local pathsep = is_windows and "\\" or "/"

local VIDEO_CODECS = {"x264 (AVC)", "x265 (HEVC)", "SVT-AV1 (AV1)", "NVENC (AVC)", "MP4 (H.264 + AAC)", "WebM (VP9 + Opus)"}
local AUDIO_CODECS = {"Opus", "FLAC", "AAC"}
local AUDIO_EXT = {Opus="opus", FLAC="flac", AAC="m4a"}
local INDEXERS = {"Auto", "LWI", "FFMS2", "BestSource"}

-- ConfigHandler requires the schema to be structured exactly like Aegisub dialog elements
local config_schema = {
    video = {
        audio = {class="checkbox", value=true, config=true},
        subs = {class="checkbox", value=true, config=true},
        hardsub = {class="checkbox", value=false, config=true},
        codec = {class="dropdown", value="x264 (AVC)", config=true},
        crf = {class="floatedit", value=-1, config=true},
        target_kb = {class="intedit", value=0, config=true},
        height = {class="intedit", value=0, config=true},
        bitdepth = {class="dropdown", value="Source", config=true},
        fps = {class="edit", value="", config=true},
        audio_codec = {class="dropdown", value="Opus", config=true},
        audio_bitrate = {class="intedit", value=192, config=true}
    },
    audio = {
        audio_codec = {class="dropdown", value="Opus", config=true},
        audio_bitrate = {class="intedit", value=192, config=true}
    },
    images = {
        image_format = {class="dropdown", value="png", config=true},
        quality = {class="intedit", value=95, config=true}
    },
    main = {
        python_exe = {class="edit", value="", config=true},
        ffmpeg_exe = {class="edit", value="", config=true},
        mkvmerge_exe = {class="edit", value="", config=true},
        x264_exe = {class="edit", value="", config=true},
        x265_exe = {class="edit", value="", config=true},
        svtav1_exe = {class="edit", value="", config=true},
        opusenc_exe = {class="edit", value="", config=true},
        flac_exe = {class="edit", value="", config=true},
        qaac_exe = {class="edit", value="", config=true},
        indexer = {class="dropdown", value="Auto", config=true},
        output_path = {class="edit", value="?script", config=true},
        naming_base = {class="dropdown", value="Video", config=true},
        use_frames = {class="checkbox", value=true, config=true},
        use_aid = {class="checkbox", value=false, config=true},
        aid = {class="intedit", value=1, config=true},
        force_square_pixels = {class="checkbox", value=false, config=true}
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

local function message(text)
    aegisub.dialog.display({{class="label", label=text, x=0, y=0}}, {"OK"})
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
    return string.format("%d/1000", math.floor(100000 * 1000 * 1000 / (ms1 - ms0) + 0.5))
end

local function worker_path()
    if EncodeVS and EncodeVS.script_path then return EncodeVS.script_path end
    return aegisub.decode_path("?user/automation/include/baws/EncodeVS/encode_vs.py")
end

-- turns line times into frames the same way aegisub-motion does: first visible frame, exclusive end frame
local function make_range(start_ms, end_ms)
    local r = {start_ms = start_ms, end_ms = end_ms}
    local first = aegisub.frame_from_ms(start_ms)
    if first then
        r.first = math.max(0, first)
        r["end"] = aegisub.frame_from_ms(end_ms)
        r.aegi_first_ms = aegisub.ms_from_frame(r.first)
    end
    return r
end

local function run_job(cfg, job)
    local temp = strip_slash(aegisub.decode_path("?temp"))
    local job_path = string.format("%s%sbaws_encode_%d_%d.json", temp, pathsep, os.time(), math.random(1, 1000000))
    local cancel_path = job_path .. ".cancel"

    local script = worker_path()
    if not file_exists(script) then
        aegisub.log(0, "Can't find encode_vs.py at:\n%s\nReinstall baws.EncodeVS through DependencyControl.\n", script)
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
    local cmd = string.format('%s -u -B %s %s 2>&1', quote(py), quote(script), quote(job_path))
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
        aegisub.log(0, "The worker didn't run properly. Check the Python path in Edit Config (it needs vapoursynth installed).\n")
    elseif status == "FAILED" then
        aegisub.log(0, "Encode failed, see above.\n")
    end
end

local function do_encode(subs, sel, mode, opts, each_line)
    local cfg = get_config("main")
    local props = aegisub.project_properties()
    local vidfile = props.video_file or ""
    local audiofile = props.audio_file or ""

    if mode ~= "audio" and vidfile == "" then
        message("No video loaded.")
        return
    end
    if mode == "audio" and vidfile == "" and audiofile == "" then
        message("No audio or video loaded.")
        return
    end

    local container = "mkv"
    if mode == "video" then
        if opts.codec == "MP4 (H.264 + AAC)" then container = "mp4"
        elseif opts.codec == "WebM (VP9 + Opus)" then container = "webm" end
    end

    -- softsubs only fit in mkv, everything else gets burned in
    opts.subs = "none"
    if mode == "video" and opts.subs_on then
        opts.subs = (opts.hardsub or container ~= "mkv") and "hard" or "soft"
    end
    opts.subs_on = nil

    local script_dir = aegisub.decode_path("?script")
    local subfile = ""
    if opts.subs ~= "none" then
        if script_dir == "?script" or not aegisub.file_name() then
            message("Save the subtitle file first, subtitles are read from disk.")
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
    if opts.subs == "hard" then tags = tags .. "[Hardsub]" end
    if mode == "video" and not opts.audio and not is_dummy then tags = tags .. "[NoAudio]" end

    local ext
    if mode == "audio" then ext = AUDIO_EXT[opts.audio_codec] or "m4a"
    elseif mode == "video" then ext = container end

    local ranges = {}
    for _, sp in ipairs(spans) do
        local r = make_range(sp[1], sp[2])
        if mode ~= "audio" and not r.first then
            message("Aegisub has no timecodes loaded, can't work out frame numbers.")
            return
        end
        if mode ~= "audio" and r["end"] <= r.first then
            aegisub.log(2, "Skipping %d-%d ms, it doesn't cover a whole frame.\n", sp[1], sp[2])
        else
            local suffix
            if not cfg.use_frames or not r.first then
                suffix = string.format("[%.3f-%.3f]", r.start_ms / 1000, r.end_ms / 1000)
            else
                suffix = string.format("[%d-%d]", r.first, r["end"])
            end
            if mode == "images" then
                r.outdir = base_name .. tags .. suffix
            else
                r.outfile = string.format("%s%s%s.%s", base_name, tags, suffix, ext)
            end
            table.insert(ranges, r)
        end
    end
    if #ranges == 0 then return end

    run_job(cfg, {
        mode = mode,
        video = vidfile,
        video_dir = aegisub.decode_path("?video"),
        audio_file = (audiofile ~= vidfile) and audiofile or "",
        subfile = subfile,
        vscache = aegisub.decode_path("?local/vscache"),
        fallback_fps = estimate_fps() or "",
        settings = cfg,
        opts = opts,
        ranges = ranges
    })
end

local function show_config_dialog()
    local c = get_config("main")
    -- older configs might have an indexer name that doesn't exist anymore
    local known = false
    for _, x in ipairs(INDEXERS) do if x == c.indexer then known = true end end
    if not known then c.indexer = "Auto" end
    local exe_hint = "Leave blank to let muxtools find it (its managed binaries, then PATH)."
    local d = {
        { class='label', label='Python:', x=0, y=0 },
        { class='edit', name='python_exe', value=c.python_exe, x=1, y=0, width=3, hint=[[Python that has vapoursynth, vsjetpack and vsmuxtools installed.
Leave blank to use python from PATH.]] },
        { class='label', label='ffmpeg:', x=0, y=1 },
        { class='edit', name='ffmpeg_exe', value=c.ffmpeg_exe, x=1, y=1, width=3, hint=exe_hint .. "\nRequired. ffprobe is picked up from the same folder." },
        { class='label', label='mkvmerge:', x=0, y=2 },
        { class='edit', name='mkvmerge_exe', value=c.mkvmerge_exe, x=1, y=2, width=3, hint=exe_hint .. "\nNeeded for mkv output (muxing goes through muxtools)." },
        { class='label', label='x264:', x=0, y=3 },
        { class='edit', name='x264_exe', value=c.x264_exe, x=1, y=3, width=3, hint=exe_hint .. "\nOptional, ffmpeg's libx264 is used if it's missing." },
        { class='label', label='x265:', x=0, y=4 },
        { class='edit', name='x265_exe', value=c.x265_exe, x=1, y=4, width=3, hint=exe_hint .. "\nOptional, ffmpeg's libx265 is used if it's missing." },
        { class='label', label='SvtAv1EncApp:', x=0, y=5 },
        { class='edit', name='svtav1_exe', value=c.svtav1_exe, x=1, y=5, width=3, hint=exe_hint .. "\nOptional, ffmpeg's libsvtav1 is used if it's missing." },
        { class='label', label='opusenc:', x=0, y=6 },
        { class='edit', name='opusenc_exe', value=c.opusenc_exe, x=1, y=6, width=3, hint=exe_hint .. "\nOptional, ffmpeg's libopus is used if it's missing." },
        { class='label', label='flac:', x=0, y=7 },
        { class='edit', name='flac_exe', value=c.flac_exe, x=1, y=7, width=3, hint=exe_hint .. "\nOptional, ffmpeg is used if it's missing." },
        { class='label', label='qaac:', x=0, y=8 },
        { class='edit', name='qaac_exe', value=c.qaac_exe, x=1, y=8, width=3, hint=exe_hint .. "\nOptional, ffmpeg's AAC is used if it's missing." },

        { class='label', label='Video Indexer:', x=0, y=9 },
        { class='dropdown', name='indexer', items=INDEXERS, value=c.indexer, x=1, y=9, width=3, hint=[[Auto: reuse Aegisub's lwi index if there is one, otherwise make an ffindex.
LWI: reuse Aegisub's lwi index if there is one, otherwise make an lwi.
FFMS2 / BestSource: always use that indexer.
Indexes are kept in Aegisub's vscache folder.]] },
        { class='label', label='Output Path:', x=0, y=10 },
        { class='edit', name='output_path', value=c.output_path, x=1, y=10, width=3, hint='Use ?script for the subtitle folder' },
        { class='label', label='Base Filename:', x=0, y=11 },
        { class='dropdown', name='naming_base', items={"Video", "Subtitle"}, value=c.naming_base, x=1, y=11, width=3 },
        { class='checkbox', name='use_frames', label='Include frames in filename', value=c.use_frames, x=0, y=12, width=4, hint='Uses timestamps otherwise.' },
        { class='checkbox', name='use_aid', label='Force audio track:', value=c.use_aid, x=0, y=13, hint='Otherwise the first audio track is used.' },
        { class='intedit', name='aid', value=c.aid, x=1, y=13, min=1, hint='Counting audio tracks only, starting from 1.' },
        { class='checkbox', name='force_square_pixels', label='Force square pixels', value=c.force_square_pixels, x=0, y=14, width=4, hint='Resizes anamorphic sources to 1:1 SAR.' },
    }
    local btn, result = aegisub.dialog.display(d, {"Save", "Cancel"}, {ok="Save", cancel="Cancel"})
    if btn == "Save" then update_config("main", result) end
end

local function list_has(list, v)
    for _, x in ipairs(list) do if x == v then return true end end
    return false
end

-- shows a mode page, returns (button, values), loops back on bad input
local function mode_page(section, build, validate)
    local values = get_config(section)
    while true do
        local btn, result = aegisub.dialog.display(build(values), {"Encode", "Encode Each Line", "Cancel"}, {ok="Encode", cancel="Cancel"})
        if not btn or btn == "Cancel" then return nil end
        values = result
        local err = validate and validate(result)
        if err then
            message(err)
        else
            update_config(section, result)
            return btn, result
        end
    end
end

local function video_page(subs, sel)
    local build = function(v)
        if not list_has(VIDEO_CODECS, v.codec) then v.codec = VIDEO_CODECS[1] end
        return {
            { class='checkbox', name='audio', label='Include audio', value=v.audio, x=0, y=0, width=2 },
            { class='checkbox', name='subs', label='Include subtitles', value=v.subs, x=0, y=1, width=2, hint='Softsubs in mkv, burned in for mp4/webm' },
            { class='checkbox', name='hardsub', label='Hardsub subtitles', value=v.hardsub, x=0, y=2, width=2, hint='Burn subs in even when the format could take softsubs' },
            { class='label', label='Video codec:', x=0, y=3 },
            { class='dropdown', name='codec', items=VIDEO_CODECS, value=v.codec, x=1, y=3, hint='MP4 and WebM also decide the audio codec' },
            { class='label', label='CRF (-1 = default):', x=0, y=4 },
            { class='floatedit', name='crf', value=v.crf, x=1, y=4, hint='Sets cq for NVENC' },
            { class='label', label='2-pass filesize (KB):', x=0, y=5 },
            { class='intedit', name='target_kb', value=v.target_kb, x=1, y=5, min=0, hint='0 = off. Anything above 0 encodes to that size instead of using CRF.' },
            { class='label', label='Height (0 = source):', x=0, y=6 },
            { class='intedit', name='height', value=v.height, x=1, y=6, min=0 },
            { class='label', label='Bit depth:', x=0, y=7 },
            { class='dropdown', name='bitdepth', items={"Source", "8", "10", "12"}, value=v.bitdepth, x=1, y=7 },
            { class='label', label='Assert FPS:', x=0, y=8 },
            { class='edit', name='fps', value=v.fps, x=1, y=8, hint='A fraction like 24000/1001. Empty = source fps. Relabels the rate, frames are never dropped or duplicated.' },
            { class='label', label='Audio codec:', x=0, y=9 },
            { class='dropdown', name='audio_codec', items=AUDIO_CODECS, value=v.audio_codec, x=1, y=9, hint='Ignored for MP4 (AAC) and WebM (Opus)' },
            { class='label', label='Audio bitrate (kbps):', x=0, y=10 },
            { class='intedit', name='audio_bitrate', value=v.audio_bitrate, x=1, y=10, min=8, hint='Ignored for FLAC' },
        }
    end
    local validate = function(v)
        local fps = v.fps:gsub("^%s+", ""):gsub("%s+$", "")
        if fps ~= "" and not fps:match("^%d+/%d+$") then
            return "Assert FPS has to be a fraction like 24000/1001, or empty for source fps."
        end
        v.fps = fps
    end
    local btn, v = mode_page("video", build, validate)
    if not btn then return end
    local opts = {
        audio = v.audio, subs_on = v.subs, hardsub = v.hardsub, codec = v.codec, crf = v.crf,
        target_kb = v.target_kb, height = v.height, bitdepth = v.bitdepth, fps = v.fps,
        audio_codec = v.audio_codec, audio_bitrate = v.audio_bitrate
    }
    do_encode(subs, sel, "video", opts, btn == "Encode Each Line")
end

local function audio_page(subs, sel)
    local build = function(v)
        return {
            { class='label', label='Audio codec:', x=0, y=0 },
            { class='dropdown', name='audio_codec', items=AUDIO_CODECS, value=v.audio_codec, x=1, y=0 },
            { class='label', label='Bitrate (kbps):', x=0, y=1 },
            { class='intedit', name='audio_bitrate', value=v.audio_bitrate, x=1, y=1, min=8, hint='Ignored for FLAC' },
        }
    end
    local btn, v = mode_page("audio", build)
    if not btn then return end
    do_encode(subs, sel, "audio", {audio_codec = v.audio_codec, audio_bitrate = v.audio_bitrate}, btn == "Encode Each Line")
end

local function images_page(subs, sel)
    local build = function(v)
        return {
            { class='label', label='Image format:', x=0, y=0 },
            { class='dropdown', name='image_format', items={"png", "jpg"}, value=v.image_format, x=1, y=0 },
            { class='label', label='Quality:', x=0, y=1 },
            { class='intedit', name='quality', value=v.quality, x=1, y=1, min=1, max=100, hint='1-100, jpg only' },
        }
    end
    local btn, v = mode_page("images", build)
    if not btn then return end
    do_encode(subs, sel, "images", {image_format = v.image_format, quality = v.quality}, btn == "Encode Each Line")
end

local function show_dialog(subs, sel)
    while true do
        local btn = aegisub.dialog.display(
            {{class="label", label="Choose a mode", x=0, y=0}},
            {"Video", "Image Sequence", "Audio", "Edit Config", "Cancel"},
            {cancel="Cancel"})
        if btn == "Video" then return video_page(subs, sel)
        elseif btn == "Image Sequence" then return images_page(subs, sel)
        elseif btn == "Audio" then return audio_page(subs, sel)
        elseif btn == "Edit Config" then show_config_dialog()
        else return end
    end
end

if haveDepCtrl then
    depctrl:registerMacro(show_dialog)
else
    aegisub.register_macro(script_name, script_description, show_dialog)
end
