import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import traceback
from fractions import Fraction

# called by baws_Encode.lua as: python -u encode_vs.py <job.json>
# lines starting with @@ are read by the lua side, everything else goes to the log

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass


class Cancelled(Exception):
    pass


class JobError(Exception):
    pass


class Reporter:
    def __init__(self, cancel_path):
        self.cancel_path = cancel_path
        self.total = 1
        self.done = 0
        self.last_pct = -1.0
        self.ticks = 0

    def task(self, msg):
        print(f"@@TASK {msg}", flush=True)

    def log(self, msg):
        for line in str(msg).splitlines():
            print(line, flush=True)

    def warn(self, msg):
        self.log(f"WARNING: {msg}")

    def check_cancel(self):
        if self.cancel_path and os.path.exists(self.cancel_path):
            raise Cancelled()

    def advance(self, n=1):
        self.done += n
        pct = min(100.0, int(1000 * self.done / max(self.total, 1)) / 10)
        if pct != self.last_pct:
            self.last_pct = pct
            print(f"@@PROGRESS {pct}", flush=True)
        self.ticks += 1
        if self.ticks % 8 == 0:
            self.check_cancel()

    def frame_cb(self):
        # vs's progress_update gives absolute counts, turn them into increments
        last = [0]

        def cb(current, total):
            if current > last[0]:
                self.advance(current - last[0])
                last[0] = current

        return cb


try:
    import vapoursynth as vs
    core = vs.core
except Exception as e:
    print(f"ERROR: couldn't import vapoursynth with {sys.executable}: {e}", flush=True)
    print("Set the Python path in the Encode config to the python that has vapoursynth/vsjetpack installed.", flush=True)
    sys.exit(2)

try:
    import vstools
except Exception:
    vstools = None


# ---- aegisub compat stuff ----

def lwi_cache_name(filename):
    # same as make_lwi_cache_filename in aegisub's aegisub_vs.py, has to match exactly
    max_len = 254
    ext = ".lwi"
    if len(filename) + len(ext) > max_len:
        filename = filename[-(max_len + len(ext)):]
    return "".join("_" if c in "/\\:" else c for c in filename) + ext


