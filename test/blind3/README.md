# Blind pass 3: TrueoRebalancer tests

Written from the specification and its numbered test plan (the "items" below), the fixtures and blind2, without
access to the implementation. The tests were first run against stub contracts: every suite that deploys the module
failed in `setUp` with "stub", as expected, while the hook-only suites (`HookGate`, `BurnerSweeps`,
`fork/ForkHookSweeps`) already passed.

Run:
- Local: `forge test --match-path "test/blind3/*.t.sol"`
- Fork: `BASE_RPC_URL=https://mainnet.base.org forge test --match-path "test/blind3/fork/*" -vv` (block 53172900)

## Shared machinery

- **`Blind3Base`** (extends Blind2Base).
  - **Baseline.** The demo hook with `rebalancer = 0`, on the same snapshot. blind2 I10 shows this equals the deployed hook code, logs included.
  - **`_pairT(M, T)`.** Runs the baseline, then the module run with `cfgGas` / `cfgMin`, and parses the logs: `Rebalanced`, PoolManager `Swap` events with sender == module, ERC-20 Transfers to or from the module, YES minted to and burned from the module, and the trader-pool `Moved` index.
  - **`_assertActedR`.** Trader identical; recipient gain ≥ minProfit and > 0; exactly one `Rebalanced`; `Rebalanced.profit` == recipient gain; the module holds no ERC-20 and no 6909 claims.
  - **`_assertIdleR`.** blind2's `_assertAllSame` (trader, prices, ticks, all four FeeCollector entries, 6909 claims, recipient), plus an exact sum and an empty module.
  - **`_modulePaths`.** Places ladders from each pool's post-trade tick (found by a dry run) in the direction the module's leg moves that pool.
- **Logs.** Logs are counted only when state shows the module acted. "No such log" checks (items 30 and 31) deliberately include reverted frames.
- **Controls.** Every idle-type test first proves, from the same state, that the trade is rebalanced without the blocking condition: items 23, 28, 29, 34, 39, 40–44, 59, and o34. So a module that does nothing fails them.
- **`Blind3HookBase` / `Blind3ForkHookBase`.** Fixtures without the module, for hook-gate and burner tests.
- **`utils/MathHarness3`.** External wrappers for `build`, `capacity`, `walk`, `payFor` and `estimateProfit`, so a test can try/catch them.

## Test-plan item → tests

