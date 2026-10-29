# Blind pass 2: TrueoRebalancer tests

Written from the specification without access to the implementation (including the later revision of the property-5 gas gate). The tests were first run against stub contracts, where every suite failed in `setUp` with "stub", as expected.

Run:
- Local: `forge test --match-path "test/blind2/*.t.sol"`
- Fork: `BASE_RPC_URL=https://mainnet.base.org forge test --match-path "test/blind2/fork/*" -vv` (block 53172900; `-vv` prints the results table)

## Shared machinery

- **Baseline.** Unless a test says otherwise, the baseline is the original `TruthMarketHook` code (`_installOriginal`, or the real deployed hook on the fork). It runs on the same snapshot as the module run, which then uses the demo hook plus the module.
- **State, not logs.** Because `recordLogs` also keeps logs from reverted frames, "module acted" and "module idle" are measured from state.
  - **Acted:** the profit recipient's TYD balance rose by at least minProfit and the module holds nothing.
  - **Idle:** both prices, ticks, all four `poolFeeAccumulated` entries, the FeeCollector's ERC‑6909 claims, the recipient and the trader's balances are all identical to the baseline.
- **Where logs are used.** Logs are compared byte for byte only where the module is never called (no-flag paths, `rebalancer = 0`). `Rebalanced` events are counted only alongside a state guard.
- **Counting `onSwap` calls.** `vm.expectCall(module, onSwap.selector, n)` counts invocations.
- **`MultiSwapRouter` (`utils/`).** Records each swap's delta, both pool prices and the fee claims after every swap inside one unlock.
- **`MathHarness`.** Exposes `RebalanceMath.build` / `payFor` / `capacity`.

## Property → tests

| # | File | Tests |
|---|---|---|
| 1 | OptIn | `test_p1_noFlag_multiSwap_identicalToDeployedHook`: mint and burn sides, 1/2/3 swaps, hookData that is empty, 32 bytes not the word, or the word followed by 1 byte. Checks per-swap deltas, prices and claims, plus all logs and the end state. Also `test_p1_noFlag_singleSwap_identical`. Fork: F3. |
| 2 | OptIn | `test_p2_flagOnSwap{k}of{n}_{mint,burn}` for n = 1, 2, 3. Swaps before k must be fully identical, swap k's delta must be identical, and the module runs once: `expectCall` = 1, `Rebalanced` = 1, recipient balance up. |
| 3 | OptIn | `testFuzz_p3_anyHookData`: 8 shapes covering 0–31 bytes, a random 32-byte word, the word itself, prefix + word, word + extra, word in the middle, 33+ bytes, and a 1-bit flip of the word. Also `test_p3_edgeLengths`. `expectCall` count = isSet ? 1 : 0, and the test checks its own model against `RebalanceFlag.isSet`. |
| 4 | OptIn | `test_p4_oneOptedInTrade_*` (mint and burn), `test_p4_noRecursion_reserveZero`, `test_p4_threeFlaggedSwaps_threeOnSwaps`, `test_p4_onSwap_onlyHook` |
| 5 | Reserve + fork F0 | Defaults and admin-only setters for reserve and `rebalanceGasMin`; slots 0–6 equal the original hook (locally and on Base), slot 7 packing, slot 8 empty. Gas sweeps (single swap, and a two-swap route flagged on swap 1) with a burner; the module running with less than rebalanceGas (`test_p5_tightLimit_moduleRunsWithLessGas`: limit = no-module gas + reserve + 1.5M); skipped below min; lowering min enables the call. |
| 6 | Dust | `test_p6_dust16_{yes,no,both}Pool_{mint,burn}`, `test_p6_dust_tooLittleGas_tradeUnchanged`, `test_p6_model_{sale,purchase}_{yes,no}_acrossDust`, `testFuzz_p6_model_conservative` |
| 7 | Ladder | One-shot module. Long ladders (48 and 128 rungs) must be rebalanced profitably with 5M rebalanceGas; fuzz: always "profit ≥ minProfit or idle", and a >3% gap must act. TrapOrderManager traps (deep, first boundary, above rebalanceGas): the module's call runs out of gas and does nothing, guarded by a trap-free run that crosses the trap tick and pays. A cheap trap must still complete. |
| 8 | Fixes | Lower bound below MIN_TICK (mint, burn, both bounds out of range); `setParams` rejects the module, the PoolManager and 0; `setMarketEnabled` is admin-only, emits an event, and switches off only that market; protocol fee (with a control test); unpriced pool. |
| 9 | fork F5 | `test_F5_p9_payBeforeSell_realOrder_AERO` |
| 10 | (removed) | `maxTraderMoveTicks` was removed from the spec (one-shot version); MaxMove.t.sol was deleted. |
| 11 | Invariants | I1 (reverting and burner rebalancers), I2 (fuzz), I3 (two tests), I4, I5 (partial rebalance, bound at the current price), I6 (six cases plus burn side), I7 (stray tokens, many trades), I9, I10 (flagged swaps with `rebalancer = 0` are identical including logs). I8 is covered in OptIn p4. |
| Fork | ForkCases | F0 storage. F1: dust 48/64/128 on AERO and PUMP. F2: 24/48 real orders on AERO and PUMP. F3: no-flag MultiSwapRouter and TwoSwapRouter, mint and burn on both markets. F4: gas sweep. F5: pay-before-sell. |

