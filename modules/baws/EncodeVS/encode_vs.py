__version__ = "1.0.3"

import glob
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import traceback
import uuid
from fractions import Fraction
from pathlib import Path

# don't leave __pycache__ folders around, nothing gets written outside the temp dir
sys.dont_write_bytecode = True

# run by baws.Encode as: python -u -B encode_vs.py <job.json>
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
        self.cancelled = False
        self.total = 1
        self.done = 0
        self.last_pct = -1.0
        self.ticks = 0
        self.lock = threading.Lock()

    def task(self, msg):
        print(f"@@TASK {msg}", flush=True)

    def log(self, msg):
        for line in str(msg).splitlines():
            print(line, flush=True)

    def warn(self, msg):
        self.log(f"WARNING: {msg}")

    def set(self, pct):
        print(f"@@PROGRESS {min(100.0, max(0.0, pct)):.1f}", flush=True)

    def check_cancel(self):
        if self.cancelled or (self.cancel_path and os.path.exists(self.cancel_path)):
            self.cancelled = True
            raise Cancelled()

    def start_watchdog(self):
        # frame callbacks can't notice a cancel while we're blocked writing to a slow encoder,
        # so poll for the cancel file separately and kill whatever child process we're waiting on
        def watch():
            while not self.cancelled:
                if self.cancel_path and os.path.exists(self.cancel_path):
                    self.cancelled = True
                    kill_children()
                    return
                time.sleep(0.3)

        threading.Thread(target=watch, daemon=True).start()

    def advance(self, n=1):
        with self.lock:
            self.done += n
            pct = min(100.0, int(1000 * self.done / max(self.total, 1)) / 10)
            if pct != self.last_pct:
                self.last_pct = pct
                print(f"@@PROGRESS {pct}", flush=True)
            self.ticks += 1
            if self.ticks % 8 == 0:
                self.check_cancel()


def kill_children():
    try:
        import psutil
        for c in psutil.Process().children(recursive=True):
            try:
                c.kill()
            except psutil.Error:
                pass
    except Exception:
        pass


try:
    import vapoursynth as vs
    core = vs.core
except Exception as e:
    print(f"ERROR: couldn't import vapoursynth with {sys.executable}: {e}", flush=True)
    print("Set the Python path in the Encode config to the python that has vapoursynth/vsjetpack installed.", flush=True)
    print("@@FAILED", flush=True)
    sys.exit(2)


def progress_probe(clip, rep):
    # counts frames as they get pulled, works no matter who's doing the pulling (us, ffmpeg pipe, vsmuxtools)
    def cb(n, f):
        rep.advance(1)
        return f

    return clip.std.ModifyFrame(clip, cb)


# ---- temp dirs ----

def rmtree_retry(path):
    # windows likes to hold onto files for a moment after a process exits
    for _ in range(10):
        if not os.path.exists(path):
            return True
        shutil.rmtree(path, ignore_errors=True)
        if not os.path.exists(path):
            return True
        time.sleep(0.3)
    return False


class Workspace:
    # vscache/temp_<id>/<tool>, each tool folder is wiped after every range and the lot at the end
    TOOLS = ("muxtools", "ffmpeg", "vapoursynth")

    def __init__(self, vscache, rep):
        self.base = vscache
        self.rep = rep
        os.makedirs(vscache, exist_ok=True)
        # leftovers from a cancelled or crashed run
        for name in os.listdir(vscache):
            if name.startswith("temp_"):
                shutil.rmtree(os.path.join(vscache, name), ignore_errors=True)
        self.root = os.path.join(vscache, f"temp_{uuid.uuid4().hex[:8]}")
        os.makedirs(self.root)
        # anything that writes to cwd (vsjetpack's .vsjet, stray encoder logs) lands in here too
        os.chdir(self.root)
        self.dirs = {}

    def begin_range(self):
        self.end_range()
        for t in self.TOOLS:
            p = os.path.join(self.root, t)
            os.makedirs(p, exist_ok=True)
            self.dirs[t] = p

    def end_range(self):
        for p in self.dirs.values():
            rmtree_retry(p)
        self.dirs = {}

    def close(self):
        self.end_range()
        os.chdir(self.base)
        if not rmtree_retry(self.root):
            self.rep.warn(f"Couldn't fully remove {self.root}, delete it manually")


# ---- tools ----

# only ffmpeg can be set in the config, the rest come from PATH (or muxtools' managed binaries)
TOOL_KEYS = {
    "ffmpeg": "ffmpeg_exe",
    "mkvmerge": None,
    "x264": None,
    "x265": None,
    "SvtAv1EncApp": None,
    "opusenc": None,
    "flac": None,
    "qaac": None,
}


def setup_tools(settings):
    import muxtools as mt
    for name, key in TOOL_KEYS.items():
        p = (settings.get(key) or "").strip().strip('"') if key else ""
        if p:
            if not os.path.isfile(p):
                raise JobError(f"{name} path in the config doesn't exist: {p}")
            # muxtools checks these env vars before its managed binaries and PATH
            os.environ[f"vof_exe_{name.lower()}"] = p
    ff = os.environ.get("vof_exe_ffmpeg")
    if ff:
        probe = os.path.join(os.path.dirname(ff), "ffprobe" + (".exe" if os.name == "nt" else ""))
        if os.path.isfile(probe):
            os.environ["vof_exe_ffprobe"] = probe
    # same lookup muxtools uses: config path, then managed binaries, then PATH. never downloads
    return {name: mt.get_executable(name, can_error=False) for name in TOOL_KEYS}


def need_ffmpeg(tools):
    if not tools["ffmpeg"]:
        raise JobError("ffmpeg not found. Set its path in Edit Config.")
    return tools["ffmpeg"]


_enc_cache = {}


