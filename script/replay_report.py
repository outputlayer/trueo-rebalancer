#!/usr/bin/env python3
"""Summarises reports/replay.csv (test/replay/Replay.t.sol) into the Level 3 comparison table (Markdown).

Usage: python3 script/replay_report.py reports/replay.csv --eth-usd 2400 > reports/replay_report.md
TYD is valued at $1. Gas in $ = gas * basefee of the forked block * ETH price (L1 data fee not included).
"""
import argparse
import csv
import sys

# gas added above which the hook called the module (a skip by the hook's gas gate costs ~1-4k; the module's
# cheapest early exit ~10k+)
CALLED_GAS = 5_000


def summarize(rows, eth_usd):
    ok = [r for r in rows if r["status"] == "ok"]
    gas_delta = [int(r["gas_mod"]) - int(r["gas_base"]) for r in ok]
    gas_usd = [
        (int(r["gas_mod"]) - int(r["gas_base"])) * int(r["basefee"]) / 1e18 * eth_usd for r in ok
    ]
    acted_gas = [int(r["gas_mod"]) - int(r["gas_base"]) for r in ok if r["module_ran"] == "true"]
    called = [r for r in ok if int(r["gas_mod"]) - int(r["gas_base"]) > CALLED_GAS]
    wasted = [int(r["gas_mod"]) - int(r["gas_base"]) for r in called if int(r["profit_tyd"]) == 0]
    return {
        "called": len(called),
        "zero_calls": len(wasted),
        "wasted_gas_total": sum(wasted),
        "wasted_gas_max": max(wasted) if wasted else 0,
        "wasted_gas_p50": quantile(wasted, 0.5),
        "gas_delta_p50": quantile(gas_delta, 0.5),
        "gas_delta_p95": quantile(gas_delta, 0.95),
        "acted_gas_avg": sum(acted_gas) / len(acted_gas) if acted_gas else 0,
        "acted_gas_p50": quantile(acted_gas, 0.5),
        "acted_gas_p95": quantile(acted_gas, 0.95),
        "acted_gas_max": max(acted_gas) if acted_gas else 0,
        "rows": len(rows),
        "replayed": len(ok),
        "skipped_multi": sum(r["status"] == "skip_multi" for r in rows),
        "base_failed": sum(r["status"] == "base_failed" for r in rows),
        "not_registrable": sum(r["status"] == "not_registrable" for r in rows),
        "mod_failed": sum(r["status"] == "mod_failed" for r in rows),
        "trader_match": sum(r["trader_match"] == "true" for r in ok),
        "fees_not_less": sum(r["fees_not_less"] == "true" for r in ok),
        "fee_tyd_base": sum(int(r["fee_tyd_base"]) for r in ok) / 1e6,
        "fee_tyd_mod": sum(int(r["fee_tyd_mod"]) for r in ok) / 1e6,
        "captured_usd": sum(int(r["profit_tyd"]) for r in ok) / 1e6,
        "module_ran": sum(r["module_ran"] == "true" for r in ok),
        "module_ran_at_gas_limit": sum(r["module_ran_at_gas_limit"] == "true" for r in ok),
        "gas_delta_avg": sum(gas_delta) / len(gas_delta) if gas_delta else 0,
        "gas_delta_max": max(gas_delta) if gas_delta else 0,
        "gas_usd_avg": sum(gas_usd) / len(gas_usd) if gas_usd else 0.0,
        "gas_usd_max": max(gas_usd) if gas_usd else 0.0,
    }


def quantile(xs, q):
    if not xs:
        return 0
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(q * (len(xs) - 1))))]


def pct(a, b):
    return f"{100.0 * a / b:.1f}%" if b else "n/a"


def render(s):
    n = s["replayed"]
    lines = [
        "| Metric | Value | Target |",
        "|---|---|---|",
        f"| Swaps in file / replayed | {s['rows']} / {n} | |",
        f"| Skipped (multi-swap tx) / baseline failed | {s['skipped_multi']} / {s['base_failed']} | |",
        f"| Not registrable (market on another hook / inactive; not replayed) | {s['not_registrable']} | |",
        f"| Failed only with the module | {s['mod_failed']} | 0 |",
        f"| Trader result identical | {s['trader_match']} ({pct(s['trader_match'], n)}) | 100% |",
        f"| Trueo fees not lower (every pool, both tokens) | {s['fees_not_less']} ({pct(s['fees_not_less'], n)}) | 100% |",
        f"| Trueo TYD fees, current hook / with module | {s['fee_tyd_base']:.2f} / {s['fee_tyd_mod']:.2f} TYD | not lower |",
        f"| Spread captured | ${s['captured_usd']:.2f} | > 0 |",
        f"| Module acted (unlimited gas / trader's gas limit) | {s['module_ran']} / {s['module_ran_at_gas_limit']} | |",
        f"| Trader gas added, avg / max | {s['gas_delta_avg']:.0f} / {s['gas_delta_max']} | |",
        f"| Trader gas added in $, avg / max | ${s['gas_usd_avg']:.4f} / ${s['gas_usd_max']:.4f} | |",
    ]
    return "\n".join(lines) + "\n"


