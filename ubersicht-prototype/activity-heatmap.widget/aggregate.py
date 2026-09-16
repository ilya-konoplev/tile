#!/usr/bin/env python3
"""Aggregates macOS Screen Time activity from knowledgeC.db into a daily heatmap JSON.

Reads /app/usage (apps, bundle id) and /app/webUsage (sites, domain) from ZOBJECT,
buckets durations by local calendar day, applies the allow/deny filter from
config.json and writes activity.json next to this script (also prints it to stdout,
which is what the Übersicht widget consumes).
"""

import json
import math
import os
import shutil
import sqlite3
import sys
import tempfile
from collections import defaultdict
from datetime import datetime, timedelta

# Core Data epoch: 2001-01-01 00:00:00 UTC
CORE_DATA_EPOCH = 978307200
DAYS = 91

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(HERE, "config.json")
OUTPUT_PATH = os.path.join(HERE, "activity.json")
DB_PATH = os.path.expanduser(
    "~/Library/Application Support/Knowledge/knowledgeC.db"
)


# --- colour ramp -----------------------------------------------------------
# The heatmap ramp is derived from a single accent colour: we take its OKLCH hue
# and walk a fixed lightness/chroma curve along it. OKLCH keeps the steps evenly
# spaced perceptually, which plain rgba() opacity steps do not. The result is
# emitted as sRGB hex so the widget never depends on CSS oklch() support.
RAMP_LIGHTNESS = [0.95, 0.86, 0.75, 0.62, 0.48]
RAMP_CHROMA = [0.025, 0.09, 0.13, 0.14, 0.12]


def _srgb_to_linear(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def _linear_to_srgb(c):
    return c * 12.92 if c <= 0.0031308 else 1.055 * (c ** (1 / 2.4)) - 0.055


def hex_to_hue_chroma(value):
    """OKLCH hue (degrees) and chroma of an #rrggbb colour."""
    v = value.lstrip("#")
    if len(v) == 3:
        v = "".join(ch * 2 for ch in v)
    r, g, b = (_srgb_to_linear(int(v[i : i + 2], 16) / 255) for i in (0, 2, 4))
    l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b) ** (1 / 3)
    m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b) ** (1 / 3)
    s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b) ** (1 / 3)
    a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
    bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    return math.degrees(math.atan2(bb, a)) % 360, math.hypot(a, bb)


def _oklch_to_rgb(lightness, chroma, hue):
    hr = math.radians(hue)
    a, b = chroma * math.cos(hr), chroma * math.sin(hr)
    l = (lightness + 0.3963377774 * a + 0.2158037573 * b) ** 3
    m = (lightness - 0.1055613458 * a - 0.0638541728 * b) ** 3
    s = (lightness - 0.0894841775 * a - 1.2914855480 * b) ** 3
    return (
        4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
    )


def oklch_to_hex(lightness, chroma, hue):
    low, high = 0.0, chroma
    for _ in range(24):  # binary-search the chroma back into sRGB gamut
        mid = (low + high) / 2
        if all(-1e-4 <= c <= 1 + 1e-4 for c in _oklch_to_rgb(lightness, mid, hue)):
            low = mid
        else:
            high = mid
    return "#" + "".join(
        "%02x" % round(min(1.0, max(0.0, _linear_to_srgb(c))) * 255)
        for c in _oklch_to_rgb(lightness, low, hue)
    )


def _ramp_for(accent):
    hue, chroma = hex_to_hue_chroma(accent)
    # A grey/black/white accent has no meaningful hue (atan2 of ~0,0 is noise),
    # so render it as an honestly neutral ramp instead of a random colour.
    saturation = 0.0 if chroma < 0.02 else 1.0
    return [
        oklch_to_hex(RAMP_LIGHTNESS[i], RAMP_CHROMA[i] * saturation, hue)
        for i in range(5)
    ]