def ffmpeg_encoders(ffmpeg):
    if ffmpeg in _enc_cache:
        return _enc_cache[ffmpeg]
    out = subprocess.run([ffmpeg, "-hide_banner", "-encoders"], capture_output=True, text=True, errors="replace").stdout
    encs = set()
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 2 and len(parts[0]) == 6 and parts[0][0] in "VAS":
            encs.add(parts[1])
    _enc_cache[ffmpeg] = encs
    return encs


def need_encoder(ffmpeg, enc):
    if enc not in ffmpeg_encoders(ffmpeg):
        raise JobError(f"Your ffmpeg doesn't have {enc}. Use a full build (e.g. gyan.dev 'full').")


def run_ffmpeg(cmd, cwd, clip, rep, logpath, raw=False):
    with open(logpath, "wb") as log:
        proc = subprocess.Popen(cmd, cwd=cwd, stdin=subprocess.PIPE if clip is not None else subprocess.DEVNULL,
                                stdout=subprocess.DEVNULL, stderr=log)
        try:
            if clip is not None:
                try:
                    clip.output(proc.stdin, y4m=not raw)
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


# ---- indexing ----

def lwi_cache_name(filename):
    # same as make_lwi_cache_filename in aegisub's aegisub_vs.py, has to match exactly
    max_len = 254
    ext = ".lwi"
    if len(filename) + len(ext) > max_len:
        filename = filename[-(max_len + len(ext)):]
    return "".join("_" if c in "/\\:" else c for c in filename) + ext


def vssource_cache_name(path, ext):
    # same naming as vssource's CacheIndexer.get_cache_path, just stored in vscache instead of .vsjet
    from hashlib import blake2s
    p = Path(path).resolve()
    h = blake2s(str(p).encode("utf-8"), digest_size=4).hexdigest()
    return f"{p.name}_{h}{ext}"


def bs_cache_base(vscache, source):
    # cachemode 3 treats cachepath as a base filename and appends .<track>.bsindex, so we get one
    # flat file per source (named like the ffindex) instead of mode 1's folder tree of the source path
    return os.path.join(vscache, vssource_cache_name(source, ""))


def video_name_candidates(job):
    # project_properties() paths go through MakeRelative/MakeAbsolute and can contain "..",
    # aegisub's vs provider got the path as it was opened, so try both
    video = job["video"]
    vdir = (job.get("video_dir") or "").rstrip("/\\")
    cands = []
    if vdir and not vdir.startswith("?"):
        cands.append(os.path.join(vdir, os.path.basename(video.replace("\\", "/"))))
    cands += [video, os.path.normpath(video)]
    out = []
    for c in cands:
        if c not in out:
            out.append(c)
    return out


def find_aegisub_lwi(job):
    for n in video_name_candidates(job):
        p = os.path.join(job["vscache"], lwi_cache_name(n))
        if os.path.exists(p):
            return p
    return None


def need_plugin(ns, name, pip_name):
    if not hasattr(core, ns):
        raise JobError(f"{name} plugin not found. Install it (pip install {pip_name}).")


def need_param(ns, func, param, name):
    sig = getattr(getattr(core, ns), func).signature
    if f"{param}:" not in sig:
        raise JobError(f"Your {name} is too old (no {param}= parameter). Update it.")


def process_read_bytes(proc):
    try:
        if os.name == "nt":
            import ctypes

            class IO_COUNTERS(ctypes.Structure):
                _fields_ = [(n, ctypes.c_ulonglong) for n in (
                    "ReadOperationCount", "WriteOperationCount", "OtherOperationCount",
                    "ReadTransferCount", "WriteTransferCount", "OtherTransferCount")]

            c = IO_COUNTERS()
            if ctypes.windll.kernel32.GetProcessIoCounters(ctypes.c_void_p(int(proc._handle)), ctypes.byref(c)):
                return c.ReadTransferCount
            return None
        with open(f"/proc/{proc.pid}/io") as f:
            for line in f:
                if line.startswith("rchar:"):
                    return int(line.split()[1])
    except Exception:
        return None
    return None


INDEX_CHILD = r"""
import sys
sys.dont_write_bytecode = True
import vapoursynth as vs
core = vs.core
kind, src, cache = sys.argv[1], sys.argv[2], sys.argv[3]
print("@@START", flush=True)
if kind == "ffms2":
    core.ffms2.Index(source=src, cachefile=cache, overwrite=True)
else:
    core.lsmas.LWLibavSource(source=src, cachefile=cache)
print("@@DONE", flush=True)
"""


def index_in_subprocess(kind, src, cache, rep, label):
    # vs holds the GIL for the whole plugin call, so index in a child process and
    # watch how much of the file it has read to get a progress bar
    rep.task(label)
    rep.set(0)
    size = os.path.getsize(src) if os.path.isfile(src) else 0
    proc = subprocess.Popen([sys.executable, "-B", "-c", INDEX_CHILD, kind, src, cache],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                            text=True, encoding="utf-8", errors="replace")
    started = threading.Event()
    output = []

    def reader():
        for line in proc.stdout:
            if line.startswith("@@START"):
                started.set()
            elif not line.startswith("@@DONE"):
                output.append(line)

    t = threading.Thread(target=reader, daemon=True)
    t.start()
    base = None
    try:
        while proc.poll() is None:
            time.sleep(0.25)
            if started.is_set() and size:
                r = process_read_bytes(proc)
                if r is not None:
                    if base is None:
                        base = r
                    rep.set(min(99.0, 100.0 * (r - base) / size))
            rep.check_cancel()
    except BaseException:
        proc.kill()
        proc.wait()
        try:
            os.remove(cache)
        except OSError:
            pass
        raise
    t.join(2)
    if proc.returncode != 0:
        raise JobError(f"Indexing failed:\n{''.join(output)[-3000:]}")
    rep.set(100)

def drop_index(path):
    try:
        os.remove(path)
    except OSError:
        pass


