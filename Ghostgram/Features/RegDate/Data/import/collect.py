#!/usr/bin/env python3 -I
"""Step 1 of the import (run once per data update, by hand): every downloaded public table -> one CSV.

Usage: python3 -I collect.py <download dir> <collected.csv>
Columns: source,id,ts,granularity,raw

The download dir holds one fresh clone per source, at the commits listed in ../README.md, under
the folder names used below (dl-<owner>_<repo>/repo, dl-exteraless/repo, dl-ls-NextAlone_Nagram/repo).
Everything downloaded is untrusted: files are parsed as JSON / text / Python literals
(ast.literal_eval), nothing from them is ever executed. Run with python3 -I, from another directory.
Step 2: build_anchors.py collected.csv ../anchors.csv. Then ../generate.py.
"""
import ast
import csv
import datetime as dt
import json
import re
import sys

S = sys.argv[1]
OUT = sys.argv[2]
rows = []


def day_ts(s):
    d = dt.datetime.strptime(s, "%Y-%m-%d").replace(tzinfo=dt.timezone.utc)
    return int(d.timestamp())


def month_ts(s):
    d = dt.datetime.strptime(s, "%Y-%m").replace(tzinfo=dt.timezone.utc)
    return int(d.timestamp())


def add(source, uid, ts, gran, raw):
    rows.append((source, int(uid), int(ts), gran, str(raw)))


# Jobians/telegram-id-age (MIT): [{"id": "...", "date": "YYYY-MM-DD"}]
for e in json.load(open(S + "/dl-jobians_telegram-id-age/repo/dataset.json")):
    add("jobians", e["id"], day_ts(e["date"]), "day", e["date"])
for e in json.load(open(S + "/dl-jobians_telegram-id-age/repo/examples/extra-dataset.json")):
    add("jobians-extra", e["id"], day_ts(e["date"]), "day", e["date"])

# wjclub/telegram-bot-getids (MIT): {"id": ms}
for k, v in json.load(open(S + "/dl-wjclub_telegram-bot-getids/repo/src/ages.json")).items():
    add("getids", k, v // 1000, "sec", v)

# lastochkin-group (no licence file): {"id": ms}
for k, v in json.load(open(S + "/dl-lastochkin-group_telegram-account-age-estimator/repo/ages.json")).items():
    add("lastochkin", k, v // 1000, "sec", v)

# go-tdage/tdage (MIT): Go map literal
txt = open(S + "/dl-go-tdage_tdage/repo/ages.go").read()
for m in re.finditer(r"^\s*(\d+)\s*:\s*(\d+)\s*,", txt, re.M):
    add("tdage", m.group(1), int(m.group(2)) // 1000, "sec", m.group(2))

# WizardLoop/CreationDate (MIT): [[id, "YYYY-MM-DD"]]
for uid, d in json.load(open(S + "/dl-WizardLoop_CreationDate/repo/data/tg_points.json")):
    add("wizardloop", uid, day_ts(d), "day", d)

# exteraless (GPL-3.0): {"data": [{"id", "date"}]}
for e in json.load(open(S + "/dl-exteraless/repo/TMessagesProj/src/main/assets/id_date.json"))["data"]:
    add("exteraless", e["id"], e["date"], "sec", e["date"])

# NextAlone/Nagram (GPL-3.0), same asset name, a different edit of the same lineage
for e in json.load(open(S + "/dl-ls-NextAlone_Nagram/repo/TMessagesProj/src/main/assets/id_date.json"))["data"]:
    add("nagram", e["id"], e["date"], "sec", e["date"])

# Aayco/Creation (no licence): ids = [(id, ts), ...] in create.py, parsed as a literal, never run
txt = open(S + "/dl-Aayco_Creation/repo/create.py").read()
m = re.search(r"^ids\s*=\s*(\[.*?\])\s*$", txt, re.S | re.M)
for uid, ts in ast.literal_eval(m.group(1)):
    add("aayco", uid, ts, "sec", ts)

# sepiol026-wq/telegram-id-age-research (AGPL-3.0): A = fitted breakpoints (model output),
# K = per-ID inputs (lookup table). Parsed as literals, never run.
txt = open(S + "/dl-sepiol026-wq_telegram-id-age-research/repo/main.py").read()
for name, src in (("A", "sepiol-fit"), ("K", "sepiol-k")):
    m = re.search(r"^" + name + r"=(.*)$", txt, re.M)
    val = ast.literal_eval(m.group(1))
    items = val.items() if isinstance(val, dict) else val
    for uid, ts in items:
        add(src, uid, ts, "sec", ts)

# barkoszloy/tg-id-mcp (MIT): (id, "YYYY-MM") rounded table
txt = open(S + "/dl-barkoszloy_tg-id-mcp/repo/src/tg_id_mcp/server.py").read()
for m in re.finditer(r"\((\d+),\s*\"(\d{4}-\d{2})\"\)", txt):
    add("tgidmcp", m.group(1), month_ts(m.group(2)), "month", m.group(2))

with open(OUT, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["source", "id", "ts", "granularity", "raw"])
    for r in rows:
        w.writerow(r)

from collections import Counter
c = Counter(r[0] for r in rows)
for k, v in sorted(c.items()):
    ids = [r[1] for r in rows if r[0] == k]
    tss = [r[2] for r in rows if r[0] == k]
    print(f"{k:14s} {v:5d}  id {min(ids)}..{max(ids)}  "
          f"{dt.datetime.fromtimestamp(min(tss), dt.timezone.utc):%Y-%m-%d}.."
          f"{dt.datetime.fromtimestamp(max(tss), dt.timezone.utc):%Y-%m-%d}")
