#!/usr/bin/env python3
"""Merges the replay CSVs of the history scan (reports/hist/{unlimited,real95}_NN.csv) into one table.
Usage: python3 script/history_report.py reports/hist data/history_meta.json"""
import csv, glob, json, sys

def load(d, leg):
    rows = {}
    for f in sorted(glob.glob(f"{d}/{leg}_*.csv")):
        for r in csv.DictReader(open(f)):
            rows[r["tx_hash"]] = r
    return rows

d = sys.argv[1]
meta = json.load(open(sys.argv[2])) if len(sys.argv) > 2 else {}
U, R = load(d, "unlimited"), load(d, "real95")
print("block,market,side,tyd,status,trader_match_U,trader_match_R,fees_ok_U,fees_ok_R,gasmod_U,gasmod_R,profit_U,profit_R,kinds")
for h, u in sorted(U.items(), key=lambda kv: int(kv[1]["block"])):
    r = R.get(h, {})
    sz = abs(int(u["amount_specified"])) / 1e6
    g = lambda x: int(x["gas_mod"]) - int(x["gas_base"]) if x and x.get("gas_mod") else ""
    print(",".join(map(str, [u["block"], u["market"][:8], u["side"], f"{sz:.2f}", u["status"], u["trader_match"], r.get("trader_match", ""),
        u["fees_not_less"], r.get("fees_not_less", ""), g(u), g(r), int(u["profit_tyd"]) / 1e6, int(r["profit_tyd"]) / 1e6 if r else "",
        "+".join(meta.get(h, {}).get("kinds", []))])))