def index_outdated(cache, src):
    # source got replaced or re-encoded after the index was made
    try:
        return os.path.getmtime(src) > os.path.getmtime(cache)
    except OSError:
        return False


def looks_like_index_error(e):
    return "index" in str(e).lower()


def open_indexed(kind, src, cache, opener, rep, label):
    if index_outdated(cache, src):
        rep.log(f"{os.path.basename(src)} changed since it was indexed, reindexing")
        drop_index(cache)
    fresh = not os.path.exists(cache)
    if fresh:
        index_in_subprocess(kind, src, cache, rep, label)
    try:
        return opener()
    except vs.Error as e:
        # a fresh index failing means something else is wrong, don't loop on it
        if fresh or not looks_like_index_error(e):
            raise
        rep.log(f"Index doesn't match the source anymore ({e}), reindexing")
        drop_index(cache)
        index_in_subprocess(kind, src, cache, rep, label)
        return opener()


def drop_stale_bs(vscache, src, rep):
    # bestsource keeps one .bsindex per track next to the base name
    base = bs_cache_base(vscache, src)
    for p in glob.glob(glob.escape(base) + ".*.bsindex"):
        if index_outdated(p, src):
            rep.log(f"{os.path.basename(src)} changed since it was indexed, dropping {os.path.basename(p)}")
            drop_index(p)


class bs_progress:
    # bestsource reports indexing progress as vs log messages
    pat = re.compile(r"index progress (\d+(?:\.\d+)?)%")

    def __init__(self, rep, label):
        self.rep = rep
        self.label = label

    def __enter__(self):
        self.rep.task(self.label)
        self.rep.set(0)

        def handler(mt, msg):
            m = self.pat.search(msg)
            if m:
                self.rep.set(float(m.group(1)))

        self.handle = core.add_log_handler(handler)
        return self

    def __exit__(self, *exc):
        core.remove_log_handler(self.handle)
        return False


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


def load_video(job, rep):
    video = job["video"]
    if video.startswith("?dummy"):
        return parse_dummy(video), "dummy"
    if video.lower().endswith((".vpy", ".py")):
        rep.task("Running the .vpy")
        return load_vpy(video), "vpy"

    vscache = job["vscache"]
    os.makedirs(vscache, exist_ok=True)
    indexer = job["settings"]["indexer"]

    # Auto and LWI reuse aegisub's lwi when there is a usable one. if not, Auto makes an ffindex and LWI makes an lwi
    if indexer in ("Auto", "LWI"):
        lwi = find_aegisub_lwi(job)
        if lwi and index_outdated(lwi, video):
            rep.log("Aegisub's lwi index is older than the video, not reusing it")
            lwi = None
        if lwi:
            need_plugin("lsmas", "LSMASH", "vapoursynth-lsmas")
            need_param("lsmas", "LWLibavSource", "cachefile", "lsmas")
            try:
                clip = core.lsmas.LWLibavSource(source=video, cachefile=lwi)
                rep.log(f"Reusing Aegisub's lwi index: {os.path.basename(lwi)}")
                return clip, "LSMASH (Aegisub's index)"
            except vs.Error as e:
                if not looks_like_index_error(e):
                    raise
                rep.log(f"Aegisub's lwi index doesn't match the video ({e}), not reusing it")
        indexer = "FFMS2" if indexer == "Auto" else "LWI"

    if indexer == "FFMS2":
        need_plugin("ffms2", "FFMS2", "vapoursynth-ffms2")
        cache = os.path.join(vscache, vssource_cache_name(video, ".ffindex"))
        clip = open_indexed("ffms2", video, cache,
                            lambda: core.ffms2.Source(source=video, cachefile=cache),
                            rep, "Indexing with FFMS2 (one-off per file)")
        return clip, "FFMS2"

    if indexer == "LWI":
        need_plugin("lsmas", "LSMASH", "vapoursynth-lsmas")
        need_param("lsmas", "LWLibavSource", "cachefile", "lsmas")
        # aegisub's naming, so aegisub's vs provider can pick it up too
        cache = os.path.join(vscache, lwi_cache_name(video_name_candidates(job)[0]))
        clip = open_indexed("lsmas", video, cache,
                            lambda: core.lsmas.LWLibavSource(source=video, cachefile=cache),
                            rep, "Indexing with LSMASH (one-off per file)")
        return clip, "LSMASH"

    if indexer == "BestSource":
        need_plugin("bs", "BestSource", "vapoursynth-bestsource")
        drop_stale_bs(vscache, video, rep)
        with bs_progress(rep, "Opening with BestSource (indexes on first use)"):
            clip = core.bs.VideoSource(source=video, cachemode=3, cachepath=bs_cache_base(vscache, video), showprogress=True)
        return clip, "BestSource"

    raise JobError(f"Unknown indexer {indexer}")


def load_audio(job, rep):
    src = job.get("audio_file") or job["video"]
    if src.startswith("?dummy") or src.startswith("dummy-audio"):
        return None
    need_plugin("bs", "BestSource", "vapoursynth-bestsource")
    s = job["settings"]
    o = job["opts"]
    track = -int(o.get("aid", 1)) if o.get("use_aid") else -1
    drop_stale_bs(job["vscache"], src, rep)
    try:
        with bs_progress(rep, "Loading audio (indexes on first use)"):
            return core.bs.AudioSource(source=src, track=track, cachemode=3, cachepath=bs_cache_base(job["vscache"], src), showprogress=True)
    except vs.Error as e:
        rep.warn(f"Couldn't open audio, continuing without it: {e}")
        return None


# ---- timing ----

def parse_fps(s):
    s = str(s).strip().replace("\\", "/")
    if not re.fullmatch(r"\d+/\d+", s):
        raise JobError(f"FPS has to be a fraction like 24000/1001, got '{s}'")
    f = Fraction(s)
    if f <= 0:
        raise JobError("FPS has to be positive")
    return f