OLD = {
    "name": "old (pre-fix)", "ok": 650, "skip_multi": 46, "not_registrable": 65, "base_failed": 1, "mod_failed": 0,
    "trader_match": "650/650", "fees_not_less": "650/650", "acted": "498 (unlimited) / 3 (real gas)",
    "captured": "607.73", "gas": "avg 487k, max 979k", "fees": "134.82 -> 873.65",
}


def render_compare(legs):
    """legs: list of (name, summary). Table of metrics per leg plus the old pre-fix run."""
    cols = [n for n, _ in legs] + [OLD["name"]]
    ss = [s for _, s in legs]
    k = lambda n: f"{n / 1000:.0f}k"  # noqa: E731
    rows = [
        ("rows ok", [str(s["replayed"]) for s in ss], str(OLD["ok"])),
        ("skip_multi", [str(s["skipped_multi"]) for s in ss], str(OLD["skip_multi"])),
        ("not_registrable", [str(s["not_registrable"]) for s in ss], str(OLD["not_registrable"])),
        ("base_failed", [str(s["base_failed"]) for s in ss], str(OLD["base_failed"])),
        ("mod_failed (trader tx reverts only with module)", [str(s["mod_failed"]) for s in ss], str(OLD["mod_failed"])),
        ("trader identical", [f"{s['trader_match']}/{s['replayed']}" for s in ss], OLD["trader_match"]),
        ("fees not lower", [f"{s['fees_not_less']}/{s['replayed']}" for s in ss], OLD["fees_not_less"]),
        ("swaps where module acted", [str(s["module_ran"]) for s in ss], OLD["acted"]),
        ("captured TYD", [f"{s['captured_usd']:.2f}" for s in ss], OLD["captured"]),
        (
            "module gas, all ok rows: avg / p50 / p95 / max",
            [f"{k(s['gas_delta_avg'])} / {k(s['gas_delta_p50'])} / {k(s['gas_delta_p95'])} / {k(s['gas_delta_max'])}" for s in ss],
            OLD["gas"],
        ),
        (
            "module gas, acted rows only: avg / p50 / p95 / max",
            [f"{k(s['acted_gas_avg'])} / {k(s['acted_gas_p50'])} / {k(s['acted_gas_p95'])} / {k(s['acted_gas_max'])}" for s in ss],
            "n/a",
        ),
        ("module called by the hook (gas added > 5k)", [str(s["called"]) for s in ss], "n/a"),
        (
            "module called, captured 0: rows / gas total / max",
            [f"{s['zero_calls']} / {k(s['wasted_gas_total'])} / {k(s['wasted_gas_max'])}" for s in ss],
            "n/a",
        ),
        ("TYD fees to Trueo before -> after", [f"{s['fee_tyd_base']:.2f} -> {s['fee_tyd_mod']:.2f}" for s in ss], OLD["fees"]),
    ]
    out = ["| Metric | " + " | ".join(cols) + " |", "|---|" + "---|" * len(cols)]
    for name, vals, old in rows:
        out.append(f"| {name} | " + " | ".join(vals + [old]) + " |")
    return "\n".join(out) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("csv", nargs="+", help="one csv, or name=csv pairs for a per-leg comparison")
    ap.add_argument("--eth-usd", type=float, required=True)
    a = ap.parse_args(argv)
    legs = []
    for item in a.csv:
        name, _, path = item.rpartition("=")
        with open(path) as f:
            legs.append((name or path, summarize(list(csv.DictReader(f)), a.eth_usd)))
    if len(legs) == 1 and "=" not in a.csv[0]:
        sys.stdout.write(render(legs[0][1]))
    else:
        sys.stdout.write(render_compare(legs))


if __name__ == "__main__":
    main()
