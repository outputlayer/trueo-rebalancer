# Mutation matrix: blind test suite

22 hand-written single-point mutants of the module (`TR` = `src/TrueoRebalancer.sol`), the math library
(`RM` = `src/libraries/RebalanceMath.sol`) and the hook gate (`H` = `src/trueo/hook/TruthMarketHookDemo.sol`),
run against the blind-written suite only (`test/blind2`, `test/blind3`; the rest of `test/` is fixtures and mocks).
Mutants 1-20 target the properties of the specification; 21 and 22 undo the two code fixes made after the final
audit run (per-edge rounding slack, burn side paying TYD before its purchases).

Procedure per mutant: apply the change → `forge test --match-path "test/blind[23]/*.t.sol"` (local) → if nothing
failed, `forge test --match-path "test/blind[23]/fork/*.t.sol"` on a Base fork at block 53,172,900 → restore the
file and check that the tree is clean. Killed = at least one failing test. No mutant failed to compile. Line
numbers refer to the current source.

**Result: 22/22 killed** (20 by the local suite, 2 only by the fork suite: #14 and #22, which need the real
OrderManager paying order owners from the PoolManager's balance).

| # | Location | Mutation | Killed (failing tests) | Killing tests |
|---|---|---|---|---|
| 1 | TR:112 | setParams: PoolManager accepted as recipient (`== poolManager` check dropped) | local (2) | `blind2/Fixes.t.sol::test_p8_setParams_rejectsModuleAndPoolManagerAndZero`, `blind3/Admin.t.sol::test_a4_setParams_storesEveryValue` |
| 2 | TR:115 | minProfit floor `<=` → `<` (4 units accepted) | local (2) | `blind3/Admin.t.sol::test_a2_minProfitFloor`, `blind3/Admin.t.sol::test_a4_setParams_storesEveryValue` |
| 3 | TR:124 | setEnabled: `enabled && recipient == 0` check deleted | local (1) | `blind3/Admin.t.sol::test_a5_enablingNeedsRecipient` |
| 4 | TR:145 | register: codehash pin dropped | local (1) | `blind3/Admin.t.sol::test_a8a_register_wrongCodehash` |
| 5 | TR:189 | `if (locked) return;` deleted (re-entry lock) | local (2) | `blind3/Reentry.t.sol::test_r1_nestedOnSwapIgnored_burn`, `blind3/Reentry.t.sol::test_r1_nestedOnSwapIgnored_mint` |
| 6 | TR:204 | pending-sync skip deleted | local (1) | `blind3/TraderIdentity.t.sol::test_t23_syncFirstRouter_moduleStaysOut` |
| 7 | TR:224 | YES-pool fee direction `mint == yOut0` → `!=` | local (3) | `blind3/Economics.t.sol::test_e39_asymmetricProtocolFee_burn_feeOnModuleDirection_idle`, `blind3/Economics.t.sol::test_e39_asymmetricProtocolFee_mint_feeOnModuleDirection_idle`, `blind3/Economics.t.sol::test_e39_asymmetricProtocolFee_mint_feeOnOtherDirection_acts` |
| 8 | TR:238 | decide-before-acting `< int256(minProfit)` → `< int256(0)` | local (36) | `blind3/AuditGuards.t.sol::test_ag_alt_burn_L1e10_rungs120_lower`, `blind3/AuditGuards.t.sol::test_ag_alt_burn_L1e10_rungs120_upper`, `blind3/AuditGuards.t.sol::test_ag_alt_burn_L1e12_rungs120_lower` +33 more |
| 9 | TR:265 | burn size ignores the PoolManager's YES balance | local (4) | `blind3/Economics.t.sol::test_e33_pmShortOfYes_burnSide`, `blind3/Economics.t.sol::test_e34_pmHoldsNoYes_idleCheap`, `blind3/Orientation.t.sol::test_o33_pmShortOfYes_burn` +1 more |
| 10 | TR:267 | mint size: `/ 2` of the PoolManager's TYD dropped | local (3) | `blind3/AuditGuards.t.sol::test_ag_mint_L1e11_rungs64_lower`, `blind3/Economics.t.sol::test_e35_pmShortOfTyd_mintSide`, `blind3/Orientation.t.sol::test_o35_pmShortOfTyd_mint` |
| 11 | TR:274 | token-cap room clamp deleted | local (1) | `blind3/Economics.t.sol::test_e37_partialCapRoom` |
| 12 | TR:307 | `lower <= MIN_TICK` guard deleted | local (3) | `blind2/Fixes.t.sol::test_p8_bothBoundsBeyondTickRange`, `blind2/Fixes.t.sol::test_p8_lowerBoundBelowMinTick_burn`, `blind2/Fixes.t.sol::test_p8_lowerBoundBelowMinTick_mint` |
| 13 | TR:311 | upper limit `upper + 1` → `upper + 2` | local (2) | `blind2/Invariants.t.sol::test_I5_validatorBoundOneSpacingAway_actsAndStops`, `blind2/Invariants.t.sol::test_I5_validatorBoundRespected_partialRebalance` |
| 14 | TR:329 | mint side: pay YES/NO after the sales | fork (1) | `blind2/fork/ForkCases.t.sol::test_F5_p9_payBeforeSell_realOrder_AERO` |
| 15 | RM:194 | mint `gainful`: `- hookFee` → `+ hookFee` | local (13) | `blind2/Fixes.t.sol::test_p8_gapBeatsFees_withoutProtocolFee_rebalanced`, `blind2/Fixes.t.sol::test_p8_protocolFee_gapBeatsOnlyLpFee_cheapNoop`, `blind3/AuditGuards.t.sol::test_ag_mint_L1e11_rungs64_lower` +10 more |
| 16 | RM:197 | burn `gainful`: `+ hookFee` → `- hookFee` | local (5) | `blind3/Economics.t.sol::test_e25_sumLands_burnSide`, `blind3/Economics.t.sol::test_e38_nearOptimal_burn`, `blind3/Economics.t.sol::test_e39_asymmetricProtocolFee_burn_feeOnModuleDirection_idle` +2 more |
| 17 | RM:211 | bisection precision `* REL_PRECISION` → `* 4` | local (7) | `blind2/Dust.t.sol::test_p6_dust16_bothPools_burn`, `blind2/Dust.t.sol::test_p6_dust16_bothPools_mint`, `blind2/Dust.t.sol::test_p6_dust16_yesPool_burn` +4 more |
| 18 | H:166 | hook gate: reserve ignored (`g = left`) | local (11) | `blind2/Reserve.t.sol::test_p5_belowGasMin_moduleSkipped`, `blind2/Reserve.t.sol::test_p5_gasSweep_singleSwap_burnerNeverBreaksTrade`, `blind2/Reserve.t.sol::test_p5_gasSweep_twoSwapRoute_flagOnFirst` +8 more |
| 19 | H:169 | hook gate: `g != 0 &&` dropped | local (1) | `blind3/HookGate.t.sol::test_g13_minZero_gasZero_noCall` |
| 20 | H:259 | hook: reserve floor check → `if (false)` | local (1) | `blind3/HookGate.t.sol::test_g10_reserveFloor` |
| 21 | RM:167 | payFor slack `(k + i) * ROUND_PER_STEP` → `k * ROUND_PER_STEP` (segment edges dropped) | local (4) | `blind3/AuditGuards.t.sol::test_ag_alt_burn_L1e10_rungs120_lower`, `blind3/AuditGuards.t.sol::test_ag_alt_burn_L1e10_rungs120_upper`, `blind3/AuditGuards.t.sol::test_ag_alt_burn_L1e12_rungs120_lower` +1 more |
| 22 | TR:356 | burn side: `_pay(m.tyd, got)` moved after the two purchases | fork (1) | `blind3/fork/ForkBurnPayout.t.sol::test_fb_burnSide_sellOrdersPaidSameTx_pmHoldsNoTyd_PUMP` |

Equivalent or behaviour-invisible variants that were not used as mutants:
- `supply >= cap` → `>` in `_hi`: a room of 0 returns 0 either way.
- `lower <= MIN_TICK` → `<` in `_limit`: both branches give `MIN_SQRT_PRICE + 1`.
- `out < x + minProfit` → `out < x` in `_mintAndSell`: the model is conservative, so the real profit is at least the
  model profit, which was already checked against minProfit.