def frame_time(clip, n):
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
        prev = int(frame_time(clip, first - 1) * 1000)
        cur = int(frame_time(clip, first) * 1000)
    except JobError:
        return
    expected = prev + (cur - prev + 1) // 2
    if abs(expected - ms) > 2:
        off = round((ms - expected) / max(cur - prev, 1))
        rep.warn(f"Frame {first} is at {expected} ms here but {ms} ms in Aegisub (~{off} frame(s) off).")
        rep.warn("The indexer isn't numbering frames like Aegisub's video provider. Try a different indexer in the config.")


# ---- filtering ----

def init_props(clip, rep):
    try:
        import vstools
        return vstools.initialize_clip(clip, bits=None)
    except Exception as e:
        rep.warn(f"initialize_clip failed ({e}), continuing with the props as they are")
        return clip


def add_hardsubs(clip, subfile):
    if hasattr(core, "sub"):
        return core.sub.TextFile(clip, file=subfile)
    if hasattr(core, "assrender"):
        return core.assrender.TextSub(clip, file=subfile)
    raise JobError("Hardsubbing needs the subtext plugin (pip install vapoursynth-subtext).")


def get_sar(clip):
    props = clip.get_frame(0).props
    num, den = props.get("_SARNum", 1), props.get("_SARDen", 1)
    if not num or not den:
        return Fraction(1)
    return Fraction(num, den)


def even(x):
    return max(2, int(round(x / 2)) * 2)


PLACEBO_PROBE = r"""
import sys
sys.dont_write_bytecode = True
import vapoursynth as vs
c = vs.core.std.BlankClip(width=64, height=64, format=vs.YUV420P16, length=1)
vs.core.placebo.Resample(c, 32, 32).get_frame(0)
"""


def placebo_works():
    # placebo needs vulkan and segfaults the whole process without it, so try it in a child first
    if not hasattr(core, "placebo"):
        return False
    try:
        r = subprocess.run([sys.executable, "-B", "-c", PLACEBO_PROBE], capture_output=True, timeout=60)
        return r.returncode == 0
    except Exception:
        return False


def scale(clip, height, square, rep):
    w, h = clip.width, clip.height
    sar = get_sar(clip)
    if square and sar != 1:
        w = even(w * sar)
    if height and height > 0 and height != h:
        w = even(w * height / h)
        h = height
    if (w, h) != (clip.width, clip.height):
        # placebo only takes 8/16-bit int or 32-bit float, and scaling at 16-bit is nicer anyway.
        # the encode step dithers back down to whatever depth is wanted
        f = clip.format
        if f.sample_type == vs.INTEGER and f.bits_per_sample != 16:
            import vstools
            clip = vstools.depth(clip, 16)
        elif f.sample_type == vs.FLOAT and f.bits_per_sample != 32:
            import vstools
            clip = vstools.depth(clip, 32)
        if w * h > clip.width * clip.height:
            if placebo_works():
                from vskernels import EwaLanczos
                clip = EwaLanczos().scale(clip, w, h)
            else:
                rep.warn("vs-placebo isn't usable here (not installed, or no Vulkan GPU), upscaling with Lanczos (3 taps) instead")
                from vskernels import Lanczos
                clip = Lanczos(taps=3).scale(clip, w, h)
        else:
            from vskernels import Hermite
            clip = Hermite().scale(clip, w, h)
    # resize nudges the SAR to cover width rounding, we already picked the width to keep the aspect so undo that
    keep = Fraction(1) if square else sar
    return clip.std.SetFrameProps(_SARNum=keep.numerator, _SARDen=keep.denominator)


def to_encode_format(clip, bits_req, src_bits, max_bits, force_420, rep):
    f = clip.format
    if bits_req == "Source":
        # src_bits is from before scaling, which works at 16-bit
        bits = src_bits
    else:
        bits = int(bits_req)
    if bits > max_bits:
        if bits_req != "Source":
            rep.warn(f"This codec can't do {bits}-bit, using {max_bits}-bit")
        bits = max_bits
    bits = 8 if bits <= 8 else bits

    if f.color_family == vs.YUV and not force_420:
        ssw, ssh = f.subsampling_w, f.subsampling_h
    else:
        ssw, ssh = 1, 1
    target = core.query_video_format(vs.YUV, vs.INTEGER, bits, ssw, ssh)
    if target.id == f.id:
        return clip
    if f.color_family == vs.YUV and (f.subsampling_w, f.subsampling_h) == (ssw, ssh):
        import vstools
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


MATRIX = {1: "bt709", 5: "bt470bg", 6: "smpte170m", 7: "smpte240m", 9: "bt2020nc", 10: "bt2020c"}
TRANSFER = {1: "bt709", 4: "bt470m", 5: "bt470bg", 6: "smpte170m", 7: "smpte240m", 8: "linear",
            13: "iec61966-2-1", 14: "bt2020-10", 15: "bt2020-12", 16: "smpte2084", 18: "arib-std-b67"}
PRIMARIES = {1: "bt709", 4: "bt470m", 5: "bt470bg", 6: "smpte170m", 7: "smpte240m", 9: "bt2020", 12: "smpte432"}


def colour_args(clip):
    # y4m doesn't carry colour info, so hand it to the encoder ourselves
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


# ---- audio ----

def export_wav(anode, path, t0, t1):
    s0 = max(0, int(round(t0 * anode.sample_rate)))
    s1 = min(anode.num_samples, int(round(t1 * anode.sample_rate)))
    if s1 <= s0:
        return False
    with open(path, "wb") as f:
        anode[s0:s1].output(f, wav=True)
    return True


