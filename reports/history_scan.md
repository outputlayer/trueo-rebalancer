# Historical scan: worst cases for the simple TrueoRebalancer module

Hook 0x3E83...e0C4 (TruthMarketHook), deployed at block 47,704,304 (2026-06-23). Scan to block 53,207,600 (2026-10-28), 623 Trueo markets (522 on this hook, 101 on the older hook 0x1cFE..., not scanned for swaps in the stats, not replayable by the module).
Market `0xA96A...E737` belongs to the older hook 0x1cFE...40c4 and is out of scope for the module.

## Method
- Pools: getPoolIds()/getPoolKeys() per market (eth_call, latest). TYD is currency0 or currency1 per pool; 4 markets use a different payment token (excluded from size/sum).
- Blocks 51,010,000 - 53,207,600: PoolManager Swap logs for all hook pools, eth_getLogs on publicnode (mainnet.base.org refuses eth_getLogs with 429, drpc allows ~100 blocks). Reconstruction offline: tick move = tick - previous swap tick of the pool, sum = pYES + pNO (TYD per token from sqrtPriceX96, last known price of the other pool; market-creation tick not available, so first swaps are skipped).
- Blocks 47,704,304 - 51,010,000 (publicnode has no data older than ~51.0M): Dune uniswap_v4_base tables, same definitions. Pool pairing there = the two Initialize events of one tx.
- Replay: test/replay/Replay.t.sol with REPLAY_FORK=block (fork at block-1), simple module, rebalanceGas 8,000,000 (env REPLAY_REBALANCE_GAS), legs REPLAY_GAS=unlimited and real+9500000. 87 single-Trueo-swap txs, data/history_swaps.jsonl, table reports/history_replay.csv (script/history_report.py).

## Totals
| | old window 47.70M-51.01M (Jun 23 - Sep 6) | new window 51.01M-53.21M (Sep 6 - Oct 28) |
|---|---|---|
| Trueo swaps | 2,215 (Jun 76, Jul 931, Aug 882, Sep 326) | 4,695 (Sep 1,332, Oct 3,363) |
| pools / markets with swaps | 459 pools | 373 markets |
| swaps in txs with >1 Trueo swap | 1,032 (47%) | 2,094 (45%) |
| \|tick move\| p50 / p90 / p99 / max | 1,193 / 10,787 / 73,009 / 118,861 | 144 / 2,715 / 27,040 / 115,342 |
| trade size TYD p50 / p90 / p99 / max | 2.5 / 19 / 63 / 613 | 11 / 239 / 1,126 / 5,063 |
| \|tick move\| >= 1000 / >= 10000 | 1,204 / 242 | 930 / 135 |
| size >= 100 TYD | 13 | 1,052 |
Total 6,910 swaps. Most active markets: 0xb1cf4f (358 swaps), 0xad5374 (303), 0xf9ca12 (257).

## Worst cases (replayed rows are in history_replay.csv)
- Largest tick moves: 118,861 (block 48262792, dust 0.05 TYD), 115,342 (52707779), 98,261 (51867202), 97,156 (52235685). They are probes into empty thin pools, not value trades.
- Largest trades (TYD): 5,063 (53041033, mkt 0xf9ca12), 4,794 (53125895), 4,401 (52990702, mkt 0xa285f4), 3,235 (53176623), 2,868 (53058476).
- Largest |sum-1| after a swap: sum 1.878 (50417215, 63 TYD), 1.83, 1.81 (48920107), 1.69 (48557140, 70 TYD), 1.66 (48011621, 62.9 TYD); low side 0.0001 (50631732, 72 TYD) and 0.049 (51977830, 73 TYD), 0.053 (51733637). All on new, thin, mispriced markets (market-creation artefacts).

## Replay results (87 rows, both legs)
- Status ok 87/87; trader identical 87/87 in both legs; fees not lower 87/87 in both legs. No bug found.
- Module gas (gas with module minus gas without it): max 710,281 (block 51741236); next 683,076, 670,397, 637,403, 630,905. Never above 0.72M, so never needs 5M or 8M; unlimited and real+9.5M give identical gas (+-20) and identical profit on all rows.
- Max profit per swap: 179.77 TYD (block 53058476, a 2,868 TYD sell on 0xa01413), then 111.28 (52992083), 109.22 (52990033), 100.35, 97.78, 94.16 (53041033), 76.08 (53125895). Zero-profit calls: 4 rows, 63k-487k gas.
- Order ladders: from 51.01M on, OrderManager has 327 OrderFilled/PartiallyFilled events in 130 txs (168 of 4,695 swaps touch any fill). Distribution of events per tx: 1 x76, 2 x45, 5, 7, 8, 9, 10 (x2), 11, 36, 65. Dense cases: 65 fills (block 53178491, 2,050 TYD, module 575k gas, profit 0.025) and 36 fills (53178857, 580k, 0.025). Before 51.01M: 16 txs with exactly 1 fill. Replayed all single-swap ladder txs (5-65 fills): module gas 536k-599k.