def build_theme(cfg):
    theme = dict(cfg.get("theme") or {})
    accent = theme.get("accent") or "#9974f7"
    try:
        ramp = _ramp_for(accent)
    except (ValueError, IndexError):  # malformed accent – fall back to the brand colour
        accent = "#9974f7"
        ramp = _ramp_for(accent)
    # An explicit 5-colour ramp in the config wins over the generated one.
    custom = theme.get("ramp")
    if isinstance(custom, list) and len(custom) == 5:
        ramp = custom
    return {
        "accent": accent,
        "ramp": ramp,
        "showLegend": bool(theme.get("showLegend", True)),
        "cellSize": int(theme.get("cellSize", 22)),
    }


def load_config():
    with open(CONFIG_PATH) as f:
        cfg = json.load(f)
    cfg.setdefault("mode", "deny")
    cfg.setdefault("apps", {}).setdefault("allow", [])
    cfg["apps"].setdefault("deny", [])
    cfg.setdefault("sites", {}).setdefault("allow", [])
    cfg["sites"].setdefault("deny", [])
    cfg.setdefault("names", {})
    cfg.setdefault("theme", {})
    cfg.setdefault("minSeconds", 60)
    return cfg


def keeps(value, rules, mode):
    """Whether an app/site passes the filter."""
    if mode == "allow":
        return value in rules["allow"]
    return value not in rules["deny"]


def open_db():
    """Copy the DB aside before reading – it is usually WAL-locked by the OS."""
    tmpdir = tempfile.mkdtemp(prefix="knowledgec-")
    local = os.path.join(tmpdir, "knowledgeC.db")
    shutil.copy2(DB_PATH, local)
    for suffix in ("-wal", "-shm"):
        side = DB_PATH + suffix
        if os.path.exists(side):
            shutil.copy2(side, local + suffix)
    return sqlite3.connect(local), tmpdir


def display_name(value, stream, overrides):
    if value in overrides:
        return overrides[value]
    if stream == "/app/webUsage":
        return value.removeprefix("www.")
    # com.apple.Safari -> Safari
    return value.rsplit(".", 1)[-1] if "." in value else value


def split_by_day(start, end):
    """Yield (date, piece_start, piece_end), splitting intervals across local midnight."""
    while start < end:
        midnight = datetime(start.year, start.month, start.day) + timedelta(days=1)
        piece_end = min(end, midnight)
        yield start.date().isoformat(), start, piece_end
        start = piece_end


def merge(intervals):
    """Union of possibly overlapping (start, end) pairs – avoids double counting."""
    out = []
    for start, end in sorted(intervals):
        if out and start <= out[-1][1]:
            out[-1][1] = max(out[-1][1], end)
        else:
            out.append([start, end])
    return out


def subtract(intervals, holes):
    """Remove `holes` (e.g. screen-locked windows) from already-merged `intervals`."""
    holes = merge(holes)  # the sweep below relies on holes being sorted and disjoint
    result = []
    for start, end in intervals:
        cursor = start
        for hole_start, hole_end in holes:
            if hole_end <= cursor or hole_start >= end:
                continue
            if hole_start > cursor:
                result.append((cursor, hole_start))
            cursor = max(cursor, hole_end)
            if cursor >= end:
                break
        if cursor < end:
            result.append((cursor, end))
    return result


def intersect(a, b):
    """Overlap between two interval lists – e.g. a domain and its browser's foreground."""
    a, b = merge(a), merge(b)
    out = []
    i = j = 0
    while i < len(a) and j < len(b):
        start, end = max(a[i][0], b[j][0]), min(a[i][1], b[j][1])
        if start < end:
            out.append((start, end))
        if a[i][1] < b[j][1]:
            i += 1
        else:
            j += 1
    return out


def awake_duration(intervals, locked):
    """Seconds of activity that happened while the screen was actually unlocked."""
    return sum(e - s for s, e in subtract(merge(intervals), locked))