def ffmpeg_audio(wav, args, ext, ws, tools, rep):
    ffmpeg = need_ffmpeg(tools)
    out = os.path.join(ws.dirs["ffmpeg"], "audio" + ext)
    cmd = [ffmpeg, "-hide_banner", "-nostats", "-loglevel", "warning", "-y", "-i", wav, "-map", "0:a:0"] + args + [out]
    run_ffmpeg(cmd, ws.dirs["ffmpeg"], None, rep, os.path.join(ws.dirs["ffmpeg"], "audio.log"))
    return out


def best_ffmpeg_aac(tools):
    return "libfdk_aac" if "libfdk_aac" in ffmpeg_encoders(need_ffmpeg(tools)) else "aac"


def encode_audio(wav, codec, bitrate, ws, tools, rep):
    import muxtools as mt
    out = os.path.join(ws.dirs["muxtools"], "audio")
    rep.task(f"Encoding audio ({codec})")

    if codec == "Opus":
        if tools["opusenc"]:
            try:
                return str(mt.Opus(bitrate=bitrate, output=out).encode_audio(wav).file)
            except Exception as e:
                rep.warn(f"opusenc failed ({e}), falling back to ffmpeg")
        need_encoder(need_ffmpeg(tools), "libopus")
        return ffmpeg_audio(wav, ["-c:a", "libopus", "-b:a", f"{bitrate}k"], ".opus", ws, tools, rep)

    if codec == "FLAC":
        if tools["flac"]:
            try:
                return str(mt.FLAC(compression_level=8, output=out).encode_audio(wav).file)
            except Exception as e:
                rep.warn(f"flac failed ({e}), falling back to ffmpeg")
        need_ffmpeg(tools)
        return str(mt.FF_FLAC(output=out).encode_audio(wav).file)

    if codec == "AAC":
        from muxtools.utils.types import qAAC_MODE
        if tools["qaac"]:
            try:
                return str(mt.qAAC(q=bitrate, mode=qAAC_MODE.CVBR, output=out).encode_audio(wav).file)
            except Exception as e:
                rep.warn(f"qaac failed ({e}), trying FDK/ffmpeg")
        ffmpeg = need_ffmpeg(tools)
        if "libfdk_aac" in ffmpeg_encoders(ffmpeg) or shutil.which("fdkaac"):
            try:
                return str(mt.FDK_AAC(bitrate_mode=0, bitrate=bitrate, output=out).encode_audio(wav).file)
            except Exception as e:
                rep.warn(f"FDK AAC failed ({e}), using ffmpeg's aac")
        return ffmpeg_audio(wav, ["-c:a", "aac", "-b:a", f"{bitrate}k"], ".m4a", ws, tools, rep)

    raise JobError(f"Unknown audio codec {codec}")


AUDIO_EXT = {"Opus": ".opus", "FLAC": ".flac", "AAC": ".m4a"}


# ---- video ----

# name in the gui -> (muxtools exe, ffmpeg encoder, max bits, default crf)
VIDEO_CODECS = {
    "x264 (AVC)": ("x264", "libx264", 10, 18),
    "x265 (HEVC)": ("x265", "libx265", 12, 18),
    "SVT-AV1 (AV1)": ("SvtAv1EncApp", "libsvtav1", 10, 20),
    "NVENC (AVC)": (None, "h264_nvenc", 8, 18),
    "MP4 (H.264 + AAC)": (None, "libx264", 8, 18),
    "WebM (VP9 + Opus)": (None, "libvpx-vp9", 8, 30),
}


def ffmpeg_vargs(enc, crf, vb):
    if enc == "libx264" or enc == "libx265":
        base = ["-c:v", enc, "-preset", "slow"]
        return base + (["-b:v", f"{vb}k"] if vb else ["-crf", str(crf)])
    if enc == "libsvtav1":
        return ["-c:v", enc, "-preset", "6"] + (["-b:v", f"{vb}k"] if vb else ["-crf", str(crf)])
    if enc == "h264_nvenc":
        base = ["-c:v", enc, "-preset", "p6", "-rc", "vbr"]
        return base + (["-b:v", f"{vb}k", "-multipass", "fullres"] if vb else ["-cq", str(crf), "-b:v", "0"])
    if enc == "libvpx-vp9":
        base = ["-c:v", enc, "-row-mt", "1", "-deadline", "good", "-cpu-used", "2"]
        return base + (["-b:v", f"{vb}k"] if vb else ["-crf", str(crf), "-b:v", "0"])
    raise JobError(f"Unknown encoder {enc}")


def ffmpeg_pass_args(enc, n):
    if enc == "libx264":
        return ["-pass", str(n), "-passlogfile", "x264pass"]
    if enc == "libvpx-vp9":
        return ["-pass", str(n), "-passlogfile", "vp9pass"]
    if enc == "libx265":
        # relative stats path on purpose, x265-params splits on ':' so C:\ paths break it
        return ["-x265-params", f"pass={n}:stats=x265pass.log"]
    return None


def ffmpeg_encode(seg, enc, crf, vb, out, ws, tools, rep, wav=None, aargs=None, meta_args=None):
    ffmpeg = need_ffmpeg(tools)
    need_encoder(ffmpeg, enc)
    vargs = ffmpeg_vargs(enc, crf, vb) + colour_args(seg)
    passes = [[]]
    if vb and ffmpeg_pass_args(enc, 1):
        passes = [ffmpeg_pass_args(enc, 1), ffmpeg_pass_args(enc, 2)]
    fdir = ws.dirs["ffmpeg"]
    for i, pargs in enumerate(passes):
        last = i == len(passes) - 1
        cmd = [ffmpeg, "-hide_banner", "-nostats", "-loglevel", "warning", "-y", "-f", "yuv4mpegpipe", "-i", "-"]
        if last and wav:
            cmd += ["-i", wav]
        cmd += ["-map", "0:v:0"]
        if last and wav:
            cmd += ["-map", "1:a:0"] + aargs
        cmd += vargs + pargs
        cmd += ((meta_args or []) + [out]) if last else ["-an", "-f", "null", "-"]
        if len(passes) > 1:
            rep.task(f"Pass {i + 1}/{len(passes)}")
        run_ffmpeg(cmd, fdir, progress_probe(seg, rep), rep, os.path.join(fdir, "video.log"))
    return out