| # | Pri | Tests |
|---|---|---|
| 1 | must | Admin `test_a1_constructor_zeroAddresses` |
| 2 | must | Admin `test_a2_minProfitFloor` |
| 3 | must | Admin `test_a3_thresholdBound` |
| 4 | must | Admin `test_a4_setParams_storesEveryValue` |
| 5 | must | Admin `test_a5_enablingNeedsRecipient` |
| 6 | must | Admin `test_a6_setAdmin` |
| 7 | must | Admin `test_a7_registerStoresBothPools` |
| 8 | must | Admin `test_a8a_register_wrongCodehash`, `test_a8b_register_inactiveMarket`, `test_a8c_register_otherHook` (plus `test_a8d_register_noCode`) |
| 9 | should | Admin `test_a9_register_permissionless_idempotent` |
| 10 | must | HookGate `test_g10_reserveFloor` |
| 11 | must | HookGate `test_g11_rebalanceGasZero_noCall_noColdAccountCharge` |
| 12 | must | HookGate `test_g12_gasBelowMin_noCall_atMin_called` |
| 13 | must | HookGate `test_g13_minZero_gasZero_noCall` |
| 14 | must | HookGate `test_g14_rebalancerCodeRemoved_tradeIdentical` |
| 15 | should | HookGate `test_g15_setterEvents_andAdminOnlyMin` |
| 16 | should | HookGate `test_g16_rebalancerCalledAfterMovePoolTick` |
| 17 | should | GasModule `test_g17_belowMinSkipIsCheap_{buyYes,sellYes200}`, `test_g17_highMin_skipIsCheap_{buyYes,sellYes200}`, `test_g17_control_plentyOfGas_acts` |
| 18 | must | BurnerSweeps `test_g18_floorSweep_{buyYes50,sellYes200,routeMint_wordOnLastHop,routeBurn_wordOnLastHop}` |
| 19 | must | BurnerSweeps `test_g19_defaultReserveSweep_sellYes200`, `test_g19_defaultReserveSweep_route_sellYesWordFirst_thenBuyNo` |
| 20 | should | GasModule `test_g20_moduleSweep_{mint,burn}_single`, `test_g20_moduleSweep_{mint,burn}_route_wordOnHop1` |
| 21 | should | GasModule `test_g21_headroom_burnSide_sell200Yes` |
| 22 | must | TraderIdentity `test_t22_exactOut_buy30No`, `test_t22_exactOut_get20Tyd_sellingYes` |
| 23 | must | TraderIdentity `test_t23_syncFirstRouter_moduleStaysOut` |
| 24 | should | TraderIdentity `test_t24_hookFeeZero_stillRebalanced_sumNearOne` |
| 25 | must | Economics `test_e25_sumLands_{mintSide,burnSide}`; Orientation `test_o25_*` |
| 26 | must | Economics `test_e26_maxSizeBinding` |
| 27 | must | Economics `test_e27_eventMatchesReality_{mint,burn}` (burn: amount × 1e12 == YES burned) |
| 28 | must | Economics `test_e28_minProfitBlocks` |
| 29 | must | Economics `test_e29_tinyTrade_idle`, `test_e29_threshold1bps_insideFeeBand_idle` |
| 30 | must | Economics `test_e30_decideBeforeSideEffects`; Orientation `test_o30_*` |
| 31 | must | Economics `test_e31_smallGaps_neverMintAndRevert` |
| 32 | must | Economics `test_e32_nearBoundary_tinyOptIn` |
| 33 | must | Economics `test_e33_pmShortOfYes_burnSide`; Orientation `test_o33_*` |
| 34 | must | Economics `test_e34_pmHoldsNoYes_idleCheap`; Orientation `test_o34_*` |
| 35 | must | Economics `test_e35_pmShortOfTyd_mintSide`; Orientation `test_o35_*` |
| 36 | must | Economics `test_e36_capBlocksMintSideOnly`; Orientation `test_o36_*` |
| 37 | should | Economics `test_e37_partialCapRoom` |
| 38 | should | Economics `test_e38_nearOptimal_{mint,burn}` |
| 39 | should | Economics `test_e39_protocolFeeBothWays_actsAndLandsLower`, `test_e39_asymmetricProtocolFee_{mint,burn}_{feeOnOtherDirection_acts,feeOnModuleDirection_idle}` |
| 40 | must | Safety `test_s40_marketMintReverts_idle` |
| 41 | should | Safety `test_s41_otherPoolEmpty_idle` |
| 42 | should | Safety `test_s42_noRoomToBound_idle` |
| 43 | should | Safety `test_s43_{managerPaused,marketPaused,finalized,noPoolPaused,tokenCap}_cheapIdle` |
| 44 | must | Safety `test_s44_tooLittleGas_calledButRealNoop`. It replaces blind2's vacuous `test_p6_dust_tooLittleGas_tradeUnchanged`; the blind2 file is untouched. |
| 45 | must | Safety `test_s45_matrix_{clean,dust16Yes,dust48Yes,dust128Yes,dust64No,dust64Both,real24Both}` |
| 46 | must | Safety `test_s46_oneSize_ladder{24,48,100,200}` |
| 47 | must | Safety `test_s47_exactlyTwoSwaps_longRealLadders` |
| 48 | should | Safety `test_s48_dust{48,64,128}_defaultGas`, `test_s48_dust64_burnSide` |
| 49 | should | Safety `test_s49_trapYesPool_10M_idle`, `test_s49_trapYesPool_100k_acts` |
| 50 | should | Model `test_m50_{sale,purchase}_outcomeCurrency{0,1}_*` (3- and 10-rung ladders each), `testFuzz_m50_modelVsReal` |
| 51 | should | Model `test_m51_stopsAtLimit_{sale,purchase}_{c0,c1}` |
| 52 | should | Model `test_m52_pairProfitModelVsReal_{mint,burn}` |
| 53 | should | fork/ForkMarkets `test_f53_orderFill_equalsOutsideArbitrage_PUMP` |
| 54 | should | fork/ForkHookSweeps `test_f54_defaultReserve_laterHopFillsOrder_burnerSweep` |
| 55 | must | fork/ForkHookSweeps `test_f55_floorSweep_{AERO_buyYes,AERO_sellYes,PUMP_buyNo,PUMP_sellNo,route_wordOnLastHop}` |
| 56 | must | fork/ForkMarkets `test_f56_gasBound_AERO_buyYes200`, `test_f56_gasBound_PUMP_sellNo500` |
| 57 | should | fork/ForkMarkets `test_f57_{AERO_buyYes200,PUMP_buyYes200,PUMP_sellNo500}` |
| 58 | should | fork/ForkMarkets `test_f58_feeAndOrderHooksOnModuleSwaps_AERO` |
| 59 | should | fork/ForkMarkets `test_f59_{pausedThroughSafe,finalized,noPoolPausedOnHook}_idle` |
| 60 | should | fork/ForkMarkets `test_f60_attackerDumps2000No_thenTrader`, `test_f60_attackerBuysNo1000_thenTrader`, `test_f60_attackerOwnDump_rebalancedInOwnTx` |
| 61 | should | fork/ForkMarkets `test_f61_hugeTrade_AERO` |
| 62 | should | fork/ForkMarkets `test_f62_dust16PerPool_vsClean_AERO` |
| 63 | should | fork/ForkMarkets `test_f63_headroom_{AERO_buyYes200,PUMP_sellNo500}` |
| 64 | should | fork/ForkNewMarket `test_f64_newMarketThroughRealManager` |
| 65 | should | fork/ForkMarkets `test_f65_orders{24,48}_xGas_AERO` |
| 66 | should | fork/ForkMarkets `test_f66_worstCaseGriefing_{AERO,PUMP}` |

