#!/usr/bin/env python3 -I
"""Step 2 of the import: collected.csv (every row of every table) -> Data/anchors.csv (one row per observation).

Usage: python3 -I build_anchors.py <collected.csv> <anchors.csv>

Copies of one observation across tables are merged (same ID or an ID a few units away, dates within
3 days) and keep the list of every table that carries them. Everything else is decided here and
written down in the `note` column, so the generator never has to guess.
"""
import csv
import datetime as dt
import sys
from collections import defaultdict

SRC, OUT = sys.argv[1], sys.argv[2]

OBS_SOURCES = ["jobians", "jobians-extra", "wizardloop", "getids", "lastochkin", "tdage",
               "exteraless", "aayco", "sepiol-k"]
DERIVED = ["sepiol-fit", "tgidmcp", "nagram"]
# Synthetic rows: IDs inside the 2.26e9..5.0e9 range no user ever got, same "…845111" tail, dates
# that contradict everything around them (2021-04 / 2021-05 for IDs past 2.1e9).
SYNTHETIC = {3318845111, 4317845111}
DAY = 86400

rows = list(csv.DictReader(open(SRC)))
for r in rows:
    r["id"] = int(r["id"])
    r["ts"] = int(r["ts"])

in_other = defaultdict(set)
for r in rows:
    in_other[r["id"]].add(r["source"])


def iso(ts):
    return dt.datetime.fromtimestamp(ts, dt.timezone.utc).strftime("%Y-%m-%d")


out = []

# 1. Derived tables (model outputs): kept for comparison only.
for r in rows:
    if r["source"] in DERIVED:
        out.append(dict(id=r["id"], ts=r["ts"], date=iso(r["ts"]), kind="derived", weight=0,
                        sources=r["source"], note="model output, comparison only"))

# 2. Observations: classify, then merge copies.
obs = []
for r in rows:
    if r["source"] not in OBS_SOURCES:
        continue
    note = []
    kind = "obs"
    weight = 1.0
    uid, ts = r["id"], r["ts"]
    if uid <= 1:
        kind, weight = "rejected", 0
        note.append("sentinel ID (0 = Telegram launch marker), not an account")
    elif uid in SYNTHETIC:
        kind, weight = "rejected", 0
        note.append("synthetic: inside the 2.26e9..5.0e9 range no user got, contradicts neighbours")
    elif r["source"] == "sepiol-k" and in_other[uid] <= {"sepiol-k", "sepiol-fit"}:
        t = dt.datetime.fromtimestamp(ts, dt.timezone.utc)
        if (t.day, t.hour, t.minute, t.second) == (16, 0, 0, 0):
            kind = "month"
            ts = int(dt.datetime(t.year, t.month, 1, tzinfo=dt.timezone.utc).timestamp())
            note.append("month label stored as the 16th 00:00 (research keeps registration_month as points)")
        elif dt.datetime(2026, 10, 9, tzinfo=dt.timezone.utc) <= t < dt.datetime(2026, 10, 11, tzinfo=dt.timezone.utc):
            kind, weight = "upper", 0
            note.append("one of six IDs 8.66e9..8.89e9 dated within 26 h before publication: "
                        "session times, existed-by bound only")
    if kind in ("obs", "month") and uid >= 10**8 and uid % 100000 == 0:
        weight = 0.5
        note.append("rounded ID")
    elif kind in ("obs", "month") and uid >= 10**8 and uid % 100 == 0 and r["source"] == "getids":
        weight = 0.8
        note.append("ID rounded to 100 by the table author (2026 additions)")
    obs.append(dict(id=uid, ts=ts, kind=kind, weight=weight, source=r["source"], note=note))

obs.sort(key=lambda o: (o["id"], o["ts"]))
merged = []
for o in obs:
    hit = None
    for m in reversed(merged[-8:]):
        if (m["kind"] == o["kind"] and abs(m["id"] - o["id"]) <= 10
                and min(abs(t - o["ts"]) for t in m["tss"]) <= 3 * DAY):
            hit = m
            break
    if hit:
        hit["sources"].add(o["source"])
        hit["ids"].add(o["id"])
        hit["tss"].append(o["ts"])
        hit["weight"] = max(hit["weight"], o["weight"])
        for n in o["note"]:
            if n not in hit["note"]:
                hit["note"].append(n)
    else:
        merged.append(dict(id=o["id"], ids={o["id"]}, tss=[o["ts"]], kind=o["kind"], weight=o["weight"],
                           sources={o["source"]}, note=list(o["note"])))

# Near-identical IDs (<= 10 apart) with dates further apart than 3 days cannot both be right.
for i, m in enumerate(merged):
    for n in merged[i + 1:i + 6]:
        if n["kind"] == m["kind"] == "obs" and abs(n["id"] - m["id"]) <= 10:
            d = abs(sorted(n["tss"])[len(n["tss"]) // 2] - sorted(m["tss"])[len(m["tss"]) // 2]) / DAY
            for a, b in ((m, n), (n, m)):
                a["weight"] = min(a["weight"], 0.5)
                a["note"].append(f"conflict: ID {b['id']} ({'/'.join(sorted(b['sources']))}) "
                                 f"is {abs(b['id'] - a['id'])} away and {d:.0f} d off")

for m in merged:
    tss = sorted(m["tss"])
    ts = tss[len(tss) // 2]
    if len(set(tss)) > 1:
        m["note"].append(f"copies differ by up to {(tss[-1] - tss[0]) / 3600:.0f} h")
    if len(m["ids"]) > 1:
        m["note"].append("copies carry IDs " + "/".join(str(x) for x in sorted(m["ids"])))
    date = iso(ts)[:7] if m["kind"] == "month" else iso(ts)
    out.append(dict(id=m["id"], ts=ts, date=date, kind=m["kind"], weight=m["weight"],
                    sources=";".join(sorted(m["sources"])), note="; ".join(m["note"])))

# 3. Existed-by bounds with documented dates (service bots; IDs from python-telegram-bot constants
# and Telegram-iOS PeerUtils.swift, dates from the Telegram blog).
BOUNDS = [
    (93372553, "2015-06-24", "@BotFather: the bot platform launched 2015-06-24 (telegram.org/blog/bot-revolution)"),
    (1087968824, "2020-09-30", "@GroupAnonymousBot: anonymous admins launched 2020-09-30 "
                               "(telegram.org/blog/filters-anonymous-admins-comments); ID: PTB constants.ANONYMOUS_ADMIN"),
    (1271266957, "2020-09-30", "@replies: channel comments launched 2020-09-30 (same post); "
                               "ID: Telegram-iOS PeerUtils.isReplies"),
]
for uid, d, n in BOUNDS:
    ts = int(dt.datetime.strptime(d, "%Y-%m-%d").replace(tzinfo=dt.timezone.utc).timestamp())
    out.append(dict(id=uid, ts=ts, date=d, kind="upper", weight=0, sources="manual", note=n))

order = {"obs": 0, "month": 1, "upper": 2, "rejected": 3, "derived": 4}
out.sort(key=lambda r: (order[r["kind"]], r["id"], r["ts"]))
with open(OUT, "w", newline="") as f:
    w = csv.writer(f, lineterminator="\n")
    w.writerow(["id", "ts", "date", "kind", "weight", "sources", "note"])
    for r in out:
        w.writerow([r["id"], r["ts"], r["date"], r["kind"], r["weight"], r["sources"], r["note"]])

from collections import Counter
print(Counter(r["kind"] for r in out))