def muxtools_encode(seg, exe, crf, vb, ws, rep):
    import vsmuxtools as vsm
    wd = ws.dirs["muxtools"]
    stats = os.path.join(wd, "pass.stats")
    passes = [1, 2] if vb and exe in ("x264", "x265") else [None]
    result = None
    for p in passes:
        out = os.path.join(wd, f"video_pass{p}" if p == 1 else "video")
        if p:
            rep.task(f"Pass {p}/2 ({exe})")
        if exe in ("x264", "x265"):
            st = ["--preset", "slow"]
            st += ["--bitrate", str(vb), "--pass", str(p), "--stats", stats] if vb else ["--crf", str(crf)]
            if exe == "x264":
                enc = vsm.x264(settings=st, resumable=False)
            else:
                # csv=False, otherwise x265 drops a log csv in the cwd
                enc = vsm.x265(settings=st, resumable=False, csv=False)
        else:
            kw = {"preset": 6}
            if vb:
                kw.update(rc=1, tbr=vb)
                rep.log("SVT-AV1 target size uses single pass VBR")
            else:
                kw["crf"] = crf
            enc = vsm.SVTAV1(resumable=False, light_photon_noise=False, **kw)
        try:
            result = str(enc.encode(progress_probe(seg, rep), out).file)
        except (Cancelled, JobError):
            raise
        except Exception as e:
            if rep.cancelled:
                raise Cancelled()
            raise JobError(f"{exe} failed, see its output above ({type(e).__name__}: {e})")
    return result


# ---- subtitles ----

def softsubs(job, rng, src_fps, t0, t1, rep):
    import muxtools as mt
    rep.task("Preparing softsubs")
    # SubFile copies the script into the muxtools workdir before touching it
    sub = mt.SubFile(job["subfile"])

    def keep(lines):
        return [ln for ln in lines if ln.end.total_seconds() > float(t0) and ln.start.total_seconds() < float(t1)]

    sub = sub.manipulate_lines(keep)
    sub = sub.shift(-rng["first"], src_fps, mt.TimeScale.MKV, oob_mode=mt.OutOfBoundsMode.MAX_TO_ZERO)
    fonts = sub.collect_fonts(use_system_fonts=True, search_current_dir=False)
    return sub, fonts


# ---- muxing ----

def probe_streams(path, tools):
    import muxtools as mt
    ffprobe = mt.get_executable("ffprobe", can_error=False)
    if not ffprobe or not os.path.isfile(path):
        return []
    out = subprocess.run([ffprobe, "-v", "error", "-show_streams", "-of", "json", path],
                         capture_output=True, text=True, encoding="utf-8", errors="replace").stdout
    try:
        return json.loads(out).get("streams", [])
    except ValueError:
        return []


def track_info(stream):
    if not stream:
        return "", "und"
    tags = {k.lower(): v for k, v in (stream.get("tags") or {}).items()}
    return tags.get("title", ""), tags.get("language", "") or "und"


def source_track_info(job, tools):
    # names + languages of the source tracks we're using, so the clip keeps them
    info = {"video": ("", "und"), "audio": ("", "und")}
    video = job["video"]
    if not video.startswith("?dummy") and not video.lower().endswith((".vpy", ".py")):
        vids = [st for st in probe_streams(video, tools)
                if st.get("codec_type") == "video" and not (st.get("disposition") or {}).get("attached_pic")]
        info["video"] = track_info(vids[0] if vids else None)
    asrc = job.get("audio_file") or video
    if not asrc.startswith("?dummy") and not asrc.startswith("dummy-audio"):
        auds = [st for st in probe_streams(asrc, tools) if st.get("codec_type") == "audio"]
        o = job["opts"]
        n = int(o.get("aid", 1)) - 1 if o.get("use_aid") else 0
        info["audio"] = track_info(auds[n] if 0 <= n < len(auds) else None)
    if not job["settings"].get("keep_track_names", True):
        # keep the languages, drop the names
        info = {k: ("", lang) for k, (_, lang) in info.items()}
    return info


def ffmpeg_meta_args(meta, has_audio):
    args = []
    kinds = [("v", meta["video"])] + ([("a", meta["audio"])] if has_audio else [])
    for kind, (title, lang) in kinds:
        if title:
            # mp4 keeps track names in handler_name, mkv/webm use title
            args += [f"-metadata:s:{kind}:0", f"title={title}", f"-metadata:s:{kind}:0", f"handler_name={title}"]
        args += [f"-metadata:s:{kind}:0", f"language={lang}"]
    return args


def mux_mkv(video, audio, sub, fonts, out, tools, rep, meta, sub_name):
    import muxtools as mt
    if not tools["mkvmerge"]:
        raise JobError("mkvmerge not found, it's needed for mkv output. Set its path in Edit Config.")
    rep.task("Muxing")
    # no fps args here on purpose, the encoders already wrote the rate vapoursynth gave them into the stream
    tracks = [mt.VideoFile(video).to_track(*meta["video"])]
    if audio:
        tracks.append(mt.AudioFile(audio).to_track(*meta["audio"]))
    if sub:
        tracks.append(sub.to_track(sub_name, "und", True, False))
        tracks += fonts
    mt.mux(*tracks, outfile=out, quiet=True)


# ---- modes ----

