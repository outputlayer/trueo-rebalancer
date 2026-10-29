# TrueoRebalancer

An opt-in, post-trade parity rebalancer for Trueo YES/NO prediction-market pools on Base
(Uniswap v4).

After a trade, the prices of a market's YES and NO tokens no longer add up to one payment token (TYD). When the
trader opts in, a small module called at the very end of the Trueo hook's `afterSwap` restores YES + NO ≈ 1 in the
same transaction:

- **YES + NO > 1:** mint YES + NO pairs from TYD and sell both into their pools;
- **YES + NO < 1:** buy YES and NO from their pools and burn the pairs for TYD.

The captured spread goes to a configurable recipient (for example Trueo). The module's swaps are ordinary pool
swaps: they pay Trueo's hook fee and LP fees, pass the swap validator and fill OrderManager limit orders.

Status: experimental research code. Not deployed, not audited by a human audit firm. See [Disclaimer](#disclaimer).

## Architecture

```
trader swap ──> PoolManager ──> TruthMarketHookDemo.afterSwap
                                   ├─ original Trueo afterSwap (validator, movePoolTick, hook fee)   unchanged
                                   └─ if rebalancer set AND hookData ends with the opt-in word
                                      AND enough gas: call TrueoRebalancer.onSwap(key)            (result ignored)
                                            ├─ model both pools, size, decide (no side effects until here)
                                            ├─ mint + sell  /  buy + burn       (one shot, inside the unlock)
                                            └─ profit -> profitRecipient; module ends with zero balances
```

- **Hook patch** ([`patches/TruthMarketHookDemo.patch`](patches/TruthMarketHookDemo.patch), 61 added code lines).
  `TruthMarketHookDemo.sol` is Trueo's verified `TruthMarketHook` source plus this patch. The original `_afterSwap`
  body is kept unchanged as `_afterSwapTrueo`; the new `_afterSwap` runs it first and only then may call the
  rebalancer through a gas-capped low-level call whose result it ignores. New storage sits after the original
  layout. The vendored Trueo sources are checked byte for byte against `vendor/trueo.sha256`.
- **Module** ([`src/TrueoRebalancer.sol`](src/TrueoRebalancer.sol),
  [`src/libraries/RebalanceMath.sol`](src/libraries/RebalanceMath.sol)). Reads both pools tick by tick toward the
  validator bounds (at most 128 boundaries per pool), sizes the rebalance on that model, checks a conservative
  profit estimate against `minProfit` before any side effect, then executes the whole size in one shot: one mint
  and two sales, or one burn and two purchases. It holds no funds between calls.

Full design: [`docs/DESIGN.md`](docs/DESIGN.md).

## Safety properties

- **The trader's result is identical** to the original hook, to the wei; the trader's swap completes whatever the
  module does.
- **Trueo's logic is untouched:** hook fee, swap validator and OrderManager run exactly as before on the trader's
  swap, and run again (fees paid, bounds enforced, orders filled) on the module's own swaps. Trueo's fee income
  only goes up.
- **Unflagged swaps are byte-identical** to the original hook (state and logs), as are all swaps while no
  rebalancer is set.
- **The module never loses funds:** it trades only when the measured profit reaches `minProfit`, checks that every
  PoolManager delta is closed and that its own balances are unchanged, and otherwise reverts.
- **Any module failure reverts only the module's call** (out of gas included); the hook ignores the result.

## Integration

- **Opt-in:** append the 32-byte word `keccak256("TrueoRebalancer.optIn.v1")`
  (`0xd217274b52e15abef088a6b357c3ad97bf9442210f0a77bd7cf0fcaa84d70917`, see
  [`RebalanceFlag`](src/libraries/RebalanceFlag.sol)) to the swap's `hookData`. On a multi-hop route, set it on the
  **last Trueo hop only**.
- **Gas headroom:** the hook calls the module only if, after the swap, `gasleft() - rebalanceGasReserve` is at least
  `rebalanceGasMin`, and forwards at most `rebalanceGas`. A frontend that sets the opt-in should add about
  `rebalanceGas + rebalanceGasReserve + ~0.5M` to the swap's gas limit (**+3M** at the recommended settings), or size
  the limit from an `eth_call` / `eth_simulateV1` dry run with a high gas limit. `eth_estimateGas` alone is not
  enough: it finds the lowest limit at which the swap succeeds, and at that limit the hook skips the module.

## Parameters

| Parameter | Where | Value |
|---|---|---|
| `rebalanceGas` | hook | recommended 1,500,000 (max module gas measured: 715k) |
| `rebalanceGasMin` | hook | default 750,000 (the module is not called with less) |
| `rebalanceGasReserve` | hook | default 1,000,000; floor 150,000 (`MIN_REBALANCE_GAS_RESERVE`) |
| `rebalancer` | hook | module address; zero disables the feature |
| `minProfit` | module | at least 5 units (0.000005 TYD); recommended 0.01-0.05 TYD |
| `thresholdBps` | module | minimum \|YES + NO - 1\| before acting, in bps |
| `maxSize` | module | largest rebalance in payment-token units |
| `profitRecipient`, `enabled` | module | recipient of the spread; global switch |
| `setMarketEnabled(market, on)` | module | per-market switch |

`register(market)` is permissionless; it accepts only active Trueo market clones whose pools use the module's hook.

## Results (Base mainnet fork replays, simulation only)

Settings: rebalanceGas 1.5M, rebalanceGasMin 750k, reserve 1M, minProfit 5 units, maxSize 10,000 TYD,
threshold 10 bps. Each historical swap is replayed at the block before it, once on the deployed hook and once on
the demo hook with the module. Details: [`reports/final_results.md`](reports/final_results.md),
[`reports/history_scan.md`](reports/history_scan.md).

**762 Trueo pool swaps, blocks 53,049,317-53,176,623** (650 replayable single-swap transactions):

| Metric | trader's own gas limit | gas limit + 3M | no gas cap |
|---|---|---|---|
| trader result identical | 650/650 | 650/650 | 650/650 |
| Trueo fees not lower | 650/650 | 650/650 | 650/650 |
| swaps where the module acted | 3 | 500 | 500 |
| captured TYD | 10.99 | 633.71 | 633.71 |
| module gas when acting, p50 / max | 519k / 570k | 534k / 622k | 534k / 622k |
| Trueo TYD fees, before -> after | 134.82 -> 139.92 | 134.82 -> 881.65 | 134.82 -> 881.65 |

**87 historical worst cases** (largest moves, sizes, price-sum deviations and order ladders since the hook's
deployment, single-swap transactions):

| Metric | gas limit + 3M | no gas cap |
|---|---|---|
| trader result identical / fees not lower | 87/87 / 87/87 | 87/87 / 87/87 |
| swaps where the module acted | 83 | 83 |
| captured TYD | 1,062.29 | 1,062.29 |
| module gas when acting, p50 / max | 556k / 715k | 556k / 715k |
| Trueo fees, before -> after (TYD markets) | 40.66 -> 258.01 | 40.66 -> 258.01 |

Maximum module gas over all replays: 715k, well under rebalanceGas 1.5M. With most historical gas limits (set
without a module in mind) the hook simply skips the module. The per-transaction gas cap observed on Base is
16,777,216, so the +3M headroom fits comfortably.

## Security

- Three AI-assisted audit passes with Pashov Audit Group's
  [solidity-auditor](https://github.com/pashov/skills) skill, plus independent reviews. Findings were fixed or
  are documented as accepted limitations; the final report and the list of fixes are in [`docs/audit/`](docs/audit/).
- Documented limitations:
  - Dust positions near the price can reduce what a rebalance captures (the walk is capped at 128 boundaries).
  - Griefing: many cheap initialized ticks or orders on the module's path can make the module exceed
    `rebalanceGas`; it then reverts and the opted-in trader pays up to `rebalanceGas` of extra gas with nothing
    captured.
  - On near-total buy-backs, small outcome-token LP-fee payouts of the OrderManager may be deferred (they stay
    claimable).
  - The opted-in trader pays the module's gas; the profit goes to the recipient.
  - Designed for Base gas prices; not suitable as-is for Ethereum mainnet.

## Tests

All assertion tests were written blind: from the specification, by authors without access to the implementation
(`test/blind2`, `test/blind3`; see their READMEs). The rest of `test/` is shared infrastructure (fixtures, mocks,
fork constants) and the replay harness.

- Local: 249 tests; fork (Base, block 53,172,900): 47 tests. Without `BASE_RPC_URL` the fork suites skip, and the
  replay runs only with `REPLAY=1`.
- Mutation testing: 22/22 hand-written mutants of the module, the math library and the hook gate are killed
  by the blind suite ([`reports/mutation_matrix.md`](reports/mutation_matrix.md)).

Requires [Foundry](https://book.getfoundry.sh/) (solc 0.8.30, via-IR, cancun).

```bash
git clone --recurse-submodules https://github.com/outputlayer/trueo-rebalancer
cd trueo-rebalancer
forge build

# local suite
forge test

# fork suite (Base mainnet; an archive RPC is needed for the fork block)
BASE_RPC_URL=https://mainnet.base.org FORK_BLOCK=53172900 forge test --match-path "test/blind*/fork/*"

# replay of data/trader_swaps.jsonl (writes reports/replay.csv; one fork per swap, needs an archive RPC)
REPLAY=1 REPLAY_LIMIT=762 REPLAY_FORK=block REPLAY_GAS=real+3000000 REPLAY_REBALANCE_GAS=1500000 BASE_RPC_URL=<archive rpc> \
  forge test --match-contract ReplayTest -vv
python3 script/replay_report.py reports/replay.csv --eth-usd 2400

# hook patch round trip and vendored-source check
patch -o /tmp/Demo.sol src/trueo/hook/TruthMarketHook.sol patches/TruthMarketHookDemo.patch \
  && cmp /tmp/Demo.sol src/trueo/hook/TruthMarketHookDemo.sol && echo PATCH_ROUNDTRIP_OK
(cd src/trueo && shasum -a 256 -c ../../vendor/trueo.sha256)
```

## Repository layout

```
src/TrueoRebalancer.sol            the module
src/libraries/RebalanceMath.sol    pool model, sizing and profit estimate
src/libraries/RebalanceFlag.sol    the opt-in word
src/interfaces/                    module and Trueo interfaces
src/trueo/                         Trueo's verified hook and validator sources (MIT) + TruthMarketHookDemo.sol
patches/TruthMarketHookDemo.patch  the hook change as a diff against Trueo's source
vendor/trueo.sha256                hashes of the vendored Trueo sources
test/blind2, test/blind3           blind-written test suites (local and fork)
test/replay/Replay.t.sol           historical replay harness
test/ (other)                      fixtures, mocks, fork constants
data/                              trader swaps for the replay; historical scan data
reports/                           replay results, history scan, mutation matrix
script/                            replay report, vendoring script
docs/                              design and audit
```

## License and attribution

MIT, see [`LICENSE`](LICENSE). The files under `src/trueo/` are Trueo's verified sources (MIT, Sourcify exact
match on Base), vendored unchanged and keeping their original headers; `TruthMarketHookDemo.sol` is derived from
Trueo's `TruthMarketHook.sol`. Dependencies: Uniswap v4 (via OpenZeppelin uniswap-hooks), forge-std, hookmate.

## Disclaimer

This is experimental code that has not been audited by a human security firm and is not deployed. The AI-assisted
reviews cannot prove the absence of vulnerabilities. The replay results are simulations on forks of Base mainnet.
Use at your own risk.
