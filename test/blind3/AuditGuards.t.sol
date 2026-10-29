// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console} from "forge-std/console.sol";
import {Blind3Base} from "./Blind3Base.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// Audit guard: the module must never trade on a profit estimate higher than what the trade really yields (pool
/// rounding per crossed initialized tick). Ladders of initialized positions (several liquidities per rung and rung
/// counts) sit on both pools' module paths at the real 1-pip LP fee. P = the profit realized at minProfit 5; then
/// minProfit is swept at 1-unit resolution over [P - 300, P + 2]. Every step is either a complete rebalance or fully
/// idle, where idle is judged by behaviour in every frame (reverted ones included): no module swap, no token moved to
/// or from the module, no mint or burn. Gas is only a secondary bound: 250k + 16k per rung per pool.
contract Blind3AuditGuardsTest is Blind3Base {
    uint256 internal constant WINDOW = 300;

    /// minProfit from P + lo to P + hi (inclusive, offsets may be negative; floored at 5)
    /// test gas that must remain before each step, so the hook always forwards the full rebalanceGas
    uint256 internal constant MIN_TEST_GAS = 60_000_000;

    /// `n` one-spacing ranges of alternating liquidity L, 2L, L, ... from the post-trade tick of `k` in the direction
    /// the module's leg moves it: every rung boundary is a real change of the liquidity in force
    function _altPath(Mkt memory M, T memory t, PoolKey memory k, bool moduleSells, uint256 n, uint128 L, uint256 salt)
        internal
    {
        int24 post = _postTick(M, t, k);
        bool down = moduleSells == _saleDown(k);
        int24 sp = k.tickSpacing;
        int24 base = _alignDown(down ? post : post + sp, sp);
        for (uint256 i; i < n; i++) {
            int24 j = int24(int256(i));
            int24 lo_ = down ? base - (j + 1) * sp : base + j * sp;
            uint128 l = i % 2 == 0 ? L : 2 * L;
            lpRouter.modifyLiquidity(k, ModifyLiquidityParams(lo_, lo_ + sp, int256(uint256(l)), bytes32(salt + i)), "");
        }
    }

    function _sweep(bool mintSide, uint256 nPerPool, uint128 liq, int256 lo, int256 hi) internal {
        _sweepX(mintSide, nPerPool, liq, lo, hi, false);
    }

    /// alt = true: alternating-liquidity ladders (L, 2L, ...); otherwise equal rungs of `liq`
    function _sweepX(bool mintSide, uint256 nPerPool, uint128 liq, int256 lo, int256 hi, bool alt) internal {
        Mkt memory M = _main();
        T memory t = mintSide ? T(true, true, -200e6, 0) : T(true, false, -300e18, 0);
        if (alt) {
            _altPath(M, t, M.ky, mintSide, nPerPool, liq, 0x9000);
            _altPath(M, t, M.kn, mintSide, nPerPool, liq, 0x19000);
        } else {
            _modulePaths(M, t, mintSide, nPerPool, nPerPool, liq, 0x9000);
        }
        cfgGas = 5_000_000;
        uint256 s0 = vm.snapshotState();

        // baseline (no module) once: it does not depend on minProfit
        _unplug();
        Run memory a = _runT(M, t, _magic());
        vm.revertToState(s0);

        // control: at minProfit 5 the module acts; P = its realized profit
        _plugCfg();
        Run memory c = _runT(M, t, _magic());
        uint256 P = c.o.recv - a.o.recv;
        _assertActedR(M, a, c);
        assertEq(c.evMint, mintSide);
        console.log("rungs per pool / liquidity per rung / P", nPerPool, liq, P);

        uint256 idleGas = 250_000 + 16_000 * nPerPool;
        uint256 acted;
        uint256 idle;
        int256 from = int256(P) + lo;
        if (from < 5) from = 5;
        int256 to = int256(P) + hi;
        for (int256 mp = from; mp <= to; mp++) {
            vm.revertToState(s0);
            // never let the test's own gas starve the hook's call (a starved module frame would look "idle")
            assertGt(gasleft(), MIN_TEST_GAS, "test gas nearly exhausted: split the window further");
            _setParams(uint256(mp), MAX_SIZE, THRESHOLD_BPS);
            _plugCfg();
            Run memory b = _runT(M, t, _magic());
            _assertTraderSame(a.o, b.o);
            _assertEmptyM(M);
            assertGe(b.o.recv, a.o.recv, "recipient lost");
            if (b.o.recv > a.o.recv) {
                acted++;
                assertGe(b.o.recv - a.o.recv, uint256(mp), "acted below minProfit");
                assertEq(b.nReb, 1);
                assertEq(b.modSwaps, 2);
            } else {
                idle++;
                // primary: behaviour in every frame, reverted ones included
                assertEq(b.modSwaps, 0, string.concat("module swapped and reverted at minProfit ", vm.toString(mp)));
                assertEq(b.modTransfers, 0, string.concat("token moved to/from the module at minProfit ", vm.toString(mp)));
                assertEq(b.yesMintCount, 0, "mint in a frame that did nothing");
                assertEq(b.yesBurned, 0, "burn in a frame that did nothing");
                _assertIdleR(M, a, b);
                // secondary: a read-only look over the pools
                assertLe(_gasAdded(a, b), idleGas, "idle module gas above 250k + 16k per rung");
            }
            if (uint256(mp) > P) assertEq(b.o.recv, a.o.recv, "acted with minProfit above the achievable profit");
        }
        console.log("acted / idle", acted, idle);
        if (hi > 0) assertGt(idle, 0, "the window never reached an idle step");
    }

    function test_ag_burn_L1e11_rungs16() public {
        _sweep(false, 16, 1e11, -int256(WINDOW), 2);
    }

    function test_ag_burn_L1e11_rungs32_lower() public {
        _sweep(false, 32, 1e11, -int256(WINDOW), -151);
    }

    function test_ag_burn_L1e11_rungs32_upper() public {
        _sweep(false, 32, 1e11, -150, 2);
    }

    function test_ag_burn_L1e11_rungs64_lower() public {
        _sweep(false, 64, 1e11, -int256(WINDOW), -151);
    }

    function test_ag_burn_L1e11_rungs64_upper() public {
        _sweep(false, 64, 1e11, -150, 2);
    }

    function test_ag_burn_L1e12_rungs16() public {
        _sweep(false, 16, 1e12, -int256(WINDOW), 2);
    }

    function test_ag_burn_L1e12_rungs32_lower() public {
        _sweep(false, 32, 1e12, -int256(WINDOW), -151);
    }

    function test_ag_burn_L1e12_rungs32_upper() public {
        _sweep(false, 32, 1e12, -150, 2);
    }

    function test_ag_burn_L1e12_rungs64_lower() public {
        _sweep(false, 64, 1e12, -int256(WINDOW), -151);
    }

    function test_ag_burn_L1e12_rungs64_upper() public {
        _sweep(false, 64, 1e12, -150, 2);
    }

    function test_ag_burn_L2e13_rungs16() public {
        _sweep(false, 16, 2e13, -int256(WINDOW), 2);
    }

    function test_ag_burn_L2e13_rungs32_lower() public {
        _sweep(false, 32, 2e13, -int256(WINDOW), -151);
    }

    function test_ag_burn_L2e13_rungs32_upper() public {
        _sweep(false, 32, 2e13, -150, 2);
    }

    function test_ag_burn_L2e13_rungs64_lower() public {
        _sweep(false, 64, 2e13, -int256(WINDOW), -151);
    }

    function test_ag_burn_L2e13_rungs64_upper() public {
        _sweep(false, 64, 2e13, -150, 2);
    }

    function test_ag_burn_L1e15_rungs16() public {
        _sweep(false, 16, 1e15, -int256(WINDOW), 2);
    }

    function test_ag_burn_L1e15_rungs32_lower() public {
        _sweep(false, 32, 1e15, -int256(WINDOW), -151);
    }

    function test_ag_burn_L1e15_rungs32_upper() public {
        _sweep(false, 32, 1e15, -150, 2);
    }

    function test_ag_burn_L1e15_rungs64_lower() public {
        _sweep(false, 64, 1e15, -int256(WINDOW), -151);
    }

    function test_ag_burn_L1e15_rungs64_upper() public {
        _sweep(false, 64, 1e15, -150, 2);
    }

    function test_ag_mint_L1e11_rungs16() public {
        _sweep(true, 16, 1e11, -int256(WINDOW), 2);
    }

    function test_ag_mint_L1e11_rungs32_lower() public {
        _sweep(true, 32, 1e11, -int256(WINDOW), -151);
    }

    function test_ag_mint_L1e11_rungs32_upper() public {
        _sweep(true, 32, 1e11, -150, 2);
    }

    function test_ag_mint_L1e11_rungs64_lower() public {
        _sweep(true, 64, 1e11, -int256(WINDOW), -151);
    }

    function test_ag_mint_L1e11_rungs64_upper() public {
        _sweep(true, 64, 1e11, -150, 2);
    }

    function test_ag_mint_L1e12_rungs16() public {
        _sweep(true, 16, 1e12, -int256(WINDOW), 2);
    }

    function test_ag_mint_L1e12_rungs32_lower() public {
        _sweep(true, 32, 1e12, -int256(WINDOW), -151);
    }

    function test_ag_mint_L1e12_rungs32_upper() public {
        _sweep(true, 32, 1e12, -150, 2);
    }

    function test_ag_mint_L1e12_rungs64_lower() public {
        _sweep(true, 64, 1e12, -int256(WINDOW), -151);
    }

    function test_ag_mint_L1e12_rungs64_upper() public {
        _sweep(true, 64, 1e12, -150, 2);
    }

    function test_ag_mint_L2e13_rungs16() public {
        _sweep(true, 16, 2e13, -int256(WINDOW), 2);
    }

    function test_ag_mint_L2e13_rungs32_lower() public {
        _sweep(true, 32, 2e13, -int256(WINDOW), -151);
    }

    function test_ag_mint_L2e13_rungs32_upper() public {
        _sweep(true, 32, 2e13, -150, 2);
    }

    function test_ag_mint_L2e13_rungs64_lower() public {
        _sweep(true, 64, 2e13, -int256(WINDOW), -151);
    }

    function test_ag_mint_L2e13_rungs64_upper() public {
        _sweep(true, 64, 2e13, -150, 2);
    }

    function test_ag_mint_L1e15_rungs16() public {
        _sweep(true, 16, 1e15, -int256(WINDOW), 2);
    }

    function test_ag_mint_L1e15_rungs32_lower() public {
        _sweep(true, 32, 1e15, -int256(WINDOW), -151);
    }

    function test_ag_mint_L1e15_rungs32_upper() public {
        _sweep(true, 32, 1e15, -150, 2);
    }

    function test_ag_mint_L1e15_rungs64_lower() public {
        _sweep(true, 64, 1e15, -int256(WINDOW), -151);
    }

    function test_ag_mint_L1e15_rungs64_upper() public {
        _sweep(true, 64, 1e15, -150, 2);
    }

    function test_ag_alt_burn_L1e10_rungs120_lower() public {
        _sweepX(false, 120, 1e10, -20, 9, true);
    }

    function test_ag_alt_burn_L1e10_rungs120_upper() public {
        _sweepX(false, 120, 1e10, 10, 40, true);
    }

    function test_ag_alt_burn_L1e12_rungs120_lower() public {
        _sweepX(false, 120, 1e12, -20, 9, true);
    }

    function test_ag_alt_burn_L1e12_rungs120_upper() public {
        _sweepX(false, 120, 1e12, 10, 40, true);
    }

    function test_ag_alt_mint_L1e10_rungs120_lower() public {
        _sweepX(true, 120, 1e10, -20, 9, true);
    }

    function test_ag_alt_mint_L1e10_rungs120_upper() public {
        _sweepX(true, 120, 1e10, 10, 40, true);
    }

    function test_ag_alt_mint_L1e12_rungs120_lower() public {
        _sweepX(true, 120, 1e12, -20, 9, true);
    }

    function test_ag_alt_mint_L1e12_rungs120_upper() public {
        _sweepX(true, 120, 1e12, 10, 40, true);
    }
}