Coverage: must 36/36, should 30/30. Totals: local 107 tests, fork 28 tests.

## Tolerances

| Check | Tolerance | Source |
|---|---|---|
| Trader result, idle state, sums in (b) cells | exact | test plan: "identical" / "exactly equal" |
| rebalanceGas 0 vs no rebalancer (11, 13) | ±500 gas, accounts cooled | test plan. Measured: 311. |
| Below-min skip (17) | < 10k | test plan |
| Module gas (45, 46, 65) | gas added ≤ rebalanceGas + 30k | test plan |
| Idle cost (30, 31) | < 300k; 34: ≤ 60k; 36 and 43: ≤ 80k | test plan |
| Asymmetric protocol fee, idle side (39) | < 100k gas | mine: the fee-aware precheck should stop early |
| Burner "fired" | 18, 19: ≥ 700k more gas (just under the new default rebalanceGasMin of 750k). 54: ≥ 900k (rebalanceGasMin set to 1M explicitly). 55: ≥ 10k more gas (the limits there leave the burner at most about 300k) | test plan / mine |
| Model vs real (50) | conservative side only, ≤ 2 × (crossed boundaries + 3) wei (a ladder of r rungs has r + 1 boundaries, all crossed); end sqrt price within 1e‑9 relative | test plan (per crossed boundary). I compare the **sqrt** price; on the price itself the bound would be 2e‑9. |
| Capacity (51) | the modelled price at capacity never passes the limit; `cap ≤ real + 8 wei` and within 1e‑6 relative of a real swap to the limit. No sqrt-distance check: one outcome wei moves the sqrt price by ~6.8e13 in purchase_c1. | test plan (revised) |
| Pair model (52) | model ≤ real ≤ model + 8 | test plan |
| Dust profit (62) | ≥ 99.9% of the clean run | test plan |

