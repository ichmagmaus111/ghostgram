#!/usr/bin/env python3 -I
"""Registration date by Telegram user ID: anchors -> monotone curve with an honest band -> Swift table.

    python3 -I Ghostgram/Features/RegDate/Data/generate.py            # fit, validate, write
    python3 -I Ghostgram/Features/RegDate/Data/generate.py --check    # fail if the Swift file is stale
    python3 -I Ghostgram/Features/RegDate/Data/generate.py --no-cv    # skip the slow validation

Reads   Data/anchors.csv            (one row per observation, see Data/README.md)
Writes  Sources/Estimate/GGRegDateAnchors.swift  (generated, do not edit by hand)
        Tests/GGRegDateEstimateFixture.swift     (what this model answers, for the host test)
        Data/validation.txt          (cross-validation, source comparison, outliers)

Standard library only. Deterministic: the same anchors give the same bytes.

The model (why each step is there is in Data/README.md):
  1. median curve: each date replaced by the weighted median of +-SMOOTH neighbours, then weighted
     L1 isotonic regression (pool-adjacent-violators with weighted medians) of the date on the ID,
     nodes at the block centres, linear in between;
  2. outliers: leave-one-out residual further than OUTLIER_MADS local MADs and OUTLIER_DAYS from
     the curve -> dropped, curve refitted (inside every training split, never on the test points);
  3. band: local BAND_LO / BAND_HI quantiles of the leave-one-out residuals over +-BAND_WINDOW
     neighbours, scaled so cross-validation lands at ~90 % in both regimes (BAND_SCALE before the
     2021 jump, BAND_SCALE_NEW after it), never narrower than MIN_HALF_DAYS, made monotone (least
     squares isotonic fit of each edge, then an envelope: low edge from the right, high from the left);
  4. near the top (within FRONT_SPAN of the newest ID) the high edge moves on with the clock once
     the data is old: accounts made after it still get IDs there (fully at the newest ID, not at
     all FRONT_SPAN below); at build time nothing changes;
  5. above the last node: the ID growth rate of the last RATE_DAYS of the curve extrapolates the
     point; the range runs from the last low edge (moved on at most MAX_RATE_FACTOR times that
     rate, never narrower than the last node's band) to `now`.
"""
import bisect
import csv
import math
import datetime as dt
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ANCHORS = os.path.join(HERE, "anchors.csv")
SWIFT = os.path.join(HERE, "..", "Sources", "Estimate", "GGRegDateAnchors.swift")
REPORT = os.path.join(HERE, "validation.txt")
FIXTURE = os.path.join(HERE, "..", "Tests", "GGRegDateEstimateFixture.swift")

# Bump with every change of the anchors or the model (GGRegDateResolver.dataVersion reads it).
DATA_VERSION = 1

DAY = 86400
LAUNCH = int(dt.datetime(2013, 8, 14, tzinfo=dt.timezone.utc).timestamp())  # Telegram for iOS, public

SMOOTH = 2
OUTLIER_MADS = 5.0
OUTLIER_DAYS = 120
BAND_WINDOW = 10
BAND_LO = 0.05
BAND_HI = 0.95
MIN_HALF_DAYS = 15
BAND_SCALE = 1.25
BAND_SCALE_NEW = 1.15
# IDs past the unused 2.26e9..5.0e9 range (from late 2021): many allocation fronts at once.
SCATTER_FROM_ID = 3_000_000_000
RATE_DAYS = 365
MAX_RATE_FACTOR = 2.0
# How far below the newest ID accounts made after the data still land (time split: up to ~0.4e9
# in 2024-2025; with 0.5e9, 98-100 % of the later accounts fall in range, Data/validation.txt).
FRONT_SPAN = 500_000_000
COMPRESS_DAYS = 1.0


# ----------------------------------------------------------------------------- data