def read_aegisub_config(user_dir):
    try:
        with open(os.path.join(user_dir, "config.json"), encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def cfg_get(d, *keys, default=None):
    for k in keys:
        if not isinstance(d, dict) or k not in d:
            return default
        d = d[k]
    return d


def ensure_plugin(ns, dll_name, data_dir):
    if hasattr(core, ns):
        return True
    # aegisub's installer ships some plugins in ?data/vapoursynth, same fallback aegisub uses
    if data_dir and dll_name:
        ext = ".dll" if os.name == "nt" else ".so"
        path = os.path.join(data_dir, "vapoursynth", dll_name + ext)
        if os.path.exists(path):
            try:
                core.std.LoadPlugin(path)
            except vs.Error:
                pass
    return hasattr(core, ns)


def video_name_candidates(job):
    # aegisub hands the vs provider the path as it was opened, but project_properties() gives
    # a path that went through MakeRelative/MakeAbsolute and can contain "..", so try a few
    cands = []
    video = job["video"]
    vdir = (job.get("video_dir") or "").rstrip("/\\")
    if vdir:
        cands.append(os.path.join(vdir, os.path.basename(video.replace("\\", "/"))))
    cands.append(video)
    cands.append(os.path.normpath(video))
    out = []
    for c in cands:
        if c not in out:
            out.append(c)
    return out


def pick_indexer(job, aegi_cfg, rep):
    choice = job["indexer"]
    if choice != "Auto":
        return choice
    provider = cfg_get(aegi_cfg, "Video", "Provider", default="FFmpegSource")
    if provider == "BestSource":
        return "BestSource"
    if provider == "FFmpegSource":
        return "FFMS2"
    if provider == "VapourSynth":
        script = cfg_get(aegi_cfg, "Provider", "Video", "VapourSynth", "Default Script", default="") or ""
        if "wrap_lwlibavsource" in script or "LWLibavSource" in script or not script:
            return "LSMASH"
        if "bs.VideoSource" in script:
            return "BestSource"
        if "ffms2" in script:
            return "FFMS2"
        rep.warn("Your VapourSynth default script in Aegisub is customised, guessing LSMASH. Set the indexer manually if frames don't line up.")
        return "LSMASH"
    return "LSMASH"


def parse_dummy(spec):
    # ?dummy:<fps>:<frames>:<w>:<h>:<r>:<g>:<b>:<checkerboard>
    parts = spec.split(":")
    fps = Fraction(parts[1].replace("\\", "/"))
    length, w, h = int(parts[2]), int(parts[3]), int(parts[4])
    r, g, b = int(parts[5]), int(parts[6]), int(parts[7])
    clip = core.std.BlankClip(width=w, height=h, format=vs.RGB24, length=length,
                              fpsnum=fps.numerator, fpsden=fps.denominator, color=[r, g, b])
    return clip.resize.Bicubic(format=vs.YUV420P8, matrix_s="709")


def load_vpy(path):
    import runpy
    vs.clear_outputs()
    old_cwd, old_argv = os.getcwd(), sys.argv
    try:
        os.chdir(os.path.dirname(os.path.abspath(path)))
        sys.argv = [path]
        runpy.run_path(path, run_name="__vapoursynth__")
    finally:
        os.chdir(old_cwd)
        sys.argv = old_argv
    out = vs.get_output(0)
    return out.clip if hasattr(out, "clip") else out


def load_video(job, aegi_cfg, rep):
    video = job["video"]
    if video.startswith("?dummy"):
        return parse_dummy(video), "dummy"
    if video.lower().endswith((".vpy", ".py")):
        rep.task("Running the .vpy")
        return load_vpy(video), "vpy"

    data_dir = job.get("data_dir")
    vscache = job["vscache"]
    os.makedirs(vscache, exist_ok=True)
    indexer = pick_indexer(job, aegi_cfg, rep)

    order = [indexer] + [i for i in ("LSMASH", "BestSource", "FFMS2") if i != indexer]
    for idx in order:
        if idx == "LSMASH" and ensure_plugin("lsmas", "libvslsmashsource", data_dir):
            names = video_name_candidates(job)
            cachefile = None
            for n in names:
                p = os.path.join(vscache, lwi_cache_name(n))
                if os.path.exists(p):
                    cachefile = p
                    break
            if cachefile:
                rep.log(f"Reusing Aegisub's lwi index: {cachefile}")
            else:
                cachefile = os.path.join(vscache, lwi_cache_name(names[0]))
                rep.task("Indexing with LSMASH (one-off, Aegisub's VS provider can reuse it after)")
            try:
                clip = core.lsmas.LWLibavSource(source=video, cachefile=cachefile)
            except vs.Error as e:
                if "cachefile" not in str(e):
                    raise
                rep.warn("Your lsmas is too old for cachefile=, indexing next to the video instead")
                clip = core.lsmas.LWLibavSource(source=video)
            return clip, "LSMASH"

        if idx == "BestSource" and ensure_plugin("bs", "BestSource", data_dir):
            rff = bool(cfg_get(aegi_cfg, "Provider", "Video", "BestSource", "Apply RFF", default=True))
            rep.task("Opening with BestSource (first run on a file indexes it)")
            return core.bs.VideoSource(source=video, cachepath=vscache, rff=rff), "BestSource"

        if idx == "FFMS2" and ensure_plugin("ffms2", "ffms2", data_dir):
            cachefile = os.path.join(vscache, lwi_cache_name(video_name_candidates(job)[0])[:-4] + ".ffindex")
            rep.task("Opening with FFMS2 (first run on a file indexes it)")
            return core.ffms2.Source(source=video, cachefile=cachefile), "FFMS2"

        if idx == indexer:
            rep.warn(f"{idx} plugin not found, trying the next indexer")

    raise JobError("No source plugin found (need lsmas, bs or ffms2). Install one with vsrepo / vsjet.")


def load_audio(job, rep):
    src = job.get("audio_file") or job["video"]
    if src.startswith("?dummy") or src.startswith("dummy-audio"):
        return None
    if not ensure_plugin("bs", "BestSource", job.get("data_dir")):
        rep.warn("bs plugin not found, skipping audio")
        return None
    # same args as aegisub's vs audio provider so the bsindex cache gets shared with it
    track = -int(job["settings"]["aid"]) if job["settings"]["use_aid"] else -1
    rep.task("Loading audio (first run on a file indexes it)")
    try:
        return core.bs.AudioSource(source=src, track=track)
    except vs.Error as e:
        rep.warn(f"Couldn't open audio, continuing without it: {e}")
        return None


# ---- timing ----

def parse_fps(s):
    s = str(s).strip()
    common = [Fraction(24000, 1001), Fraction(30000, 1001), Fraction(48000, 1001),
              Fraction(60000, 1001), Fraction(120000, 1001)]
    f = Fraction(s.replace("\\", "/"))
    for c in common:
        if abs(float(f) - float(c)) < 0.0015:
            return c
    return f.limit_denominator(100000)


def frame_time(clip, n, rep):
    # exact time of frame n relative to frame 0, in seconds
    if clip.fps.numerator > 0:
        return Fraction(n * clip.fps.denominator, clip.fps.numerator)
    try:
        t0 = clip.get_frame(0).props["_AbsoluteTime"]
        if n < clip.num_frames:
            return Fraction(clip.get_frame(n).props["_AbsoluteTime"] - t0).limit_denominator(10**9)
        last = clip.get_frame(clip.num_frames - 1).props
        dur = Fraction(last["_DurationNum"], last["_DurationDen"])
        return Fraction(last["_AbsoluteTime"] - t0).limit_denominator(10**9) + dur
    except (KeyError, vs.Error):
        raise JobError("VFR clip without timestamps in frame props, can't cut audio exactly")


def check_alignment(clip, rng, rep):
    # recompute aegisub's START time for this frame from the clip and compare with what aegisub said
    first = rng["first"]
    ms = rng.get("aegi_first_ms")
    if ms is None or first < 1 or first >= clip.num_frames:
        return
    try:
        prev = int(frame_time(clip, first - 1, rep) * 1000)
        cur = int(frame_time(clip, first, rep) * 1000)
    except JobError:
        return
    expected = prev + (cur - prev + 1) // 2
    if abs(expected - ms) > 2:
        off = round((ms - expected) / max(cur - prev, 1))
        rep.warn(f"Frame {first} is at {expected} ms here but {ms} ms in Aegisub (~{off} frame(s) off).")
        rep.warn("The indexer isn't numbering frames like Aegisub's video provider. Try a different indexer in the config.")


# ---- filtering ----

def init_props(clip, rep):
    if vstools is None:
        rep.warn("vstools not importable, colour props won't be guessed")
        return clip
    try:
        return vstools.initialize_clip(clip, bits=None)
    except Exception as e:
        rep.warn(f"initialize_clip failed ({e}), continuing with the props as they are")
        return clip


def add_subs(clip, subfile, rep):
    if hasattr(core, "sub"):
        return core.sub.TextFile(clip, file=subfile)
    if hasattr(core, "assrender"):
        return core.assrender.TextSub(clip, file=subfile)
    raise JobError("Hardsubbing needs the subtext (sub) or assrender plugin.")


def get_sar(clip):
    props = clip.get_frame(0).props
    num, den = props.get("_SARNum", 1), props.get("_SARDen", 1)
    if not num or not den:
        return Fraction(1)
    return Fraction(num, den)


def even(x):
    return max(2, int(round(x / 2)) * 2)


def scale(clip, s, square):
    w, h = clip.width, clip.height
    sar = get_sar(clip)
    if square and sar != 1:
        w = even(w * sar)
        sar = Fraction(1)
    if s["target_height"] > 0 and s["target_height"] != h:
        w = even(w * s["target_height"] / h)
        h = s["target_height"]
    if (w, h) != (clip.width, clip.height):
        clip = core.resize.Spline36(clip, w, h)
    if square:
        clip = clip.std.SetFrameProps(_SARNum=1, _SARDen=1)
    return clip


ENC_MAX_BITS = {"libx264": 10, "h264_nvenc": 8, "libx265": 12, "libsvtav1": 10}


def to_encode_format(clip, enc, s, tracking, rep):
    f = clip.format
    if tracking:
        bits = 8
    elif s["force_source_bitdepth"]:
        bits = f.bits_per_sample if f.sample_type == vs.INTEGER else 10
    else:
        bits = int(s["custom_bitdepth"])
    cap = ENC_MAX_BITS.get(enc, 10)
    if bits > cap:
        rep.warn(f"{enc} can't do {bits}-bit, using {cap}-bit")
        bits = cap
    bits = 8 if bits <= 8 else bits

    if f.color_family == vs.YUV and not tracking:
        ssw, ssh = f.subsampling_w, f.subsampling_h
    else:
        ssw, ssh = 1, 1
    target = core.query_video_format(vs.YUV, vs.INTEGER, bits, ssw, ssh)
    if target.id == f.id:
        return clip

    if f.color_family == vs.YUV and (f.subsampling_w, f.subsampling_h) == (ssw, ssh) and vstools:
        return vstools.depth(clip, bits)
    kw = {"dither_type": "error_diffusion"}
    if f.color_family == vs.RGB:
        kw["matrix_s"] = "709"
    return core.resize.Bicubic(clip, format=target.id, **kw)


def to_rgb24(clip):
    if clip.format.id == vs.RGB24:
        return clip
    kw = {"dither_type": "error_diffusion"}
    if clip.format.color_family == vs.YUV:
        m = clip.get_frame(0).props.get("_Matrix", 2)
        if m in (2, 3):
            kw["matrix_in_s"] = "709"
    return core.resize.Bicubic(clip, format=vs.RGB24, **kw)


# ---- ffmpeg ----

MATRIX = {1: "bt709", 5: "bt470bg", 6: "smpte170m", 7: "smpte240m", 9: "bt2020nc", 10: "bt2020c"}
TRANSFER = {1: "bt709", 4: "bt470m", 5: "bt470bg", 6: "smpte170m", 7: "smpte240m", 8: "linear",
            13: "iec61966-2-1", 14: "bt2020-10", 15: "bt2020-12", 16: "smpte2084", 18: "arib-std-b67"}
PRIMARIES = {1: "bt709", 4: "bt470m", 5: "bt470bg", 6: "smpte170m", 7: "smpte240m", 9: "bt2020", 12: "smpte432"}


def colour_args(clip):
    # y4m doesn't carry colour info, so pass it to the encoder ourselves
    p = clip.get_frame(0).props
    args = []
    if p.get("_Matrix") in MATRIX:
        args += ["-colorspace", MATRIX[p["_Matrix"]]]
    if p.get("_Transfer") in TRANSFER:
        args += ["-color_trc", TRANSFER[p["_Transfer"]]]
    if p.get("_Primaries") in PRIMARIES:
        args += ["-color_primaries", PRIMARIES[p["_Primaries"]]]
    # vs R80 renamed _ColorRange to _Range and flipped the numbers, so compare against vs's own constants
    rng = p.get("_Range") if "_Range" in p else p.get("_ColorRange")
    if rng is not None and rng == vs.RANGE_LIMITED:
        args += ["-color_range", "tv"]
    elif rng is not None and rng == vs.RANGE_FULL:
        args += ["-color_range", "pc"]
    sar = get_sar(clip)
    if sar != 1:
        args += ["-vf", f"setsar={sar.numerator}/{sar.denominator}"]
    return args


def find_exe(path, name):
    exe = path or name
    found = shutil.which(exe)
    if not found:
        raise JobError(f"Couldn't find {name} ('{exe}'). Set its path in the Encode config.")
    return found


def ffmpeg_encoders(ffmpeg):
    out = subprocess.run([ffmpeg, "-hide_banner", "-encoders"], capture_output=True,
                         text=True, errors="replace").stdout
    encs = set()
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 2 and len(parts[0]) == 6 and parts[0][0] in "VAS":
            encs.add(parts[1])
    return encs


def pick_aac(s, encs):
    if s["audio_encoder"]:
        return s["audio_encoder"]
    prio = {"aac": 0, "libfdk_aac": 1, "aac_mf": 2, "aac_at": 3}
    best = "aac"
    for e in prio:
        if e in encs and prio[e] > prio[best]:
            best = e
    return best


def custom_args(text, rep):
    text = (text or "").replace("\n", " ").strip()
    if not text:
        return []
    args = shlex.split(text, posix=os.name != "nt")
    if any(a.startswith("--") for a in args):
        rep.warn(f"Ignoring custom options '{text}', they look like old mpv options. These are ffmpeg output options now.")
        return []
    return args


def run_ffmpeg(cmd, cwd, clip, rep, logpath):
    with open(logpath, "wb") as log:
        proc = subprocess.Popen(cmd, cwd=cwd, stdin=subprocess.PIPE if clip is not None else subprocess.DEVNULL,
                                stdout=subprocess.DEVNULL, stderr=log)
        try:
            if clip is not None:
                try:
                    clip.output(proc.stdin, y4m=True, progress_update=rep.frame_cb())
                except BrokenPipeError:
                    pass
                finally:
                    proc.stdin.close()
            rc = proc.wait()
        except BaseException:
            proc.kill()
            proc.wait()
            raise
    if rc != 0:
        with open(logpath, encoding="utf-8", errors="replace") as f:
            tail = f.read()[-3000:]
        raise JobError(f"ffmpeg failed (exit {rc}):\n{tail}")


def write_wav(anode, path, t0, t1):
    s0 = max(0, int(round(t0 * anode.sample_rate)))
    s1 = min(anode.num_samples, int(round(t1 * anode.sample_rate)))
    if s1 <= s0:
        return False
    with open(path, "wb") as f:
        anode[s0:s1].output(f, wav=True)
    return True


def video_codec_args(enc, s, tracking, duration, has_audio, rep):
    if tracking:
        return ["-c:v", "libx264", "-profile:v", "baseline", "-crf", "18", "-preset", "fast"]
    args = ["-c:v", enc]
    if s["target_filesize"] > 0:
        target_kbit = s["target_filesize"] * 8
        if has_audio:
            target_kbit -= duration * (64 if s["strict_filesize"] else 256)
        vb = int(target_kbit / max(duration, 0.001))
        if vb < 50:
            rep.warn(f"Target size leaves {vb} kb/s for video, that's going to look awful")
            vb = max(vb, 10)
        args += ["-b:v", f"{vb}k"]
        if s["strict_filesize"]:
            args += ["-minrate", f"{vb}k", "-maxrate", f"{vb}k", "-bufsize", f"{vb}k"]
        if enc == "h264_nvenc":
            args += ["-rc", "vbr"]
        return args
    crf = s["crf"]
    if enc == "h264_nvenc":
        args += ["-rc", "vbr", "-cq", str(18 if crf < 0 else crf), "-b:v", "0", "-preset", "p6"]
    elif enc == "libsvtav1":
        args += ["-crf", str(20 if crf < 0 else crf), "-preset", "6"]
    else:
        args += ["-crf", str(18 if crf < 0 else crf), "-preset", "slow"]
    return args


def pass_args(enc, n):
    if enc == "libx264":
        return ["-pass", str(n), "-passlogfile", "x264pass"]
    if enc == "libx265":
        # relative stats path on purpose, x265-params splits on ':' so C:\ paths break it
        return ["-x265-params", f"pass={n}:stats=x265pass.log"]
    return []


# ---- jobs ----

def encode_video_range(clip, anode, rng, job, enc, aac, tmp, rep, ffmpeg):
    s = job["settings"]
    tracking = job["gui"]["tracking"]
    seg = clip[rng["first"]:rng["end"]]
    fps = seg.fps
    duration = seg.num_frames * fps.denominator / fps.numerator

    wav = None
    if anode is not None:
        wav = os.path.join(tmp, "audio.wav")
        t0 = frame_time(job["_src"], rng["first"], rep)
        t1 = frame_time(job["_src"], rng["end"], rep)
        if not write_wav(anode, wav, t0, t1):
            rep.warn("Audio doesn't cover this range, encoding without it")
            wav = None

    base = [ffmpeg, "-hide_banner", "-nostats", "-loglevel", "warning", "-y", "-f", "yuv4mpegpipe", "-i", "-"]
    vargs = video_codec_args(enc, s, tracking, duration, wav is not None, rep) + colour_args(seg)
    extra = custom_args(job["settings"]["video_command"], rep)

    two_pass = s["two_pass"] and s["target_filesize"] > 0 and not tracking
    if two_pass and enc == "h264_nvenc":
        vargs += ["-multipass", "fullres"]
        two_pass = False
    elif two_pass and enc not in ("libx264", "libx265"):
        rep.warn(f"Two pass isn't wired up for {enc}, doing one pass")
        two_pass = False

    def audio_args():
        if wav is None:
            return ["-map", "0:v:0"]
        ab = 64 if (s["target_filesize"] > 0 and s["strict_filesize"]) else 256
        return ["-map", "0:v:0", "-map", "1:a:0", "-c:a", aac, "-b:a", f"{ab}k"]

    out = rng["outfile"]
    mux = ["-movflags", "+faststart"] if out.lower().endswith(".mp4") else []
    log = os.path.join(tmp, "ffmpeg.log")

    if two_pass:
        rep.task(f"Pass 1: {os.path.basename(out)}")
        run_ffmpeg(base + vargs + pass_args(enc, 1) + extra + ["-an", "-f", "null", "-"], tmp, seg, rep, log)
        rep.task(f"Pass 2: {os.path.basename(out)}")
        inputs = base + (["-i", wav] if wav else [])
        run_ffmpeg(inputs + audio_args() + vargs + pass_args(enc, 2) + extra + mux + [out], tmp, seg, rep, log)
    else:
        rep.task(f"Encoding {os.path.basename(out)}")
        inputs = base + (["-i", wav] if wav else [])
        run_ffmpeg(inputs + audio_args() + vargs + extra + mux + [out], tmp, seg, rep, log)
    rep.log(f"Wrote {out}")


def encode_audio_range(anode, rng, job, aac, tmp, rep, ffmpeg):
    s = job["settings"]
    wav = os.path.join(tmp, "audio.wav")
    t0 = Fraction(rng["start_ms"], 1000)
    t1 = Fraction(rng["end_ms"], 1000)
    rep.task(f"Cutting audio {os.path.basename(rng['outfile'])}")
    if not write_wav(anode, wav, t0, t1):
        raise JobError("Audio doesn't cover the selected time range")
    ab = 64 if (s["target_filesize"] > 0 and s["strict_filesize"]) else 256
    cmd = [ffmpeg, "-hide_banner", "-nostats", "-loglevel", "warning", "-y", "-i", wav,
           "-c:a", aac, "-b:a", f"{ab}k"] + custom_args(s["audio_command"], rep) + [rng["outfile"]]
    run_ffmpeg(cmd, tmp, None, rep, os.path.join(tmp, "ffmpeg.log"))
    rep.advance(1)
    rep.log(f"Wrote {rng['outfile']}")


def export_images(clip, rng, job, rep):
    s = job["settings"]
    if not hasattr(core, "imwri"):
        raise JobError("Image export needs the imwri plugin (vsrepo install imwri).")
    outdir = rng["outdir"]
    os.makedirs(outdir, exist_ok=True)
    fmt = s["image_format"].lower()
    imgformat = "JPEG" if fmt == "jpg" else "PNG"
    seg = to_rgb24(clip[rng["first"]:rng["end"]])
    # files get named by their real frame number in the source
    writer = core.imwri.Write(seg, imgformat=imgformat, filename=os.path.join(outdir, f"%06d.{fmt}"),
                              firstnum=rng["first"], quality=int(s["jpeg_quality"]), overwrite=True)
    rep.task(f"Writing {seg.num_frames} {fmt} files to {os.path.basename(outdir)}")
    for _ in writer.frames(close=True):
        rep.advance(1)
    rep.log(f"Wrote {seg.num_frames} images to {outdir}")


def run(job, rep):
    s = job["settings"]
    gui = job["gui"]
    ranges = job["ranges"]
    mode = job["mode"]
    aegi_cfg = read_aegisub_config(job.get("user_dir", ""))
    ffmpeg = None if mode == "images" else find_exe(s["ffmpeg_exe"], "ffmpeg")
    encs = ffmpeg_encoders(ffmpeg) if ffmpeg else set()

    if mode == "audio":
        anode = load_audio(job, rep)
        if anode is None:
            raise JobError("No audio to encode")
        aac = pick_aac(s, encs)
        rep.total = len(ranges)
        tmp = tempfile.mkdtemp(prefix="baws_enc_", dir=job.get("temp_dir") or None)
        try:
            for rng in ranges:
                encode_audio_range(anode, rng, job, aac, tmp, rep, ffmpeg)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
        return

    src, how = load_video(job, aegi_cfg, rep)
    if src.format is None:
        raise JobError("Variable-format clips aren't supported")
    rep.log(f"Source: {how}, {src.width}x{src.height}, {src.num_frames} frames, {src.fps} fps, {src.format.name}")
    job["_src"] = src

    for rng in ranges:
        rng["end"] = min(rng["end"], src.num_frames)
        if rng["first"] >= rng["end"]:
            raise JobError(f"Range {rng['first']}-{rng['end']} is outside the video ({src.num_frames} frames)")
    if how in ("LSMASH", "BestSource", "FFMS2"):
        check_alignment(src, ranges[0], rep)

    clip = init_props(src, rep)
    if gui["subs"]:
        clip = add_subs(clip, job["subfile"], rep)

    if mode == "images":
        clip = scale(clip, s, s["force_square_pixels"])
        rep.total = sum(r["end"] - r["first"] for r in ranges)
        for rng in ranges:
            export_images(clip, rng, job, rep)
        return

    tracking = gui["tracking"]
    enc = {"AVC": "libx264", "AVC-NVENC": "h264_nvenc", "HEVC": "libx265", "AV1": "libsvtav1"}.get(s["encoder"], "libx264")
    if tracking:
        enc = "libx264"
    if enc not in encs:
        raise JobError(f"Your ffmpeg doesn't have {enc}. Use a full build (e.g. gyan.dev 'full').")

    clip = scale(clip, s, s["force_square_pixels"] or tracking)
    clip = to_encode_format(clip, enc, s, tracking, rep)

    if not s["use_source_fps"] and str(s["force_fps"]).strip() not in ("", "-1"):
        fps = parse_fps(s["force_fps"])
        rep.log(f"Labelling output as {fps.numerator}/{fps.denominator} fps (frames aren't added or dropped)")
        clip = clip.std.AssumeFPS(fpsnum=fps.numerator, fpsden=fps.denominator)
    elif clip.fps.numerator == 0:
        fps = parse_fps(job.get("fallback_fps") or "24000/1001")
        rep.warn(f"Source is VFR, output will be CFR {fps.numerator}/{fps.denominator}")
        clip = clip.std.AssumeFPS(fpsnum=fps.numerator, fpsden=fps.denominator)

    anode = load_audio(job, rep) if gui["audio"] else None
    aac = pick_aac(s, encs) if anode is not None else None

    two_pass = s["two_pass"] and s["target_filesize"] > 0 and not tracking and enc in ("libx264", "libx265")
    rep.total = sum(r["end"] - r["first"] for r in ranges) * (2 if two_pass else 1)

    tmp = tempfile.mkdtemp(prefix="baws_enc_", dir=job.get("temp_dir") or None)
    try:
        for rng in ranges:
            try:
                encode_video_range(clip, anode, rng, job, enc, aac, tmp, rep, ffmpeg)
            except BaseException:
                try:
                    os.remove(rng["outfile"])
                except OSError:
                    pass
                raise
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    if len(sys.argv) < 2:
        print("usage: encode_vs.py <job.json>")
        return 2
    job_path = sys.argv[1]
    with open(job_path, encoding="utf-8") as f:
        job = json.load(f)
    rep = Reporter(job_path + ".cancel")
    try:
        run(job, rep)
    except Cancelled:
        rep.log("Cancelled.")
        print("@@CANCELLED", flush=True)
        return 1
    except JobError as e:
        rep.log(f"ERROR: {e}")
        print("@@FAILED", flush=True)
        return 1
    except Exception:
        rep.log(traceback.format_exc())
        print("@@FAILED", flush=True)
        return 1
    print("@@OK", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