## Ambiguities and how I read them

1. **Baseline for "identical".** Locally: the demo hook with `rebalancer = 0` (blind2 I10 shows it equals the original code bit for bit). Fork: the deployed hook code. Exceptions:
   - f63 measures plain gas on the demo hook (rebalancer 0).
   - f64 compares against the new demo hook with rebalancer 0, because no original hook exists at that address.
2. **Item 39, asymmetric fee.** I use four directed cases instead of "the same config on each pool".
   - The module's legs are: mint side, YES pool zeroForOne and NO pool oneForZero; burn side, the reverse.
   - Mint side: sum 1.0086, break-even ~1.00807, ~1.00908 with 0.1% on both legs.
   - Burn side: sum 0.9914, break-even ~0.99206, ~0.99107 with the fee.
   - The fee on the module's directions ⇒ idle. The same fee on the opposite directions ⇒ acts.
   - Each case has a no-fee control.
3. **Item 49.** The trap tick (two spacings below the trader's end tick) also lies on the trader's own path. So the trader's swap burns the trap gas in the baseline too: identical in both runs. A disarmed reference run proves the module's YES leg crosses the trap tick.
4. **Item 51.** For an amount past capacity, `payFor` must return `ok = false` or revert; both count as "not tradable". `walk` must return `ok = false`.
5. **Item 52.** Model profit uses curves built at the validator bounds with `Stop` off, `fee` = LP fee (1 pip) and `hookFee` = 80 (feeNumerator). I also require model profit ≥ minProfit at the module's chosen size ("decide before acting").
6. **Item 53.** The purchase doubles from 500 TYD only up to 2000. 4000 TYD fails the YES pool's validator bound even on the real hook.
7. **Item 54.** Hop 2 sells 200 NO. The guard checks that it fills the order and pays the owner in the same transaction.
8. **Item 55.**
   - Accounts are cooled with `vm.cool`. The list comes from a state-diff dry run plus the burner.
   - The sweep starts at plain − 50k, and the test asserts that some limits there fail without the rebalancer.
   - Forge 1.8.3 caps each test at 2^30 gas. Sweep density was sized to stay under it: about 850M used.
9. **Item 64.** The new hook needs three setup steps:
   - `V4_HOOK_ROLE` on the real OrderManager;
   - `FeeCollector.setHookAddress(newHook)` (FeeCollector's `onlyHook` gate);
   - validator `OPERATOR_ROLE` for this test, all granted by the deployer EOA.

   The manager ABI comes from Sourcify (impl 0x7BDa…5999); `createMarketV2` uses the 11-argument overload. The created market's YES is currency1 and its NO is currency0, so the orientation differs from AERO.
10. **Item 20, routes.** With the opt-in on hop 1, hop 2 runs after the rebalance, so only hop 1's delta is compared.
11. **Item 23.** Besides "recipient nothing, module empty", I require both pool prices to equal the baseline ("returns quietly, no effect"). I also check with `expectCall` that the module really was called.
12. **Item 50.** Resolved in the test plan: the bound is per crossed boundary, 2 × (boundaries + 3) wei, conservative side only.

## Validation done here (module unplugged)

- **Local scenarios** (from the fixture state):

  | Trade | YES + NO after |
  |---|---|
  | buy 50 TYD | 1.0800 |
  | sell 50 YES | 0.9561 |
  | buy 2 TYD | 1.0031 |
  | buy 200 TYD | 1.3498 |
  | sell 300 YES | 0.7951 |
  | exact-out 30 NO | 1.0156 |
  | exact-out 20 TYD | 0.9694 |

  - The item 31 threshold is 5.3 TYD.
  - Item 32 stops exactly on T, with sum 1.024.
  - Asymmetric market sum: 1.0086.
  - A 30M burner gets its 30M.
  - The 128 + 64 dust and 100 + 100 real ladders set up fine.
  - The trap run works.
  - The outside mint-sell and buy-burn helpers show profit at every size.
  - Model-test real swaps cross the whole ladder.
- **Fork** (block 53172900):
  - At the fork block YES + NO is 1.0342 on AERO and 1.0083 on PUMP.
  - The trades used by the tests all pass on the real hook. After AERO buy YES 200 the sum is 1.0355; after PUMP sell NO 500 it is 0.9415.
  - AERO's largest accepted YES purchase is 3125 TYD (halving from 50k).
  - The Safe can call `setPaused` on the market.
  - The f64 market creation and seeding work: sum 1.3498 after a 200 TYD purchase.
  - The griefing setups (128 dust + 40 orders per pool) work.
- **Passing now:** HookGate 7/7, BurnerSweeps 6/6, ForkHookSweeps 6/6.

## Corrections after the first run on the real code (local 97/107, fork 28/28)

1. **Default `rebalanceGasMin` is now 750,000.**
   - g12 derives the below-min (min / 2, min − 1) and at-min gas values from `rebalanceGasMin()` and asserts that the default is 750k.
   - g15 and g19 assert 750k. The burner "fired" threshold is now 700k.
   - f63 uses min 750k (the default).
   - blind2, mechanical edits: in Reserve.t.sol the fired threshold is 700k (lines 232 and 272), the first-fire bound is now > 1.75M (reserve + min; it was > 2M), and the comments are updated. fork/ForkCases :556 also uses 700k.
   - Against the stale local demo hook (still 1M), g12, g15 and g19 fail on the default check. With min set to 750k the g19 sweeps pass.
2. **m51.** The 1e6 sqrt-price tolerance is dropped. The test checks behaviour instead: the price never passes the limit and capacity ≤ real + 8 wei.
3. **m50.** Per-boundary tolerance 2 × (rungs + 1 + 3), conservative side only.
4. **e29 tiny trade.** Now includes a control: a 50 TYD purchase from the same snapshot must raise the recipient's balance.

## Re-entry guard (I8), added after the mutation check

The shipped hook never calls `onSwap` from the module's own swaps, because those swaps carry no opt-in word. So the guard was never exercised.

- **`utils/ReentryHook.sol`** is a TEST-ONLY copy of `TruthMarketHookDemo`, generated mechanically:
  - import paths adjusted;
  - the gate `rebalancer != 0 && RebalanceFlag.isSet(hookData)` becomes `rebalancer != 0`;
  - a counter `onSwapCalls` is added, stored after the demo layout (slot 8).

  It calls the rebalancer on every swap of its pools. It is installed at HOOK with `_deployHook`, so the fixture module (bound to HOOK) is unchanged.
- **Gas settings.** Reserve 150k and min 0 on both hooks, so that nested calls are always made.
- **Tests (`Reentry.t.sol`):**
  - `test_r1_nestedOnSwapIgnored_{mint,burn}`:
    - the reference run on the normal demo hook gives the profit P and the final prices;
    - on the variant: the control `onSwapCalls ≥ 3` (trader swap + the module's 2 swaps);
    - acted, with the trader identical, exactly one `Rebalanced` and the module empty;
    - exactly 2 module swaps;
    - profit == P, and each pool's sqrtPrice within 1 wei of the reference.
  - `test_r2_guardReleased_twoTraderSwapsInOneTx`: in one unlock (MultiSwapRouter), buy YES for 50 TYD (opt-in), then buy NO for 50 TYD (opt-in).
    - exactly 2 `Rebalanced`, both profits > 0, and recipient gain == their sum;
    - control: `onSwapCalls ≥ 6`;
    - module empty.
- **Validated without the module:** a RecordingRebalancer on the variant is called on unflagged swaps (counter == calls == 2).

## Audit guards (added after the final review)

### `AuditGuards.t.sol` (revised after the run on the real code)

Name pattern: `test_ag_{burn,mint}_L{1e11,1e12,2e13,1e15}_rungs{16,32,64}`. 64 rungs are split into `_lower` and `_upper` halves of the window: 32 tests in all.

- **Setup.**
  - 1-pip LP fee.
  - 16, 32 or 64 one-spacing positions per pool on the module's paths, with liquidity per rung 1e11, 1e12, 2e13 or 1e15. Small liquidities make per-tick rounding matter.
  - Burn side: a 300 YES sale. Mint side: a 200 TYD purchase.
- **Order of runs.** The no-module baseline runs once (it does not depend on minProfit). The control at minProfit 5 must act; its realized profit is P.
- **Sweep.** minProfit is swept at 1-unit resolution over [P − 300, P + 2], floored at 5. Every step must be one of:
  - a complete rebalance: gain ≥ minProfit, one Rebalanced, 2 module swaps, module empty, trader identical;
  - fully idle.
- **Idle is judged by behaviour first.** In every frame, reverted ones included, there must be:
  - no module Swap;
  - no ERC-20 Transfer to or from the module;
  - no YES mint or burn by the module.

  It must also match the full idle state. Gas is only secondary: ≤ 250k + 16k × rungs per pool.
- **Further checks.** minProfit > P must be idle, and the window must contain an idle step.
- **Coverage.** No combo was dropped. Both the 32- and 64-rung combos are split into `_lower` ([P−300, P−151]) and `_upper` ([P−150, P+2]) halves to stay under Foundry's 2^30 per-test gas cap. The real-code run showed the unsplit rungs32 tests at 0.91–1.23e9 gas.
- **Gas guard.** Every step first asserts that the test still has > 60M gas. Otherwise a starved hook call would make a reverted rebalance look idle.
- **Alternating-liquidity family** (`test_ag_alt_{burn,mint}_L{1e10,1e12}_rungs120_{lower,upper}`, 8 tests):
  - 120 one-spacing ranges per pool on the module's path, with liquidity L, 2L, L, 2L …, so every rung boundary the module crosses is a real change of the liquidity in force. Equal rungs never change it inside the ladder, so they cannot expose an over-optimistic estimate.
  - minProfit is swept one unit at a time over [P−20, P+40], split into [P−20, P+9] and [P+10, P+40].
  - Every step above P must be fully idle (behavioural criterion). Steps ≤ P either complete or are idle. A trade followed by a revert fails the test.
  - The burn side is the target; the mint side is the guard.

### `fork/ForkBurnPayout.t.sol`: `test_fb_burnSide_sellOrdersPaidSameTx_pmHoldsNoTyd_PUMP`

On PUMP:
- **Setup.**
  - An earlier, unflagged dump of 400 NO leaves YES + NO ≈ 0.956.
  - Then 5 real OrderManager SELL-NO orders (2 NO each) are placed one spacing apart just above the new NO price.
  - The PoolManager's TYD balance is dealt to 0.
- **The opted-in trade.** The trader sells 2 YES with the opt-in, taking the TYD output as PoolManager claims.
- **Baseline (deployed hook).** No order is filled and the sum is < 0.99.
- **Module run.**
  - Trader delta, claims and YES are identical to the baseline.
  - One Rebalanced; recipient gain == event profit ≥ minProfit.
  - No `PaymentDeferred` from the OrderManager.
  - Every filled seller holds exactly the principal of its fill in TYD (±1 wei); unfilled sellers hold none.
  - Control: at least one order is filled by the module's NO purchase.
  - The module ends empty, ERC-20 and 6909.
- **Choice of orders.** Probes showed that the pools' depth above the price makes sell orders in the YES pool unreachable, and so are orders above the pre-trade NO price. Hence the earlier dump. A 64 TYD outside NO purchase already fills the first order.