def do_video_range(clip, src, anode, rng, job, ws, tools, rep):
    o = job["opts"]
    out = rng["outfile"]
    exe, enc, _, default_crf = VIDEO_CODECS[o["codec"]]
    crf = default_crf if o["crf"] < 0 else o["crf"]
    container = os.path.splitext(out)[1].lower()
    seg = clip[rng["first"]:rng["end"]]
    fps = seg.fps
    duration = seg.num_frames * fps.denominator / fps.numerator
    t0, t1 = frame_time(src, rng["first"]), frame_time(src, rng["end"])

    wav = None
    if anode is not None:
        wav = os.path.join(ws.dirs["vapoursynth"], "audio.wav")
        rep.task("Cutting audio")
        if not export_wav(anode, wav, t0, t1):
            rep.warn("Audio doesn't cover this range, encoding without it")
            wav = None

    if container in (".mp4", ".webm"):
        aargs = None
        if wav:
            ab = o["audio_bitrate"]
            aargs = ["-c:a", best_ffmpeg_aac(tools), "-b:a", f"{ab}k"] if container == ".mp4" else ["-c:a", "libopus", "-b:a", f"{ab}k"]
        vb = 0
        if o["target_kb"] > 0:
            audio_kbit = duration * o["audio_bitrate"] if wav else 0
            vb = video_budget(o["target_kb"], audio_kbit, duration, rep)
        rep.task(f"Encoding {os.path.basename(out)}")
        ffmpeg_encode(seg, enc, crf, vb, out, ws, tools, rep, wav=wav, aargs=aargs,
                      meta_args=ffmpeg_meta_args(job["_meta"], wav is not None))
        return

    # mkv: audio first so a target size can account for its real size
    audio = None
    if wav:
        audio = encode_audio(wav, o["audio_codec"], o["audio_bitrate"], ws, tools, rep)
    sub, fonts = None, []
    if o["subs"] == "soft":
        sub, fonts = softsubs(job, rng, src.fps, t0, t1, rep)

    vb = 0
    if o["target_kb"] > 0:
        # whatever else goes in the file comes out of the video's share
        extra = [audio] if audio else []
        extra += [str(sub.file)] if sub else []
        extra += [str(f.file) for f in fonts]
        other_kbit = sum(os.path.getsize(p) for p in extra) * 8 / 1000
        vb = video_budget(o["target_kb"], other_kbit, duration, rep)

    rep.task(f"Encoding {os.path.basename(out)}")
    if exe and tools[exe]:
        video = muxtools_encode(seg, exe, crf, vb, ws, rep)
    else:
        if exe:
            rep.log(f"{exe} not found, encoding with ffmpeg's {enc}")
        video = ffmpeg_encode(seg, enc, crf, vb, os.path.join(ws.dirs["ffmpeg"], "video.mkv"), ws, tools, rep)
    sub_name = ""
    if sub and job["settings"].get("name_subs_after_script", True):
        sub_name = os.path.splitext(os.path.basename(job["subfile"]))[0]
    mux_mkv(video, audio, sub, fonts, out, tools, rep, job["_meta"], sub_name)


def video_budget(target_kb, other_kbit, duration, rep):
    # KB like the old script (1000 bytes), keep 2% for container overhead
    total_kbit = target_kb * 8 * 0.98
    vb = int((total_kbit - other_kbit) / max(duration, 0.001))
    if vb < 50:
        raise JobError(f"{target_kb} KB is too small: audio/subs/fonts already take {other_kbit / 8:.0f} KB, "
                       f"leaving {vb} kb/s for video. Raise the target, lower the audio bitrate or skip softsubs.")
    if vb < 300:
        rep.warn(f"Target size leaves {vb} kb/s for video, expect it to look rough")
    return vb


def do_audio_range(anode, rng, job, ws, tools, rep):
    o = job["opts"]
    out = rng["outfile"]
    wav = os.path.join(ws.dirs["vapoursynth"], "audio.wav")
    rep.task("Cutting audio")
    if not export_wav(anode, wav, Fraction(rng["start_ms"], 1000), Fraction(rng["end_ms"], 1000)):
        raise JobError("Audio doesn't cover the selected time range")
    res = encode_audio(wav, o["audio_codec"], o["audio_bitrate"], ws, tools, rep)
    if o["audio_codec"] == "AAC" and not res.lower().endswith(".m4a"):
        # qaac writes raw adts, put it in an m4a so it has proper duration/seeking
        res = ffmpeg_audio(res, ["-c:a", "copy"], ".m4a", ws, tools, rep)
    shutil.move(res, out)
    rep.advance(1)


def jpeg_qscale(quality):
    # ffmpeg's mjpeg takes -q:v 2 (best) to 31 (worst), map the 1-100 quality onto that
    q = max(1, min(100, int(quality)))
    return str(round(2 + (100 - q) * 29 / 99))


def do_images_range(clip, rng, job, ws, tools, rep):
    o = job["opts"]
    outdir = rng["outdir"]
    os.makedirs(outdir, exist_ok=True)
    fmt = o["image_format"].lower()
    seg = to_rgb24(clip[rng["first"]:rng["end"]])
    # files get named by their real frame number in the source
    pattern = os.path.join(outdir, f"%06d.{fmt}")
    rep.task(f"Writing {seg.num_frames} {fmt} files")

    if fmt == "png" and hasattr(core, "fpng"):
        writer = core.fpng.Write(seg, filename=pattern, firstnum=rng["first"], overwrite=True)
        for _ in writer.frames(close=True):
            rep.advance(1)
        return

    # everything else gets piped into ffmpeg as raw rgb. vs writes planes as R,G,B but ffmpeg's
    # planar rgb (gbrp) wants G,B,R, so shuffle them first
    ffmpeg = need_ffmpeg(tools)
    gbr = core.std.ShufflePlanes(seg, [1, 2, 0], vs.RGB)
    fps = seg.fps if seg.fps.numerator else Fraction(24000, 1001)
    if fmt == "jpg":
        codec = ["-c:v", "mjpeg", "-q:v", jpeg_qscale(o["quality"]), "-pix_fmt", "yuvj444p"]
    else:
        codec = ["-c:v", "png", "-pix_fmt", "rgb24"]
    cmd = [ffmpeg, "-hide_banner", "-nostats", "-loglevel", "warning", "-y",
           "-f", "rawvideo", "-pix_fmt", "gbrp", "-s", f"{seg.width}x{seg.height}",
           "-r", f"{fps.numerator}/{fps.denominator}", "-i", "-"] + codec + ["-start_number", str(rng["first"]), pattern]
    fdir = ws.dirs["ffmpeg"]
    run_ffmpeg(cmd, fdir, progress_probe(gbr, rep), rep, os.path.join(fdir, "images.log"), raw=True)