def share_overlap(per_domain):
    """Делит время, покрытое сразу несколькими доменами, поровну между ними.

    Развёртка по всем границам: каждый элементарный отрезок делится на число
    доменов, которые его покрывают. Какая вкладка была активной, база не
    сообщает, поэтому равное деление – осознанная догадка, но ограниченная:
    сумма долей равна реально прошедшему времени.
    """
    merged = {d: merge(iv) for d, iv in per_domain.items()}
    bounds = sorted({p for iv in merged.values() for s, e in iv for p in (s, e)})
    result = {d: 0.0 for d in per_domain}
    for i in range(len(bounds) - 1):
        start, end = bounds[i], bounds[i + 1]
        length = end - start
        if length <= 0:
            continue
        probe = start + length / 2
        covering = [d for d, iv in merged.items()
                    if any(s <= probe < e for s, e in iv)]
        if not covering:
            continue
        share = length / len(covering)
        for d in covering:
            result[d] += share
    return result


def collect(cfg):
    conn, tmpdir = open_db()
    try:
        cutoff_cd = (datetime.now() - timedelta(days=DAYS)).timestamp() - CORE_DATA_EPOCH
        # /app/webUsage carries the browser's bundle id in ZVALUESTRING; the actual
        # domain lives in the joined metadata row.
        rows = conn.execute(
            """
            SELECT o.ZSTREAMNAME, o.ZVALUESTRING,
                   m.Z_DKDIGITALHEALTHMETADATAKEY__WEBDOMAIN,
                   o.ZSTARTDATE, o.ZENDDATE
            FROM ZOBJECT o
            LEFT JOIN ZSTRUCTUREDMETADATA m ON o.ZSTRUCTUREDMETADATA = m.Z_PK
            WHERE o.ZSTREAMNAME IN ('/app/usage', '/app/webUsage')
              AND o.ZSTARTDATE >= ?
              AND o.ZVALUESTRING IS NOT NULL
              AND o.ZENDDATE > o.ZSTARTDATE
              AND (o.ZSOURCE IS NULL
                   OR (SELECT s.ZDEVICEID FROM ZSOURCE s WHERE s.Z_PK = o.ZSOURCE) IS NULL)
            """,
            (cutoff_cd,),
        ).fetchall()
        # Screen-locked windows, so overnight idling does not count as activity.
        locked_rows = conn.execute(
            """
            SELECT o.ZSTARTDATE, o.ZENDDATE FROM ZOBJECT o
            WHERE o.ZSTREAMNAME = '/device/isLocked'
              AND o.ZVALUEINTEGER = 1 AND o.ZSTARTDATE >= ? AND o.ZENDDATE > o.ZSTARTDATE
              AND (o.ZSOURCE IS NULL
                   OR (SELECT s.ZDEVICEID FROM ZSOURCE s WHERE s.Z_PK = o.ZSOURCE) IS NULL)
            """,
            (cutoff_cd,),
        ).fetchall()
    finally:
        conn.close()
        shutil.rmtree(tmpdir, ignore_errors=True)

    locked = defaultdict(list)
    for zstart, zend in locked_rows:
        start = datetime.fromtimestamp(zstart + CORE_DATA_EPOCH)
        end = datetime.fromtimestamp(zend + CORE_DATA_EPOCH)
        for day, piece_start, piece_end in split_by_day(start, end):
            locked[day].append((piece_start.timestamp(), piece_end.timestamp()))

    # Any bundle id that shows up in webUsage is a browser: it is represented in the
    # breakdown by its domains instead of by itself, so its time is not counted twice.
    browsers = {v for stream, v, _, _, _ in rows if stream == "/app/webUsage"}

    per_app = defaultdict(lambda: defaultdict(list))  # day -> name -> [(s, e)]
    # day -> browser -> domain -> [(s, e)]. Браузер нужен, чтобы домен
    # засчитывался только пока впереди был ЕГО браузер.
    per_web = defaultdict(lambda: defaultdict(lambda: defaultdict(list)))
    spans = defaultdict(list)  # day -> [(s, e)] for the overall daily total
    foreground = defaultdict(lambda: defaultdict(list))  # day -> browser -> [(s, e)]
    mode = cfg["mode"]

    for stream, value, domain, zstart, zend in rows:
        is_web = stream == "/app/webUsage"
        key = domain if is_web else value
        if key is None:
            continue
        if not keeps(key, cfg["sites"] if is_web else cfg["apps"], mode):
            continue

        start = datetime.fromtimestamp(zstart + CORE_DATA_EPOCH)
        end = datetime.fromtimestamp(zend + CORE_DATA_EPOCH)
        name = display_name(key, stream, cfg["names"])
        for day, piece_start, piece_end in split_by_day(start, end):
            piece = (piece_start.timestamp(), piece_end.timestamp())
            if is_web:
                per_web[day][value][name].append(piece)
                continue
            # Only foreground app usage defines the day's total; webUsage keeps
            # ticking for background tabs and would tile the whole day.
            spans[day].append(piece)
            if value in browsers:
                foreground[day][value].append(piece)
            else:
                per_app[day][name].append(piece)

    days = {}
    for day, intervals in spans.items():
        holes = merge(locked[day])
        total = awake_duration(intervals, holes)
        if total < cfg["minSeconds"]:
            continue
        scored = {n: awake_duration(iv, holes) for n, iv in per_app[day].items()}
        # A domain only counts while its browser was actually frontmost.
        # webUsage тикает для ВСЕХ открытых вкладок, поэтому одну и ту же
        # секунду могут заявить несколько доменов. Делим её поровну: какая
        # вкладка была видимой, в базе не записано, но так сумма по доменам
        # не превышает реального времени браузера.
        for browser, domains in per_web[day].items():
            browser_time = merge(foreground[day].get(browser, []))
            eligible = {
                d: subtract(intersect(iv, browser_time), holes)
                for d, iv in domains.items()
            }
            for domain, seconds in share_overlap(eligible).items():
                scored[domain] = scored.get(domain, 0.0) + seconds
        ranked = sorted(scored.items(), key=lambda kv: -kv[1])
        days[day] = {
            "t": round(total),
            "top": [[name, round(sec)] for name, sec in ranked[:3] if sec > 0],
        }
    return days


