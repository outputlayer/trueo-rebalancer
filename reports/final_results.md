# TrueoRebalancer (simple, one-shot): final replay measurements

Simulation on Base mainnet forks (Foundry, fork at block-1 of each swap); no transactions broadcast.
Settings: rebalanceGas 1,500,000; rebalanceGasMin 750,000 (hook default); rebalanceGasReserve 1,000,000 (default); minProfit 5 units (0.000005 TYD); maxSize 10,000 TYD; threshold 10 bps.
"Module gas" = gas of the trader's swap with the module minus gas without it. "Acted" = module captured > 0 TYD.
Leg names: `real` = the trader's historical gas limit; `real+3M` = historical limit plus 3,000,000 (rebalanceGas + reserve + ~0.5M frontend headroom); `unlimited` = no gas cap.
Reference columns are the earlier runs with rebalanceGas 5M (762-swap window) and 8M (history), from the previous replay reports.

## A. 762 trader swaps, 3-day window (650 replayed; 46 multi-swap txs, 65 markets not registrable at that block, 1 baseline failure)

| Metric | real | real (5M run) | real+3M | unlimited | unlimited (5M run) |
|---|---|---|---|---|---|
| ok / skip_multi / not_registrable / base_failed | 650/46/65/1 | same | same | same | same |
| module reverted the swap | 0 | 0 | 0 | 0 | 0 |
| trader result identical | 650/650 | 650/650 | 650/650 | 650/650 | 650/650 |
| fees not lower | 650/650 | 650/650 | 650/650 | 650/650 | 650/650 |
| swaps where module acted | 3 | 2 | 500 | 500 | 500 |
| captured TYD | 10.99 | 0.75 | 633.71 | 633.71 | 633.71 |
| module gas, acted: avg / p50 / p95 / max | 534k / 519k / 570k / 570k | 536k / 507k / 565k / 565k | 536k / 534k / 565k / 622k | 536k / 534k / 565k / 622k | 536k / 534k / 565k / 622k |
| module called, captured 0: rows / max gas | 1 / 62k | 1 / 62k | 150 / 248k | 150 / 248k | 150 / 248k |
| Trueo TYD fees, before -> after | 134.82 -> 139.92 | 134.82 -> 134.84 | 134.82 -> 881.65 | 134.82 -> 881.65 | 134.82 -> 881.65 |

- real+3M reaches the unlimited result exactly (500/500 acted, 633.71 TYD, identical gas) and matches the 5M run row for row.
- In the `real` leg most historical gas limits are too small for the module (the hook skips the call when too little gas remains after the swap); with rebalanceGas 1.5M the module acts in 3 rows (10.99 TYD) against 2 (0.75 TYD) at 5M. The traders' own gas limits were set without a module in mind.

## B. 87 worst cases over the full history (single-swap txs; largest moves, sizes, sum deviations, order ladders)

| Metric | real+3M | unlimited | earlier run (8M; real+9.5M and unlimited) |
|---|---|---|---|
| status ok | 87/87 | 87/87 | 87/87 |
| trader result identical | 87/87 | 87/87 | 87/87 |
| fees not lower | 87/87 | 87/87 | 87/87 |
| swaps where module acted | 83 | 83 | 83 |
| captured TYD | 1,062.29 | 1,062.29 | 1,062.29 |
| module gas, acted: avg / p50 / p95 / max | 565k / 556k / 636k / 715k | 565k / 556k / 636k / 715k | 563k / 555k / n.a. / 710k |
| module called, captured 0: rows / max gas | 4 / 487k | 4 / 487k | 4 / 487k |
| Trueo fees, before -> after (TYD, 86 TYD markets) | 40.66 -> 258.01 | 40.66 -> 258.01 | n.a. |

- Both legs give identical gas and profit on every row. Maximum module gas 715k (earlier 710k), well below rebalanceGas 1.5M.
- The fee line excludes one row (block 52543479, market 0x4886...4E1A) whose payment token is not TYD (18 decimals), which makes a TYD-unit sum meaningless; fee-not-lower holds on it as well.
- Captured TYD is unchanged against the 8M run, so the lower rebalanceGas (1.5M) loses no profit on any of the 87 rows.

## Notes
- Shards of 40 (window) / 20 (history) rows, 4 in parallel; the last shard of each leg re-runs once on the "fewer rows than requested" retry, which has no effect on the data.
- Data: `reports/final_window_{real,real_3000000,unlimited}.csv`, `reports/final_history_{real_3000000,unlimited}.csv` (columns as in the replay harness).