def run(job, rep):
    s = job["settings"]
    mode = job["mode"]
    ranges = job["ranges"]
    tools = setup_tools(s)
    ws = Workspace(job["vscache"], rep)
    current = None
    try:
        if mode == "audio":
            anode = load_audio(job, rep)
            if anode is None:
                raise JobError("No audio to encode")
            rep.total = len(ranges)
            for rng in ranges:
                current = rng["outfile"]
                make_parent(current)
                ws.begin_range()
                setup_muxtools(ws)
                do_audio_range(anode, rng, job, ws, tools, rep)
                rep.log(f"Wrote {current}")
                ws.end_range()
            current = None
            return

        src, how = load_video(job, rep)
        if src.format is None:
            raise JobError("Variable-format clips aren't supported")
        rep.log(f"Source: {how}, {src.width}x{src.height}, {src.num_frames} frames, {src.fps} fps, {src.format.name}")

        for rng in ranges:
            rng["end"] = min(rng["end"], src.num_frames)
            if rng["first"] >= rng["end"]:
                raise JobError(f"Range {rng['first']}-{rng['end']} is outside the video ({src.num_frames} frames)")
        if how not in ("dummy", "vpy"):
            check_alignment(src, ranges[0], rep)

        o = job["opts"]
        clip = init_props(src, rep)
        if o.get("subs") == "hard":
            clip = add_hardsubs(clip, job["subfile"])

        if mode == "images":
            clip = scale(clip, o.get("height", 0), False, rep)
            rep.total = sum(r["end"] - r["first"] for r in ranges)
            for rng in ranges:
                current = rng["outdir"]
                ws.begin_range()
                do_images_range(clip, rng, job, ws, tools, rep)
                ws.end_range()
                rep.log(f"Wrote {rng['end'] - rng['first']} images to {current}")
            current = None
            return

        exe, enc, max_bits, _ = VIDEO_CODECS[o["codec"]]
        compat = o["codec"] in ("MP4 (H.264 + AAC)", "WebM (VP9 + Opus)")
        if not compat and not tools["mkvmerge"]:
            raise JobError("mkvmerge not found, it's needed for mkv output. Set its path in Edit Config.")
        src_bits = clip.format.bits_per_sample if clip.format.sample_type == vs.INTEGER else 10
        clip = scale(clip, o["height"], o.get("square", False), rep)
        clip = to_encode_format(clip, o["bitdepth"], src_bits, max_bits, compat, rep)

        if o["fps"].strip():
            fps = parse_fps(o["fps"])
            rep.log(f"Output rate set to {fps.numerator}/{fps.denominator} (frames aren't added or dropped)")
            clip = clip.std.AssumeFPS(fpsnum=fps.numerator, fpsden=fps.denominator)
        elif clip.fps.numerator == 0:
            fps = parse_fps(job.get("fallback_fps") or "24000/1001")
            rep.warn(f"Source is VFR, output will be CFR {fps.numerator}/{fps.denominator}")
            clip = clip.std.AssumeFPS(fpsnum=fps.numerator, fpsden=fps.denominator)

        anode = load_audio(job, rep) if o["audio"] else None
        job["_meta"] = source_track_info(job, tools)

        two_pass = o["target_kb"] > 0 and (enc in ("libx264", "libx265", "libvpx-vp9"))
        rep.total = sum(r["end"] - r["first"] for r in ranges) * (2 if two_pass else 1)
        for rng in ranges:
            current = rng["outfile"]
            make_parent(current)
            ws.begin_range()
            setup_muxtools(ws)
            do_video_range(clip, src, anode, rng, job, ws, tools, rep)
            rep.log(f"Wrote {current}")
            ws.end_range()
        current = None
    except BaseException:
        if current:
            if os.path.isdir(current):
                shutil.rmtree(current, ignore_errors=True)
            else:
                try:
                    os.remove(current)
                except OSError:
                    pass
        raise
    finally:
        ws.close()


def make_parent(path):
    # the output path can have tokens in it now, so the folder might not exist yet
    os.makedirs(os.path.dirname(path), exist_ok=True)


def setup_muxtools(ws):
    import muxtools as mt
    wd = ws.dirs["muxtools"]
    mt.Setup("clip", work_dir=wd, out_dir=wd, show_name="", out_name="clip", mkv_title_naming="",
             clean_work_dirs=False, debug=False)


def main():
    if len(sys.argv) < 2:
        print("usage: encode_vs.py <job.json>")
        return 2
    job_path = os.path.abspath(sys.argv[1])
    with open(job_path, encoding="utf-8") as f:
        job = json.load(f)
    rep = Reporter(job_path + ".cancel")
    rep.start_watchdog()
    try:
        run(job, rep)
    except Exception as e:
        # killed children surface as all sorts of errors, so check the flag first
        if rep.cancelled or isinstance(e, Cancelled):
            rep.log("Cancelled.")
            print("@@CANCELLED", flush=True)
            return 1
        if isinstance(e, JobError):
            rep.log(f"ERROR: {e}")
            print("@@FAILED", flush=True)
            return 1
        rep.log(traceback.format_exc())
        print("@@FAILED", flush=True)
        return 1
    print("@@OK", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
