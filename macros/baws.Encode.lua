-- Copyright (c) 2026, McBaws
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
script_version = '2.0.2'

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
        sub_mode = {class="dropdown", value="Softsub", config=true},
        codec = {class="dropdown", value="x264 (AVC)", config=true},
        crf = {class="floatedit", value=-1, config=true},
        target_kb = {class="intedit", value=0, config=true},
        height = {class="intedit", value=0, config=true},
        bitdepth = {class="dropdown", value="Source", config=true},
        fps = {class="edit", value="", config=true},
        audio_codec = {class="dropdown", value="Opus", config=true},
        audio_bitrate = {class="intedit", value=192, config=true},
        use_aid = {class="checkbox", value=false, config=true},
        aid = {class="intedit", value=1, config=true},
        square = {class="checkbox", value=false, config=true}
    },
    audio = {
        audio_codec = {class="dropdown", value="Opus", config=true},
        audio_bitrate = {class="intedit", value=192, config=true},
        use_aid = {class="checkbox", value=false, config=true},
        aid = {class="intedit", value=1, config=true}
    },
    images = {
        image_format = {class="dropdown", value="jpg", config=true},
        quality = {class="intedit", value=95, config=true}
    },
    main = {
        python_exe = {class="edit", value="", config=true},
        ffmpeg_exe = {class="edit", value="", config=true},
        indexer = {class="dropdown", value="Auto", config=true},
        output_path = {class="edit", value="?script", config=true},
        filename = {class="edit", value="$video$ [$sframe$-$eframe$]", config=true},
        keep_track_names = {class="checkbox", value=true, config=true},
        name_subs_after_script = {class="checkbox", value=false, config=true}
    }
}

local DEFAULTS = {}
for section, entries in pairs(config_schema) do
    DEFAULTS[section] = {}
    for k, v in pairs(entries) do DEFAULTS[section][k] = v.value end
end

local function defaults(section)
    local c = {}
    for k, v in pairs(DEFAULTS[section]) do c[k] = v end
    return c
end

if haveDepCtrl then
    config = ConfigHandler(config_schema, depctrl.configFile, false, script_version, depctrl.configDir)
end

local function get_config(section)
    if haveDepCtrl then
        config:read()
        config:updateInterface()
    end
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
    if haveDepCtrl then
        config:updateConfiguration(new_values, section)
        config:write()
    end
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
    -- aegisub doesn't always close the progress dialog on its own, so at least make it obvious we're done
    aegisub.progress.set(100)
    aegisub.progress.task(status == "OK" and "Finished" or status == "CANCELLED" and "Cancelled" or "Finished (with errors)")
end

-- ---- filename templates ----

local NAME_TOKENS = {
    {"$video$", "video file name"},
    {"$script$", "subtitle file name"},
    {"$sframe$", "first frame"},
    {"$eframe$", "last frame (inclusive)"},
    {"$stime$", "start time, like 0.04.17.170"},
    {"$etime$", "end time"},
}

local function time_token(ms)
    if not ms then return "" end
    local h = math.floor(ms / 3600000)
    local m = math.floor(ms / 60000) % 60
    local sec = math.floor(ms / 1000) % 60
    return string.format("%d.%02d.%02d.%03d", h, m, sec, ms % 1000)
end

local function sanitize(name)
    -- empty tokens leave double spaces behind, so squash those too
    name = name:gsub('[<>:"/\\|%?%*%c]', "_"):gsub("%s%s+", " "):gsub("^%s+", ""):gsub("[%s%.]+$", "")
    return name
end