def load():
    obs, months, uppers, derived = [], [], [], {}
    for r in csv.DictReader(open(ANCHORS, newline="")):
        uid, ts, kind, w = int(r["id"]), int(r["ts"]), r["kind"], float(r["weight"])
        if kind == "obs":
            obs.append(dict(id=uid, t=ts, w=w, lo=ts, hi=ts, src=r["sources"], kind=kind))
        elif kind == "month":
            y, m = map(int, r["date"].split("-"))
            end = month_start(y + (m == 12), 1 if m == 12 else m + 1) - 1
            months.append(dict(id=uid, t=(ts + end) // 2, w=1.0, lo=ts, hi=end, src=r["sources"], kind=kind))
        elif kind == "upper":
            uppers.append(dict(id=uid, t=ts, note=r["note"]))
        elif kind == "derived":
            derived.setdefault(r["sources"], []).append((uid, ts))
    return obs, months, uppers, derived


def month_start(y, m):
    return int(dt.datetime(y, m, 1, tzinfo=dt.timezone.utc).timestamp())


def iso(ts):
    return dt.datetime.fromtimestamp(ts, dt.timezone.utc).strftime("%Y-%m-%d")


# ----------------------------------------------------------------------------- model

def wmedian(pairs):
    """Weighted median of (value, weight) pairs, lower median on a tie."""
    pairs = sorted(pairs)
    total = sum(w for _, w in pairs)
    acc = 0.0
    for v, w in pairs:
        acc += w
        if acc >= total / 2:
            return v
    return pairs[-1][0]


def wquantile(pairs, q):
    pairs = sorted(pairs)
    total = sum(w for _, w in pairs)
    acc = 0.0
    for v, w in pairs:
        acc += w
        if acc >= total * q - 1e-9:
            return v
    return pairs[-1][0]


def smoothed(pts):
    """Each date replaced by the weighted median over +-SMOOTH neighbours (by ID rank)."""
    if SMOOTH <= 0:
        return pts
    out = []
    n = len(pts)
    for i, p in enumerate(pts):
        lo, hi = max(0, i - SMOOTH), min(n, i + SMOOTH + 1)
        q = dict(p)
        q["t"] = wmedian([(pts[j]["t"], pts[j]["w"]) for j in range(lo, hi)])
        out.append(q)
    return out


def median_curve(pts):
    """L1 isotonic regression. pts sorted by id. Returns nodes [(id, t)] with strictly growing ids."""
    pts = smoothed(pts)
    blocks = []  # [values [(t, w)], idsum, wsum, value]
    for p in pts:
        b = [[(p["t"], p["w"])], p["id"] * p["w"], p["w"], p["t"]]
        blocks.append(b)
        while len(blocks) > 1 and blocks[-2][3] > blocks[-1][3]:
            b2 = blocks.pop()
            b1 = blocks.pop()
            vals = b1[0] + b2[0]
            blocks.append([vals, b1[1] + b2[1], b1[2] + b2[2], wmedian(vals)])
    nodes = []
    for vals, idsum, wsum, value in blocks:
        cid = idsum / wsum
        if nodes and cid <= nodes[-1][0]:
            pid, pt = nodes[-1]
            nodes[-1] = (pid, max(pt, value))
            continue
        nodes.append((cid, value))
    return nodes


def isotonic_l2(values):
    """Non-decreasing least-squares fit (pool adjacent violators, equal weights)."""
    blocks = []  # [sum, count]
    for v in values:
        blocks.append([v, 1])
        while len(blocks) > 1 and blocks[-2][0] / blocks[-2][1] > blocks[-1][0] / blocks[-1][1]:
            s2, c2 = blocks.pop()
            blocks[-1][0] += s2
            blocks[-1][1] += c2
    out = []
    for total, count in blocks:
        out.extend([total / count] * count)
    return out


def interp(nodes, x):
    """Piecewise linear through nodes, flat outside (callers handle the ends themselves)."""
    xs = [n[0] for n in nodes]
    i = bisect.bisect_right(xs, x)
    if i == 0:
        return nodes[0][1]
    if i == len(nodes):
        return nodes[-1][1]
    (x0, y0), (x1, y1) = nodes[i - 1], nodes[i]
    return y0 + (y1 - y0) * (x - x0) / (x1 - x0)


def loo_residuals(pts):
    res = []
    for i in range(len(pts)):
        rest = pts[:i] + pts[i + 1:]
        if not rest:
            res.append(0.0)
            continue
        res.append(pts[i]["t"] - interp(median_curve(rest), pts[i]["id"]))
    return res


def drop_outliers(pts):
    """One pass: leave-one-out residuals against the local spread."""
    res = loo_residuals(pts)
    keep, dropped = [], []
    for i, p in enumerate(pts):
        lo, hi = max(0, i - BAND_WINDOW), min(len(pts), i + BAND_WINDOW + 1)
        local = sorted(abs(res[j]) for j in range(lo, hi) if j != i)
        mad = local[len(local) // 2] if local else 0.0
        if abs(res[i]) > max(OUTLIER_MADS * mad, OUTLIER_DAYS * DAY):
            dropped.append((p, res[i]))
        else:
            keep.append(p)
    return keep, dropped


class Model:
    def __init__(self, pts):
        pts = sorted(pts, key=lambda p: (p["id"], p["t"]))
        self.kept, self.dropped = drop_outliers(pts)
        kept = self.kept
        self.curve = median_curve(kept)
        res = loo_residuals(kept)
        n = len(kept)
        rows = []
        for i, p in enumerate(kept):
            lo_i, hi_i = max(0, i - BAND_WINDOW), min(n, i + BAND_WINDOW + 1)
            window = [(res[j], kept[j]["w"]) for j in range(lo_i, hi_i)]
            scale = BAND_SCALE if p["id"] < SCATTER_FROM_ID else BAND_SCALE_NEW
            qlo = min(wquantile(window, BAND_LO) * scale, -MIN_HALF_DAYS * DAY)
            qhi = max(wquantile(window, BAND_HI) * scale, MIN_HALF_DAYS * DAY)
            mid = interp(self.curve, p["id"])
            rows.append([p["id"], mid, mid + qlo, mid + qhi])
        # one row per distinct id
        merged = []
        for r in rows:
            if merged and r[0] == merged[-1][0]:
                m = merged[-1]
                m[2] = min(m[2], r[2])
                m[3] = max(m[3], r[3])
            else:
                merged.append(r)
        # monotone edges: a least-squares isotonic fit of each edge averages a lone wide spot with
        # its neighbours instead of copying it over the whole older (or newer) part of the curve
        for k in (2, 3):
            fitted = isotonic_l2([r[k] for r in merged])
            for r, v in zip(merged, fitted):
                r[k] = v
        for r in merged:
            r[2] = min(r[2], r[1] - MIN_HALF_DAYS * DAY)
            r[3] = max(r[3], r[1] + MIN_HALF_DAYS * DAY)
        # the clamps above may break monotonicity a little: an envelope repairs it
        for i in range(len(merged) - 2, -1, -1):
            merged[i][2] = min(merged[i][2], merged[i + 1][2])
        for i in range(1, len(merged)):
            merged[i][3] = max(merged[i][3], merged[i - 1][3])
        for r in merged:
            r[1] = max(r[1], LAUNCH)
            r[2] = max(min(r[2], r[1]), LAUNCH)
            r[3] = max(r[3], r[1])
        # the launch node: nothing is older than Telegram itself
        first = merged[0]
        self.data_end = max(p["hi"] for p in kept)
        self.use_nodes([[0, LAUNCH, LAUNCH, first[3]]] + merged if first[0] > 0 else merged)

    def use_nodes(self, nodes):
        self.nodes = nodes
        last = self.nodes[-1]
        self.last_id, self.last_mid, self.last_lo, self.last_hi = last[0], last[1], last[2], last[3]
        # ID growth over the last RATE_DAYS of the curve
        target = self.last_mid - RATE_DAYS * DAY
        j = len(self.nodes) - 1
        while j > 0 and self.nodes[j][1] > target:
            j -= 1
        span_t = self.last_mid - self.nodes[j][1]
        span_x = self.last_id - self.nodes[j][0]
        self.rate = span_x / span_t if span_t > 0 and span_x > 0 else 1.0

    def predict(self, x, now):
        """(point, lo, hi) like the Swift code, before any evidence."""
        nodes = self.nodes
        if x >= self.last_id:
            now = max(now, self.data_end)
            point = self.last_mid + (x - self.last_id) / self.rate
            point = min(max(point, self.last_mid), now)
            # From below: the last low edge, moved on only as fast as IDs could at most have grown
            # (MAX_RATE_FACTOR x the last year), never past the point, and never so far that the
            # range gets narrower than the last node's band.
            band = self.last_hi - self.last_lo
            lo = self.last_lo + (x - self.last_id) / (self.rate * MAX_RATE_FACTOR)
            lo = max(self.last_lo, min(lo, point, max(now - band, self.last_lo)))
            return point, max(lo, LAUNCH), now
        xs = [n[0] for n in nodes]
        i = bisect.bisect_right(xs, x)
        a, b = nodes[i - 1], nodes[i]
        f = (x - a[0]) / (b[0] - a[0])
        point, lo, hi = (a[k] + (b[k] - a[k]) * f for k in (1, 2, 3))
        now = max(now, self.data_end)
        # Near the top of the table new accounts keep getting IDs after the data ends: the high
        # edge there moves on with the clock, fully at the newest ID, not at all FRONT_SPAN below.
        d = self.last_id - x
        if d < FRONT_SPAN and now > self.data_end:
            hi = hi + (now - self.data_end) * (1 - d / FRONT_SPAN)
        hi = min(hi, now)
        point = min(point, hi)
        lo = min(lo, point)
        return point, lo, hi


def compress(nodes, tol):
    """Drop nodes that linear interpolation of their neighbours reproduces within tol (all three)."""
    out = [nodes[0]]
    i = 1
    while i < len(nodes) - 1:
        # try to extend the segment from out[-1] as far as possible
        j = i + 1
        while j < len(nodes):
            a, b = out[-1], nodes[j]
            ok = True
            for k in range(i, j):
                f = (nodes[k][0] - a[0]) / (b[0] - a[0])
                for c in (1, 2, 3):
                    if abs(a[c] + (b[c] - a[c]) * f - nodes[k][c]) > tol:
                        ok = False
                        break
                if not ok:
                    break
            if not ok:
                break
            j += 1
        out.append(nodes[j - 1])
        i = j
    if out[-1] is not nodes[-1]:
        out.append(nodes[-1])
    return out


# ----------------------------------------------------------------------------- validation

def score(p, pred):
    point, lo, hi = pred
    if point < p["lo"]:
        err = p["lo"] - point
    elif point > p["hi"]:
        err = point - p["hi"]
    else:
        err = 0.0
    hit = lo <= (p["lo"] + p["hi"]) / 2 <= hi
    return err / DAY, hit, (hi - lo) / DAY


def summarize(rows):
    if not rows:
        return "n=0"
    errs = sorted(r[0] for r in rows)
    hits = sum(1 for r in rows if r[1])
    widths = sorted(r[2] for r in rows)

    def q(a, f):
        return a[min(len(a) - 1, int(f * len(a)))]
    return (f"n={len(rows):4d}  med={q(errs, 0.5):6.1f} d  p80={q(errs, 0.8):6.1f} d  "
            f"p90={q(errs, 0.9):6.1f} d  in range={100 * hits / len(rows):5.1f}%  "
            f"width med={q(widths, 0.5):6.0f} d")


def era(ts):
    y = int(iso(ts)[:4])
    if y <= 2014:
        return "2013-14"
    return str(y)


def cross_validate(pts, folds=10, repeats=3, now=None):
    out = []
    for seed in range(repeats):
        rnd = random.Random(1000 + seed)
        idx = list(range(len(pts)))
        rnd.shuffle(idx)
        for f in range(folds):
            test = set(idx[f::folds])
            train = [pts[i] for i in range(len(pts)) if i not in test]
            model = Model(train)
            for i in test:
                p = pts[i]
                out.append((p, score(p, model.predict(p["id"], now))))
    return out


def lineage(src):
    s = set(src.split(";"))
    if s & {"getids", "lastochkin", "tdage"}:
        return "classic (getids 2019+)"
    if s & {"jobians", "wizardloop", "jobians-extra"}:
        return "jobians (signup notices)"
    if s & {"exteraless", "aayco"}:
        return "exteraless/aayco assets"
    return "sepiol-k only"


# ----------------------------------------------------------------------------- swift

def swift_array(name, typ, values, per_line):
    lines = []
    for i in range(0, len(values), per_line):
        lines.append("        " + ", ".join(str(v) for v in values[i:i + per_line]) + ",")
    return f"    static let {name}: [{typ}] = [\n" + "\n".join(lines) + "\n    ]\n"


def write_text(path, text, check):
    name = os.path.basename(path)
    old = open(path).read() if os.path.exists(path) else None
    if check:
        if old != text:
            print(f"{name} is stale: run generate.py")
            sys.exit(1)
        print(f"{name} is up to date")
        return
    if old != text:
        with open(path, "w") as f:
            f.write(text)
        print("wrote", os.path.relpath(path, os.path.join(HERE, "..")))


def swift_anchors(model, n_points, n_sources):
    nodes = model.nodes
    ids = [n[0] for n in nodes]
    for a, b in zip(ids, ids[1:]):
        assert b > a, "node ids must grow"
    for a, b in zip(nodes, nodes[1:]):
        assert b[1] >= a[1] and b[2] >= a[2] and b[3] >= a[3], "curve and edges must be monotone"
    for n in nodes:
        assert LAUNCH <= n[2] <= n[1] <= n[3] < 2**31, "low <= point <= high, all after the launch"
    return (
        "// Generated by Ghostgram/Features/RegDate/Data/generate.py from Data/anchors.csv — do not edit.\n"
        f"// {n_points} observations from {n_sources} public sources, {len(ids)} nodes; "
        "see Data/README.md and Data/validation.txt.\n"
        "\n"
        "// Unix seconds, UTC. Node i: an account with ID ids[i] was most likely created at points[i],\n"
        "// and lows[i]...highs[i] is the range the validation found honest for that part of the curve.\n"
        "// Linear between nodes. Above the last node the point follows `idsPerSecond` and the range\n"
        "// runs from the shifted low edge to `now` (GGRegDateResolver).\n"
        "enum GGRegDateAnchors {\n"
        f"    static let dataVersion: Int = {DATA_VERSION}\n"
        "    /// Telegram for iOS went public; nothing is older.\n"
        f"    static let launch: Int64 = {LAUNCH}\n"
        "    /// The newest moment the anchors describe: a device clock behind it is wrong.\n"
        f"    static let dataEnd: Int64 = {int(model.data_end)}\n"
        f"    /// ID growth of the last {RATE_DAYS} days of the curve.\n"
        f"    static let idsPerSecond: Double = {model.rate:.6f}\n"
        "    /// Above the last node the low edge moves at most this many times faster than that.\n"
        f"    static let maxRateFactor: Double = {MAX_RATE_FACTOR}\n"
        "    /// Accounts made after the data still land up to this far below the newest ID.\n"
        f"    static let frontSpan: Double = {float(FRONT_SPAN)}\n"
        "\n"
        + swift_array("ids", "Int64", ids, 6)
        + "\n"
        + swift_array("points", "Int32", [n[1] for n in nodes], 8)
        + "\n"
        + swift_array("lows", "Int32", [n[2] for n in nodes], 8)
        + "\n"
        + swift_array("highs", "Int32", [n[3] for n in nodes], 8)
        + "}\n"
    )


def fixture_ids(model):
    """Deterministic probe IDs: log-spaced over the whole table plus a few past its end."""
    lo, hi = 5.0, math.log10(model.last_id * 1.08)
    ids = sorted({int(round(10 ** (lo + (hi - lo) * k / 199))) for k in range(200)})
    return ids


def swift_fixture(model, pts):
    now = int(model.data_end)
    probe = fixture_ids(model)
    preds = [model.predict(x, now) for x in probe]
    obs = sorted(pts, key=lambda p: (p["id"], p["t"]))
    return (
        "// Generated by Ghostgram/Features/RegDate/Data/generate.py — do not edit.\n"
        "// What generate.py's model answers for fixed IDs (now = GGRegDateAnchors.dataEnd), and every\n"
        "// observation it was fitted on: the host test checks that the Swift resolver is the same\n"
        "// function and measures its in-sample coverage.\n"
        "enum GGRegDateEstimateFixture {\n"
        f"    static let dataVersion: Int = {DATA_VERSION}\n"
        + swift_array("probeIds", "Int64", probe, 6)
        + swift_array("probePoints", "Int64", [int(round(p[0])) for p in preds], 8)
        + swift_array("probeLows", "Int64", [int(round(p[1])) for p in preds], 8)
        + swift_array("probeHighs", "Int64", [int(round(p[2])) for p in preds], 8)
        + swift_array("observedIds", "Int64", [p["id"] for p in obs], 6)
        + swift_array("observedFrom", "Int64", [p["lo"] for p in obs], 8)
        + swift_array("observedTo", "Int64", [p["hi"] for p in obs], 8)
        + "}\n"
    )


# ----------------------------------------------------------------------------- main

def main():
    check = "--check" in sys.argv
    no_cv = "--no-cv" in sys.argv or check
    obs, months, uppers, derived = load()
    pts = obs + months
    sources = set()
    for p in pts:
        sources |= set(p["src"].split(";"))
    model = Model(pts)
    full_nodes = len(model.nodes)
    model.use_nodes([[int(round(v)) for v in n] for n in compress(model.nodes, COMPRESS_DAYS * DAY)])
    write_text(SWIFT, swift_anchors(model, len(pts), len(sources)), check)
    write_text(FIXTURE, swift_fixture(model, pts), check)
    if no_cv:
        return

    now = model.data_end
    rep = []
    w = rep.append
    w(f"generate.py, data version {DATA_VERSION}")
    w(f"points: {len(obs)} dated + {len(months)} months (fit), {len(uppers)} existed-by bounds, "
      f"derived tables: {', '.join(f'{k} {len(v)}' for k, v in sorted(derived.items()))}")
    w(f"sources in the fit: {', '.join(sorted(sources))}")
    w(f"curve: {full_nodes} nodes, {len(model.nodes)} after compression (tolerance {COMPRESS_DAYS} d); "
      f"last node ID {int(model.last_id)} at {iso(model.last_mid)}; growth {model.rate * DAY / 1e6:.2f} M IDs/day")
    w("")
    w("== outliers dropped from the final fit (leave-one-out residual)")
    for p, r in model.dropped:
        w(f"  {p['id']:>11d} {iso(p['t'])} {p['kind']:5s} residual {r / DAY:+7.0f} d  [{p['src']}]")
    w("")

    cv = cross_validate(pts, now=now)
    w("== 10-fold cross-validation x3 (outliers removed inside each training split only)")
    w("   error = |point - date| (0 inside a month label); in range = the date (mid-month) is inside")
    w("   the range the model gave for that ID")
    w("all      " + summarize([s for _, s in cv]))
    eras = sorted({era(p["t"]) for p, _ in cv})
    for e in eras:
        w(f"{e:8s} " + summarize([s for p, s in cv if era(p["t"]) == e]))
    w("months   " + summarize([s for p, s in cv if p["kind"] == "month"]))
    w("")

    w("== leave-lineage-out: fit without one lineage, score its points (source comparison)")
    lineages = sorted({lineage(p["src"]) for p in pts})
    for ln in lineages:
        test = [p for p in pts if lineage(p["src"]) == ln]
        train = [p for p in pts if lineage(p["src"]) != ln]
        m = Model(train)
        sc = [(p, score(p, m.predict(p["id"], now))) for p in test]
        w(f"{ln:26s} " + summarize([s for _, s in sc]))
        for e in eras:
            sub = [s for p, s in sc if era(p["t"]) == e]
            if sub:
                bias = sorted((p["t"] - m.predict(p["id"], now)[0]) / DAY for p, _ in sc if era(p["t"]) == e)
                w(f"    {e:8s} " + summarize(sub) + f"  bias med {bias[len(bias) // 2]:+6.0f} d")
    w("")

    w("== other estimators scored on the same observations (their own interpolation, not held out:")
    w("   sepiol-fit and nagram were fitted on most of these points, tgidmcp was not)")
    for name, table in sorted(derived.items()):
        table = sorted(set(table))
        tnodes = []
        for x, t in table:
            if tnodes and x == tnodes[-1][0]:
                continue
            tnodes.append((x, t))
        rows = []
        for p in pts:
            if p["id"] < tnodes[0][0] or p["id"] > tnodes[-1][0]:
                continue
            point = interp(tnodes, p["id"])
            rows.append((p, score(p, (point, point, point))))
        w(f"{name:12s} " + summarize([s for _, s in rows]).split("  in range")[0])
        for e in eras:
            sub = [s for p, s in rows if era(p["t"]) == e]
            if sub:
                w(f"    {e:8s} " + summarize(sub).split("  in range")[0])
    w("")

    w("== time split: fit on everything dated before a cutoff, score what came after")
    for cutoff in ("2024-01-01", "2025-01-01", "2025-07-01", "2026-01-01"):
        c = int(dt.datetime.strptime(cutoff, "%Y-%m-%d").replace(tzinfo=dt.timezone.utc).timestamp())
        train = [p for p in pts if p["hi"] < c]
        test = [p for p in pts if p["lo"] >= c]
        if len(train) < 20 or not test:
            continue
        m = Model(train)
        sc = [score(p, m.predict(p["id"], now)) for p in test]
        above = sum(1 for p in test if p["id"] >= m.last_id)
        w(f"cutoff {cutoff}: {above:3d}/{len(test):3d} test IDs above the last node   " + summarize(sc))
    w("")

    w("== what the profile row gets from the table alone (final model at every observed ID)")
    w("   precision: month if the range is <= 183 d wide, year otherwise (GGRegDateResolver)")
    for e in eras + ["all"]:
        sub = [p for p in pts if e == "all" or era(p["t"]) == e]
        widths = sorted((lambda r: (r[2] - r[1]) / DAY)(model.predict(p["id"], now)) for p in sub)
        month = sum(1 for x in widths if x <= 183)
        w(f"    {e:8s} n={len(sub):4d}  month {100 * month / len(sub):5.1f}%  year {100 - 100 * month / len(sub):5.1f}%  "
          f"width med {widths[len(widths) // 2]:4.0f} d  p90 {widths[int(len(widths) * 0.9)]:4.0f} d")
    w("")

    w("== existed-by bounds: the range must start no later than the bound")
    for u in uppers:
        point, lo, hi = model.predict(u["id"], now)
        ok = "ok " if lo <= u["t"] else "BAD"
        w(f"  {ok} {u['id']:>11d} existed by {iso(u['t'])}: range {iso(lo)}..{iso(hi)}, point {iso(point)}")
    w("")

    w("== monotonicity of the inputs: adjacent observations (by ID) whose dates go back")
    srt = sorted(obs, key=lambda p: p["id"])
    for lim in (30, 90, 180):
        n = sum(1 for a, b in zip(srt, srt[1:]) if b["t"] < a["t"] - lim * DAY)
        w(f"  more than {lim:3d} d back: {n} of {len(srt) - 1} pairs")
    for e in eras:
        sub = [p for p in srt if era(p["t"]) == e]
        n = sum(1 for a, b in zip(sub, sub[1:]) if b["t"] < a["t"] - 30 * DAY)
        w(f"    {e:8s} {n:3d} of {max(0, len(sub) - 1)} pairs back by > 30 d")

    text = "\n".join(rep) + "\n"
    with open(REPORT, "w") as f:
        f.write(text)
    print(text)


if __name__ == "__main__":
    main()