def merge_history(fresh):
    """macOS prunes knowledgeC.db after ~a week, so keep our own rolling history.

    Days still present in the DB always win (they may have grown since last run);
    older days survive from the previous activity.json until they age out of the grid.
    """
    horizon = (datetime.now() - timedelta(days=DAYS)).date().isoformat()
    try:
        with open(OUTPUT_PATH) as f:
            previous = json.load(f).get("days", {})
    except (OSError, ValueError):
        previous = {}
    kept = {d: v for d, v in previous.items() if d >= horizon}
    kept.update(fresh)
    return dict(sorted(kept.items()))


def main():
    ok = True
    try:
        cfg = load_config()
        payload = {
            "generated": datetime.now().isoformat(timespec="seconds"),
            "theme": build_theme(cfg),
            "days": merge_history(collect(cfg)),
        }
    except (PermissionError, FileNotFoundError, sqlite3.OperationalError) as exc:
        ok, payload = False, {"error": "no_access", "detail": str(exc)}
    except Exception as exc:  # surface anything else in the widget rather than a blank tile
        ok, payload = False, {"error": "failed", "detail": f"{type(exc).__name__}: {exc}"}

    # Never let a failed run overwrite activity.json – it is the only copy of the
    # history that macOS has already pruned from knowledgeC.db.
    if ok:
        try:
            tmp = OUTPUT_PATH + ".tmp"
            with open(tmp, "w") as f:
                f.write(json.dumps(payload))
            os.replace(tmp, OUTPUT_PATH)
        except OSError:
            pass
    sys.stdout.write(json.dumps(payload))


if __name__ == "__main__":
    main()
