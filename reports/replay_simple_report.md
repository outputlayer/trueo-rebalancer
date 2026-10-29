# Earlier measurement at rebalanceGas 5M: replay and griefing worst case

> **Superseded.** These numbers were measured with rebalanceGas 5,000,000, before the final parameters
> (rebalanceGas 1,500,000, rebalanceGasMin 750,000) and the last audit fixes. The current results are in
> `final_results.md`. This report is kept for the griefing measurement in Part B and for the comparison with an
> earlier, chunked development version of the module (columns "chunked"; that version is not in this repository).

## Part A: replay of 762 trader swaps (Base fork, REPLAY_FORK=block)

Setup: rebalanceGas 5,000,000, reserve 1,000,000, minProfit 5 units
(simple module `setParams(recipient, 5, 10_000e6, 10)`), same 762 rows, 20 shards x 40 rows per leg, 4 in parallel,
mainnet.base.org. Legs = the trader's gas limit on the module run: `real`, `real+2000000`, `real+6500000`, `unlimited`.
CSVs: `reports/replay_simple_{real,real_2000000,real_6500000,unlimited}.csv`. Columns "chunked" = the same replay
on the earlier chunked version; it had no real+6.5M leg (n/a).

| Metric | real | real (chunked) | real+2M | real+2M (chunked) | real+6.5M | unlimited | unlimited (chunked) |
|---|---|---|---|---|---|---|---|
| rows ok / skip_multi / not_registrable / base_failed | 650/46/65/1 | same | same | same | same | same | same |
| mod_failed | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| trader identical | 650/650 | 650/650 | 650/650 | 650/650 | 650/650 | 650/650 | 650/650 |
| fees not lower | 650/650 | 650/650 | 650/650 | 650/650 | 650/650 | 650/650 | 650/650 |
| swaps where module acted | 2 | 2 | 377 | 377 | 500 | 500 | 500 |
| captured TYD | 0.75 | 0.75 | 596.23 | 596.23 | 633.71 | 633.71 | 633.71 |
| module gas, all ok rows: avg / p50 / p95 / max | 5k / 3k / 3k / 565k | 6k / 4k / 4k / 589k | 321k / 520k / 555k / 622k | 335k / 543k / 577k / 647k | 427k / 528k / 559k / 622k | 427k / 528k / 559k / 622k | 444k / 550k / 582k / 647k |
| module gas, acted rows: avg / p50 / p95 / max | 536k / 507k / 565k / 565k | 559k / 529k / 589k / 589k | 536k / 533k / 560k / 622k | 558k / 555k / 585k / 647k | 536k / 534k / 565k / 622k | 536k / 534k / 565k / 622k | 558k / 555k / 588k / 647k |
| module called by hook (gas added > 5k) | 3 | 3 | 474 | 474 | 650 | 650 | 650 |
| called, captured 0: rows / gas total / max | 1 / 62k / 62k | 1 / 62k / 62k | 97 / 6311k / 235k | 97 / 6622k / 522k | 150 / 9756k / 248k | 150 / 9756k / 248k | 150 / 10078k / 522k |
| TYD fees to Trueo before -> after | 134.82 -> 134.84 | 134.82 -> 134.84 | 134.82 -> 793.15 | 134.82 -> 793.15 | 134.82 -> 881.65 | 134.82 -> 881.65 | 134.82 -> 881.65 |

Findings:

- No bug: 650/650 trader results identical and 650/650 fees not lower in every leg, 0 mod_failed.
- Same behaviour as the chunked module row for row in acted count, captured TYD (633.71 unlimited) and Trueo fees; the one-shot module is about 4% cheaper in gas
  (acted p50 534k vs 555k, max 622k vs 647k) and the worst captured-0 call fell from 522k to 248k (the chunked NotProfitable(0) dust case no longer runs).
- real+6.5M reaches the unlimited result (500/500 acted, 633.71 TYD): rebalanceGasMin + reserve + the ~150-300k spent before afterSwap fit under limit + 6.5M for every row.
- Shard note: the last shard (rows 760-761) retries on "fewer than 40 rows", harmless; all 762 rows present per leg.

## Part B: griefing worst case (fork test of an earlier development suite, not included; FORK_BLOCK 53172900)

Both pools of the market get 128 liquidity-1 spacing-aligned dust positions in the direction the module sells
and 40 real one-TYD OrderManager orders (the OrderManager fills at most 20 ranges per swap). The trader buys NO with TYD;
the module then mints and sells YES and NO. Module gas = trader gas with module minus without (includes OrderManager fills).
Orders are placed from the pre-trade tick (the OrderManager requires it); trader buy: AERO 5,000 TYD, PUMP 3,000 TYD (larger sizes revert in the validator).

| market | module gas need (complete rebalance) | orders filled (YES pool / NO pool) | rebalanceGas 4M | 5M | 8M | 11M | 14M | 30M |
|---|---|---|---|---|---|---|---|---|
| AERO | 4,052k | 20 / 0 | fails, 3,880k wasted | completes | completes | completes | completes | completes |
| PUMP | 5,847k | 20 / 0 | fails, 3,944k wasted | fails, 4,897k wasted | completes | completes | completes | completes |

- AERO worst case needs 4.05M, within 5M (0.95M headroom). PUMP exceeds 5M: 5.85M; at 5M the rebalance runs out of gas, profit 0,
  and the trader pays about 4.9M extra gas for nothing (the all-or-nothing one-shot failure mode). 8M completes. The same PUMP set-up with 2,000 TYD needs 4.4M (completes at 5M), so the 5M edge sits near a 2,500 TYD trader buy.
- NO pool orders never fill: the deep NO pool moves only about 3 ticks under the module's sale, less than the gap to the first order range, so the 20-range cap is reached on the YES pool only (the module moves YES ~2,400 ticks).
- Assertions hold at every level: trader result identical, module holds nothing, recipient never loses; at 8M+ exactly one rebalance.
- Practical reading: with the reserve 1M and rebalanceGas 5M the module can be made to burn up to ~5M of a trader's gas without capturing anything on a thin market (PUMP) by a griefer who pays for 128 dust positions and 20+ orders; a rebalanceGas of 8M covers both measured worst cases, at the price of a larger gas ask from the trader.