local function make_name(template, rng)
    local vidfile = aegisub.project_properties().video_file or ""
    local video = vidfile:sub(1, 7) == "?dummy:" and "dummy" or get_filename(vidfile)
    local script = get_filename(aegisub.file_name())
    local values = {
        video = video ~= "" and video or "video",
        script = script ~= "" and script or "untitled",
        sframe = rng.first and tostring(rng.first) or "",
        eframe = rng["end"] and tostring(rng["end"] - 1) or "",
        stime = time_token(rng.start_ms),
        etime = time_token(rng.end_ms),
    }
    local name = template:gsub("%$(%w+)%$", function(k)
        local v = values[k:lower()]
        if v == nil then return "$" .. k .. "$" end
        return v
    end)
    name = sanitize(name)
    return name ~= "" and name or "clip"
end

local function token_help()
    local help = {"Tokens (the extension is added for you):"}
    for _, t in ipairs(NAME_TOKENS) do table.insert(help, t[1] .. "  " .. t[2]) end
    return table.concat(help, "\n")
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

    local used = {}
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
            local name = make_name(cfg.filename, r)
            -- two lines giving the same name shouldn't overwrite each other
            local base, n = name, 2
            while used[name:lower()] do
                name = string.format("%s (%d)", base, n)
                n = n + 1
            end
            used[name:lower()] = true
            if mode == "images" then
                r.outdir = out_dir .. pathsep .. name
            else
                r.outfile = string.format("%s%s%s.%s", out_dir, pathsep, name, ext)
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

local function preview_name(subs, sel, template)
    if not sel or #sel == 0 then return "(select a line to see a preview)" end
    local line = subs[sel[1]]
    return make_name(template, make_range(line.start_time, line.end_time))
end

-- aegisub's grid collapses empty rows, so a label with a space is what gives a visible gap
local function spacer(y)
    return { class='label', label=' ', x=0, y=y }
end