## Fork scenarios (chosen from on-chain depth at block 53172900)

On both markets the YES pool is deep above the price and almost empty below it. The AERO NO pool is extremely deep. At the fork block YES + NO is 1.034 on AERO and 1.008 on PUMP.

- **F1 (dust).** The trader dumps 10 YES, which takes YES + NO to about 0.94 / 0.91. The module buys YES back up and buys NO. Dust is placed from a dry-run post-trade YES tick upward, which is where the module trades.
- **F2, F4, F5 (orders).** The trader buys NO, so the module sells YES into real 1-TYD `createOrder` bids below the YES price. F2 on PUMP only logs and checks safety (its 1.18% gap is marginal), with no fill guard.
- **F5 (pay-before-sell).** `deal(YES, PoolManager, 0)`. "No deferral" is checked as: the OrderManager's ERC‑6909 YES claim is unchanged, and each filled owner holds exactly the principal (`SqrtPriceMath`, rounded down).
  - Outside-arbitrage comparison: same state with normal balances on the real hook; an arbitrageur sells YES down to the module's final YES price. Each owner's balance and fill status must be equal.
- **Checked against the real hook.** Without the module, F3 passes against the real hook and the slot 0–6 part of F0 passes. The other fork cases run up to their module assertions.

## Tolerances

| Check | Tolerance | Why |
|---|---|---|
| Trader result, flagless swaps, idle state | Exact | The spec says "to the wei" or "bit-identical". |
| Module gas | Trader gas with the module − without ≤ rebalanceGas + 30k | The 30k covers ABI encoding, the cold call and 63/64 slack. |
| Precheck (property 8) | < 60k, measured the same way | As specified. |
| Dust profit (p6) | Relative difference < 0.1% | As specified. |
| Dust YES + NO (p6) | < 2e14 WAD (0.0002) | As specified. |
| Model vs real (p6) | One-sided (model payout ≤ real, model cost ≥ real), within 2 × crossed + 5 | "Crossed" counts the exact dust boundaries the real swap passed; the real swap runs on a hookless fee-0 pool so it is fee-free like `payFor`. |
| Gas sweep (p5) | Starts 5,000 gas above the no-rebalancer success threshold | The hook's own gate check costs a few hundred gas, so the literal claim cannot hold at the exact edge. |
| Burner "fired" | The burner run used ≥ 900k more gas than the base run | It always receives at least `rebalanceGasMin`. |
| Owner fills (F2, F5) | 1 wei vs the computed principal | Exact when compared with the outside-arbitrage run. |
| Order "fill" | Pending order deleted | — |

## Ambiguities and how I read them

1. **Gas gate.** I implemented the revised gate (`rebalanceGasMin`, `avail = gasleft − reserve`, gas = min(rebalanceGas, avail)) instead of the original interface's gate. Because the stub hook lacks `rebalanceGasMin()`, `setRebalanceGasMin()` and the `RebalanceGasMinSet(uint32)` event, these are declared through the `IGasMinHook` interface cast. The demo hook now has them.
2. **setParams rejection error.** The error for a bad recipient is unspecified; I accept either `BadParams` or `ZeroAddress`.
3. **Unpriced pool.** I assumed `register()` succeeds when one pool is uninitialized. If it reverts, `test_p8_unpricedPool_onSwapReturns` fails in setup.
4. **Non-hook `onSwap` caller.** I read this as a revert with `NotHook`.
5. **I7 "balances = before".** I read it literally: tokens donated to the module stay exactly as they were (not swept, not used). I do not require the module to act in that case.
6. **I6 token cap.** Tested on the mint side only. Burning is not blocked by a cap, though the spec says the module "does nothing"; the burn-side idle check uses pause and finalization.
7. **I5 with the bound at the current tick.** I only require the NO pool tick to stay at the bound; a profitable move inside that tick is allowed.
8. **Trap tests (p7), one-shot version:** a trap that makes the module's call run out of gas must leave everything exactly as on the deployed hook. That means no profit, identical prices and fees, and an empty module. The guard is that the same scenario without the trap crosses the trap tick and pays.
9. **Profitability assumptions.** Several "acted" guards (e.g. YES + NO = 1.0086 vs the ~1.00807 / ~1.00909 fee thresholds in p8; the small 20 TYD move in p10) assume the module trades whenever the gap beats LP fee + 0.8% hook fee (+ protocol fee) by a modest margin with `MIN_PROFIT = 1`. The p8 control test makes this assumption explicit.

