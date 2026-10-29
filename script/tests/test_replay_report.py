import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import replay_report as rr  # noqa: E402


def row(**kw):
    r = {
        "status": "ok", "trader_match": "true", "fees_not_less": "true", "fee_tyd_base": "0",
        "fee_tyd_mod": "500000", "profit_tyd": "15000000", "module_ran": "true",
        "module_ran_at_gas_limit": "false", "gas_base": "280000", "gas_mod": "980000", "basefee": "5000000",
    }
    r.update(kw)
    return r


def test_summarize_counts_and_money():
    rows = [
        row(),
        row(profit_tyd="0", module_ran="false", gas_mod="340000", fee_tyd_mod="0"),
        row(status="skip_multi"),
        row(status="mod_failed"),
    ]
    s = rr.summarize(rows, eth_usd=2000.0)
    assert (s["rows"], s["replayed"], s["skipped_multi"], s["mod_failed"]) == (4, 2, 1, 1)
    assert s["trader_match"] == 2 and s["fees_not_less"] == 2
    assert s["captured_usd"] == 15.0
    assert s["fee_tyd_mod"] == 0.5
    assert s["module_ran"] == 1
    assert s["gas_delta_max"] == 700_000
    assert s["gas_delta_avg"] == 380_000
    # 700k gas * 0.005 gwei * $2000
    assert abs(s["gas_usd_max"] - 0.007) < 1e-12


def test_render_has_targets():
    out = rr.render(rr.summarize([row()], eth_usd=2000.0))
    assert "| Trader result identical | 1 (100.0%) | 100% |" in out
    assert "| Spread captured | $15.00 | > 0 |" in out


def test_compare_has_legs_and_old_column():
    rows = [row(), row(profit_tyd="0", module_ran="false", gas_mod="340000")]
    out = rr.render_compare([("unlimited", rr.summarize(rows, 2000.0))])
    assert "| Metric | unlimited | old (pre-fix) |" in out
    assert "| swaps where module acted | 1 | 498 (unlimited) / 3 (real gas) |" in out
    assert "| trader identical | 2/2 | 650/650 |" in out


def test_quantile():
    assert rr.quantile([], 0.5) == 0
    assert rr.quantile(list(range(101)), 0.95) == 95


def test_called_and_wasted_gas():
    rows = [
        row(),  # acted: +700k, profit
        row(profit_tyd="0", module_ran="false", gas_mod="283000"),  # skipped by the hook gate: +3k
        row(profit_tyd="0", module_ran="false", gas_mod="1790000"),  # called, captured 0: +1.51M
        row(profit_tyd="0", module_ran="false", gas_mod="320000"),  # called, early exit: +40k
    ]
    s = rr.summarize(rows, eth_usd=2000.0)
    assert s["called"] == 3
    assert s["zero_calls"] == 2
    assert s["wasted_gas_total"] == 1_550_000
    assert s["wasted_gas_max"] == 1_510_000
    out = rr.render_compare([("x", s)])
    assert "| module called, captured 0: rows / gas total / max | 2 / 1550k / 1510k | n/a |" in out