local function show_config_dialog(subs, sel, pending)
    local c = pending or get_config("main")
    -- older configs might have an indexer name that doesn't exist anymore
    local known = false
    for _, x in ipairs(INDEXERS) do if x == c.indexer then known = true end end
    if not known then c.indexer = "Auto" end
    local d = {
        { class='label', label='Video Indexer:', x=0, y=0 },
        { class='dropdown', name='indexer', items=INDEXERS, value=c.indexer, x=1, y=0, width=3, hint=[[Auto: reuse Aegisub's lwi index if there is one, otherwise make an ffindex.
LWI: reuse Aegisub's lwi index if there is one, otherwise make an lwi.
FFMS2 / BestSource: always use that indexer.
Indexes are kept in Aegisub's vscache folder.]] },
        { class='label', label='Output Path:', x=0, y=1 },
        { class='edit', name='output_path', value=c.output_path, x=1, y=1, width=3, hint='Use ?script for the subtitle folder' },
        { class='label', label='Filename:', x=0, y=2 },
        { class='edit', name='filename', value=c.filename, x=1, y=2, width=3, hint=token_help() },
        { class='label', label='Preview:', x=0, y=3 },
        { class='label', label=preview_name(subs, sel, c.filename), x=1, y=3, width=3 },
        { class='checkbox', name='keep_track_names', label='Copy track names from the source', value=c.keep_track_names, x=0, y=4, width=4, hint='Gives the video and audio tracks the same names as in the source file.\nLanguages are always copied.' },
        { class='checkbox', name='name_subs_after_script', label='Name the softsub track after the script', value=c.name_subs_after_script, x=0, y=5, width=4, hint='Uses the subtitle file name (without extension). Otherwise the track is left unnamed.' },
        spacer(6),
        { class='label', label='Python:', x=0, y=7 },
        { class='edit', name='python_exe', value=c.python_exe, x=1, y=7, width=3, hint=[[Python that has vapoursynth, vsjetpack and vsmuxtools installed.
Leave blank to use python from PATH.]] },
        { class='label', label='ffmpeg:', x=0, y=8 },
        { class='edit', name='ffmpeg_exe', value=c.ffmpeg_exe, x=1, y=8, width=3, hint=[[Leave blank to use ffmpeg from PATH. ffprobe is picked up from the same folder.
Everything else (mkvmerge, x264, x265, SvtAv1EncApp, opusenc, flac, qaac) is looked up on PATH.]] },
    }
    local btn, result = aegisub.dialog.display(d, {"Save", "Preview Filename", "Reset Defaults", "Cancel"}, {ok="Save", cancel="Cancel"})
    if btn == "Save" then
        update_config("main", result)
    elseif btn == "Reset Defaults" then
        -- only fills the dialog in, nothing is saved until Save
        return show_config_dialog(subs, sel, defaults("main"))
    elseif btn == "Preview Filename" then
        -- reopen with what they typed so the preview label updates
        return show_config_dialog(subs, sel, result)
    end
end

local function list_has(list, v)
    for _, x in ipairs(list) do if x == v then return true end end
    return false
end

-- shows a mode page, returns (button, values), loops back on bad input
local function mode_page(section, build, validate)
    local values = get_config(section)
    while true do
        local btn, result = aegisub.dialog.display(build(values), {"Encode", "Encode Each Line", "Reset Defaults", "Cancel"}, {ok="Encode", cancel="Cancel"})
        if not btn or btn == "Cancel" then return nil end
        values = result
        if btn == "Reset Defaults" then
            -- only fills the dialog in, it gets saved once you encode
            values = defaults(section)
            goto continue
        end
        local err = validate and validate(result)
        if err then
            message(err)
        else
            update_config(section, result)
            return btn, result
        end
        ::continue::
    end
end

local function audio_rows(v, y)
    return {
        { class='checkbox', name='use_aid', label='Force audio track:', value=v.use_aid, x=0, y=y, hint='Otherwise the first audio track is used.' },
        { class='intedit', name='aid', value=v.aid, x=1, y=y, min=1, hint='Counting audio tracks only, starting from 1.' },
        { class='label', label='Audio codec:', x=0, y=y + 1 },
        { class='dropdown', name='audio_codec', items=AUDIO_CODECS, value=v.audio_codec, x=1, y=y + 1 },
        { class='label', label='Audio bitrate (kbps):', x=0, y=y + 2 },
        { class='intedit', name='audio_bitrate', value=v.audio_bitrate, x=1, y=y + 2, min=8, hint='Ignored for FLAC' },
    }
end

local function video_opts(v)
    return {
        audio = v.audio, subs_on = v.subs, hardsub = v.sub_mode == "Hardsub", codec = v.codec, crf = v.crf,
        target_kb = v.target_kb, height = v.height, bitdepth = v.bitdepth, fps = v.fps,
        audio_codec = v.audio_codec, audio_bitrate = v.audio_bitrate,
        use_aid = v.use_aid, aid = v.aid, square = v.square
    }
end

local function audio_opts(v)
    return {audio_codec = v.audio_codec, audio_bitrate = v.audio_bitrate, use_aid = v.use_aid, aid = v.aid}
end

local function images_opts(v)
    return {image_format = v.image_format, quality = v.quality}
end

local function video_page(subs, sel)
    local build = function(v)
        if not list_has(VIDEO_CODECS, v.codec) then v.codec = VIDEO_CODECS[1] end
        if v.sub_mode ~= "Hardsub" then v.sub_mode = "Softsub" end
        local d = {
            { class='checkbox', name='audio', label='Include audio', value=v.audio, x=0, y=0, width=2 },
            { class='checkbox', name='subs', label='Include subtitles', value=v.subs, x=0, y=1, width=2 },
            spacer(2),
            { class='label', label='Video codec:', x=0, y=3 },
            { class='dropdown', name='codec', items=VIDEO_CODECS, value=v.codec, x=1, y=3, hint='MP4 and WebM also decide the audio codec' },
            { class='label', label='CRF (-1 = default):', x=0, y=4 },
            { class='floatedit', name='crf', value=v.crf, x=1, y=4, hint='Sets cq for NVENC' },
            { class='label', label='2-pass filesize (KB):', x=0, y=5 },
            { class='intedit', name='target_kb', value=v.target_kb, x=1, y=5, min=0, hint='0 = off. Anything above 0 encodes to that size instead of using CRF.' },
            { class='label', label='Bit depth:', x=0, y=6 },
            { class='dropdown', name='bitdepth', items={"Source", "8", "10", "12"}, value=v.bitdepth, x=1, y=6 },
            { class='label', label='Assert FPS:', x=0, y=7 },
            { class='edit', name='fps', value=v.fps, x=1, y=7, hint='A fraction like 24000/1001. Empty = source fps. Relabels the rate, frames are never dropped or duplicated.' },
            { class='label', label='Height (0 = source):', x=0, y=8 },
            { class='intedit', name='height', value=v.height, x=1, y=8, min=0 },
            { class='checkbox', name='square', label='Force square pixels', value=v.square, x=0, y=9, width=2, hint='Resizes anamorphic sources to 1:1 SAR.' },
            spacer(10),
        }
        for _, e in ipairs(audio_rows(v, 11)) do table.insert(d, e) end
        d[#d - 2].hint = 'Ignored for MP4 (AAC) and WebM (Opus)'
        table.insert(d, spacer(14))
        table.insert(d, { class='label', label='Subtitles:', x=0, y=15 })
        table.insert(d, { class='dropdown', name='sub_mode', items={"Softsub", "Hardsub"}, value=v.sub_mode, x=1, y=15, hint='Only used when "Include subtitles" is ticked. MP4 and WebM can only hardsub.' })
        return d
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
    do_encode(subs, sel, "video", video_opts(v), btn == "Encode Each Line")
end

local function audio_page(subs, sel)
    local build = function(v)
        return audio_rows(v, 0)
    end
    local btn, v = mode_page("audio", build)
    if not btn then return end
    do_encode(subs, sel, "audio", audio_opts(v), btn == "Encode Each Line")
end

local function images_page(subs, sel)
    local build = function(v)
        return {
            { class='label', label='Image format:', x=0, y=0 },
            { class='dropdown', name='image_format', items={"jpg", "png"}, value=v.image_format, x=1, y=0 },
            { class='label', label='Quality:', x=0, y=1 },
            { class='intedit', name='quality', value=v.quality, x=1, y=1, min=1, max=100, hint='1-100, jpg only' },
        }
    end
    local btn, v = mode_page("images", build)
    if not btn then return end
    do_encode(subs, sel, "images", images_opts(v), btn == "Encode Each Line")
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
        elseif btn == "Edit Config" then show_config_dialog(subs, sel)
        else return end
    end
end

-- skips the dialogs and reuses whatever that page was last encoded with
local function shortcut(mode, to_opts, each_line)
    return function(subs, sel)
        do_encode(subs, sel, mode, to_opts(get_config(mode)), each_line)
    end
end

local macros = {
    {"Encode", script_description, show_dialog},
    {"Repeat Last/All Lines/Video", "Encode video of the whole selection with the last used settings, no dialog", shortcut("video", video_opts, false)},
    {"Repeat Last/All Lines/Audio", "Encode audio of the whole selection with the last used settings, no dialog", shortcut("audio", audio_opts, false)},
    {"Repeat Last/All Lines/Images", "Export images of the whole selection with the last used settings, no dialog", shortcut("images", images_opts, false)},
    {"Repeat Last/Each Line/Video", "Encode video of each selected line with the last used settings, no dialog", shortcut("video", video_opts, true)},
    {"Repeat Last/Each Line/Audio", "Encode audio of each selected line with the last used settings, no dialog", shortcut("audio", audio_opts, true)},
    {"Repeat Last/Each Line/Images", "Export images of each selected line with the last used settings, no dialog", shortcut("images", images_opts, true)},
}

if haveDepCtrl then
    depctrl:registerMacros(macros)
else
    for _, m in ipairs(macros) do
        aegisub.register_macro(script_name .. "/" .. m[1], m[2], m[3])
    end
end