## Corrections after the first run on the real code

- **Property 5 local sweeps:** fewer points: 31k steps in 1.8–3.2M, 97k steps in 6–7M, 331k steps elsewhere. A sweep now uses ~0.1–0.3e9 gas, under Foundry's per-test cap, and still checks that the burner fired (including partial firings).
- **F4:** the "without" baseline is now the demo hook with rebalancer = 0. The sweep finds that hook's success threshold by binary search and starts 5k above it. Gas differences of the hook itself are out of scope for I1/I10.
- **F5 (clarified):** the module may fill more orders than one outside swap does, because its swaps can take a different path to the price. Still required:
  - nothing deferred;
  - each filled owner is paid exactly their fill in the same transaction;
  - every order the arbitrage fills is also filled by the module, and its owner is paid at least as much.
- **Vacuous tests strengthened:**
  - I2 fuzz and p7 ladder fuzz must act whenever the trade leaves |YES+NO−1| > 3%.
  - New `test_I2_traderIdentical_knownGaps_allAct` (8 trades that must all act).
  - I9 must act at rebalanceGas ≥ 1M.
  - I7 must act, with stray tokens untouched.
  - New `test_I5_validatorBoundOneSpacingAway_actsAndStops`.
  - F2 on PUMP must act (profit > 0) and pay its fills in the same transaction.
- **New `test_F6_route_wordOnLastHop_firstHopFillsOrders_burnerSweep` (§9.2 rule):**
  - The opt-in word is on hop 2 of a two-hop route; hop 1 fills real OrderManager orders.
  - Every gas limit at which the route succeeds with rebalancer = 0 also succeeds with a gas burner, and the burner fires.
  - Checked with the module unplugged: hop 1 fills 5 orders and the burner fires.

## Orientation and decimals (Orientation.t.sol)

- **`Blind2OrientationTest`:** four tests, one per orientation (YES currency0/currency1 × NO currency0/currency1).
  - Outcome tokens are placed below or above TYD's address (0x50…05) with `deployCodeTo`. Market and module are the fixture's (gap 12).
  - Each test makes four trades: buy and sell in the YES pool and in the NO pool, so both mint-side and burn-side rebalances happen.
- **`Blind2DecimalsTest`:** gap 0 (payment token with 18 decimals), gap 6 (12 decimals), and a gap-12 control through the same path.
  - **Test-only mock.** `MockTruthMarket` hard-codes 1e12, so these use `utils/DecTruthMarket.sol`. It mirrors the fixture mock, but mint and burn use `factor = 10**(outcomeDecimals − paymentDecimals)` (the market's mint/burn rule is decimals-based).
  - **Own module per market.** A separate module is deployed with `marketCodehash` = DecTruthMarket's codehash, and `maxSize` = 10k whole payment tokens.
  - **Pools.** Liquidity scales by 10**((12−gap)/2), so the pools hold the same whole-token amounts as the fixture. Validator bounds are [0, 1] payment token per outcome, aligned as on Aero.
  - **Registration check.** `marketOf(id).gap` must equal the gap.
- **Per-trade checks:**
  - The trader's deltas and balances are identical to the deployed hook.
  - The module holds nothing afterwards.
  - If |YES+NO−1| after the trade is > 3%: exactly one `Rebalanced` and profit > 0.
  - If the module acted, YES+NO did not move away from 1 and did not cross it by more than 0.02. That 0.02 limit is my reading of "not past it by more than fees" (generous, about two hook fees plus LP fee).
  - If the module did not act, the prices are unchanged.

## One-shot simplification (specification change)

- **Removed features:** `chunk()`, partial rebalances after a failed chunk, `maxTraderMoveTicks`, and `previousTick()`.
- **Deleted:** `MaxMove.t.sol` and `utils/ChunkProbeOrderManager.sol`.
- **Ladder.t.sol:** the `chunk()` access tests and the later/first-chunk tests are gone. The trap tests now require a complete no-op when the module runs out of gas.
- **Adapted:** `utils/MathHarness.sol` follows the new `build()` signature.
