// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Blind2Base} from "../blind2/Blind2Base.sol";
import {TrueoRebalancer} from "../../src/TrueoRebalancer.sol";
import {RebalanceFlag} from "../../src/libraries/RebalanceFlag.sol";
import {MockOrderManager} from "../mocks/MockOrderManager.sol";

/// @notice Shared machinery of the blind pass-3 local tests (on top of Blind2Base).
/// Baseline = the same demo hook with rebalancer = 0 on the same snapshot (blind2 shows it is identical to the
/// deployed TruthMarketHook code, logs included); the run under test = the module plugged in.
/// "Acted" and "idle" are measured from state; logs are only parsed for (a) events of a call that completed
/// (Rebalanced, Swap counts once the state shows the module acted) and (b) "no such log at all" checks, which are
/// strictly stronger when logs of reverted frames are included.
abstract contract Blind3Base is Blind2Base {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    bytes32 internal constant ERC20_TRANSFER = keccak256("Transfer(address,address,uint256)");
    /// what the hook's low-level call may add on top of rebalanceGas (encoding, cold account, 63/64 slack)
    uint256 internal constant CALL_OVERHEAD = 30_000;

    /// One market as seen by the tests (fixture market or one made by _newMarket)
    struct Mkt {
        address m;
        PoolKey ky;
        PoolKey kn;
        address y;
        address n;
    }

    /// A trader swap. amt < 0: exact in |amt|; amt > 0: exact out amt. buy: TYD -> outcome. limit 0 = no limit.
    struct T {
        bool onYes;
        bool buy;
        int256 amt;
        uint160 limit;
    }

    /// One run (baseline or module) and what its logs say
    struct Run {
        Out o;
        uint256 sum;
        uint256 nReb; // Rebalanced events
        bool evMint;
        uint256 evAmount;
        uint256 evProfit;
        uint256 modSwaps; // PoolManager Swap events with sender == module
        uint256 modTransfers; // ERC-20 Transfer events from or to the module (any token)
        uint256 yesMintCount; // YES Transfer(0 -> module)
        uint256 yesMinted;
        uint256 yesBurned; // YES Transfer(module -> 0)
        uint256 movedIdx; // index of the trader-pool Moved log (MockOrderManager), type(uint256).max if none
    }

    /// module configuration applied by _pairT before the module run
    uint32 internal cfgGas = 5_000_000;
    bool internal cfgMinSet;
    uint32 internal cfgMin;

    // ---------------------------------------------------------------- markets

    function _main() internal view returns (Mkt memory M) {
        M = Mkt(address(market), kYes, kNo, YES, NO);
    }

    function _mkt(address m, PoolKey memory ky, PoolKey memory kn) internal pure returns (Mkt memory M) {
        M.m = m;
        M.ky = ky;
        M.kn = kn;
        M.y = Currency.unwrap(ky.currency0) == 0x5000000000000000000000000000000000000005
            ? Currency.unwrap(ky.currency1)
            : Currency.unwrap(ky.currency0);
        M.n = Currency.unwrap(kn.currency0) == 0x5000000000000000000000000000000000000005
            ? Currency.unwrap(kn.currency1)
            : Currency.unwrap(kn.currency0);
    }

    // ---------------------------------------------------------------- configuration

    function _setParams(uint256 mp, uint256 ms, uint16 th) internal {
        vm.prank(admin);
        module.setParams(recipient, mp, ms, th);
    }

    function _plugCfg() internal {
        hook.setRebalancer(address(module));
        hook.setRebalanceGas(cfgGas);
        if (cfgMinSet) hook.setRebalanceGasMin(cfgMin);
    }

    // ---------------------------------------------------------------- trading

    function _zfo(PoolKey memory k, bool buy) internal pure returns (bool) {
        bool outIs0 = Currency.unwrap(k.currency0) != TYD;
        return buy ? !outIs0 : outIs0;
    }

    /// raw swap through the fixture router as the trader, gas measured around the router call
    function _swapRaw(PoolKey memory k, bool zeroForOne, int256 amountSpecified, uint160 limit, bytes memory hd)
        internal
        returns (BalanceDelta d, uint256 used)
    {
        if (limit == 0) limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        vm.prank(trader);
        uint256 g = gasleft();
        d = router.swap(
            k,
            SwapParams(zeroForOne, amountSpecified, limit),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hd
        );
        used = g - gasleft();
    }

    function _tradeT(Mkt memory M, T memory t, bytes memory hd) internal returns (Out memory o) {
        PoolKey memory k = t.onYes ? M.ky : M.kn;
        (BalanceDelta d, uint256 used) = _swapRaw(k, _zfo(k, t.buy), t.amt, t.limit, hd);
        o = _snapOut(M.ky, M.kn);
        o.ok = true;
        o.a0 = d.amount0();
        o.a1 = d.amount1();
        o.gas = used;
    }

    function _parse(Run memory r, Vm.Log[] memory logs, Mkt memory M, PoolId traderPool) internal view {
        r.movedIdx = type(uint256).max;
        bytes32 mod = bytes32(uint256(uint160(address(module))));
        for (uint256 i; i < logs.length; i++) {
            Vm.Log memory l = logs[i];
            if (l.topics.length == 0) continue;
            bytes32 t0 = l.topics[0];
            if (t0 == TrueoRebalancer.Rebalanced.selector && l.emitter == address(module)) {
                r.nReb++;
                (r.evMint, r.evAmount, r.evProfit) = abi.decode(l.data, (bool, uint256, uint256));
            } else if (t0 == IPoolManager.Swap.selector && l.emitter == address(poolManager)) {
                if (l.topics[2] == mod) r.modSwaps++;
            } else if (t0 == ERC20_TRANSFER && l.topics.length == 3) {
                if (l.topics[1] == mod || l.topics[2] == mod) r.modTransfers++;
                if (l.emitter == M.y && l.topics[1] == bytes32(0) && l.topics[2] == mod) {
                    r.yesMintCount++;
                    r.yesMinted += abi.decode(l.data, (uint256));
                }
                if (l.emitter == M.y && l.topics[1] == mod && l.topics[2] == bytes32(0)) {
                    r.yesBurned += abi.decode(l.data, (uint256));
                }
            } else if (
                l.emitter == address(om) && t0 == MockOrderManager.Moved.selector
                    && l.topics[1] == PoolId.unwrap(traderPool) && r.movedIdx == type(uint256).max
            ) {
                r.movedIdx = i;
            }
        }
    }

    /// one run of `t` from the current state with the current hook configuration, logs recorded
    function _runT(Mkt memory M, T memory t, bytes memory hd) internal returns (Run memory r) {
        _startRec();
        r.o = _tradeT(M, t, hd);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        r.sum = _sumOf(M.ky, M.kn);
        _parse(r, logs, M, (t.onYes ? M.ky : M.kn).toId());
    }

    /// baseline (rebalancer 0) and module run of the same opted-in trade from the same snapshot. The state is left
    /// as after the module run.
    function _pairT(Mkt memory M, T memory t) internal returns (Run memory a, Run memory b) {
        uint256 s0 = vm.snapshotState();
        _unplug();
        a = _runT(M, t, _magic());
        vm.revertToState(s0);
        _plugCfg();
        b = _runT(M, t, _magic());
    }

    function _pairMain(bool onYes, bool buy, int256 amt) internal returns (Run memory a, Run memory b) {
        return _pairT(_main(), T(onYes, buy, amt, 0));
    }

    // ---------------------------------------------------------------- assertions

    function _assertEmptyM(Mkt memory M) internal view {
        assertEq(tyd.balanceOf(address(module)), 0, "module holds TYD");
        assertEq(ERC20(M.y).balanceOf(address(module)), 0, "module holds YES");
        assertEq(ERC20(M.n).balanceOf(address(module)), 0, "module holds NO");
        assertEq(poolManager.balanceOf(address(module), uint256(uint160(TYD))), 0, "module 6909 TYD");
        assertEq(poolManager.balanceOf(address(module), uint256(uint160(M.y))), 0, "module 6909 YES");
        assertEq(poolManager.balanceOf(address(module), uint256(uint160(M.n))), 0, "module 6909 NO");
    }

    /// acted: exactly one Rebalanced, recipient gain == event profit >= minProfit, module empty, trader identical
    function _assertActedR(Mkt memory M, Run memory a, Run memory b) internal view returns (uint256 profit) {
        _assertTraderSame(a.o, b.o);
        assertGe(b.o.recv, a.o.recv, "recipient lost");
        profit = b.o.recv - a.o.recv;
        assertGe(profit, module.minProfit(), "module did not act (recipient gain below minProfit)");
        assertGt(profit, 0, "no profit");
        assertEq(b.nReb, 1, "exactly one Rebalanced");
        assertEq(b.evProfit, profit, "Rebalanced.profit != recipient gain");
        _assertEmptyM(M);
    }

    /// idle: everything equals the baseline and the module holds nothing
    function _assertIdleR(Mkt memory M, Run memory a, Run memory b) internal view {
        _assertAllSame(a.o, b.o);
        assertEq(a.sum, b.sum, "sum differs from the no-module run");
        _assertEmptyM(M);
    }

    function _dist(uint256 s) internal pure returns (uint256) {
        return s > 1e18 ? s - 1e18 : 1e18 - s;
    }

    function _gasAdded(Run memory a, Run memory b) internal pure returns (uint256) {
        return b.o.gas > a.o.gas ? b.o.gas - a.o.gas : 0;
    }

    // ---------------------------------------------------------------- liquidity shapes

    /// `n` one-spacing positions of liquidity `liq`, consecutive, starting at the aligned tick `from` and going
    /// down (first range [from - s, from]) or up (first range [from, from + s]); salts start at saltBase
    function _ladderAt(PoolKey memory k, int24 from, bool down, uint256 n, uint128 liq, uint256 saltBase) internal {
        int24 s = k.tickSpacing;
        int24 base = _alignDown(from, s);
        for (uint256 i; i < n; i++) {
            int24 j = int24(int256(i));
            int24 lo = down ? base - (j + 1) * s : base + j * s;
            lpRouter.modifyLiquidity(
                k, ModifyLiquidityParams(lo, lo + s, int256(uint256(liq)), bytes32(saltBase + i)), ""
            );
        }
    }

    /// does selling the outcome of k lower its tick?
    function _saleDown(PoolKey memory k) internal pure returns (bool) {
        return Currency.unwrap(k.currency0) != TYD;
    }

    /// tick of pool `k` after `t` on the no-module hook (dry run, state restored)
    function _postTick(Mkt memory M, T memory t, PoolKey memory k) internal returns (int24 tk) {
        uint256 s = vm.snapshotState();
        _unplug();
        _tradeT(M, t, _magic());
        tk = _tick(k);
        vm.revertToState(s);
    }

    /// state after `t` on the no-module hook (dry run, state restored): sum
    function _postSum(Mkt memory M, T memory t) internal returns (uint256 sm) {
        uint256 s = vm.snapshotState();
        _unplug();
        _tradeT(M, t, _magic());
        sm = _sumOf(M.ky, M.kn);
        vm.revertToState(s);
    }

    /// `nYes` / `nNo` one-spacing positions of liquidity `liq` on the module's paths after trade `t`: from each pool's
    /// post-trade tick in the direction the module's leg moves it (moduleSells: the module sells the outcome, i.e.
    /// the mint side; else it buys it, the burn side)
    function _modulePaths(Mkt memory M, T memory t, bool moduleSells, uint256 nYes, uint256 nNo, uint128 liq, uint256 salt)
        internal
    {
        if (nYes > 0) _pathOne(M, t, M.ky, moduleSells, nYes, liq, salt);
        if (nNo > 0) _pathOne(M, t, M.kn, moduleSells, nNo, liq, salt + 0x10000);
    }

    function _pathOne(Mkt memory M, T memory t, PoolKey memory k, bool moduleSells, uint256 n, uint128 liq, uint256 salt)
        internal
    {
        int24 post = _postTick(M, t, k);
        bool down = moduleSells == _saleDown(k);
        _ladderAt(k, down ? post : post + k.tickSpacing, down, n, liq, salt);
    }

    // ---------------------------------------------------------------- protocol fee

    function _protocolFee(PoolKey memory k, uint24 zeroForOnePips, uint24 oneForZeroPips) internal {
        if (poolManager.protocolFeeController() != address(this)) {
            vm.prank(address(0x4444)); // PoolManager owner in the local deployment (as in blind2 Fixes)
            poolManager.setProtocolFeeController(address(this));
        }
        poolManager.setProtocolFee(k, zeroForOnePips | (oneForZeroPips << 12));
    }

    address internal arb = makeAddr("arb");

    // ---------------------------------------------------------------- outside actor

    /// outside actor on the current state: mint x pairs, sell all YES and NO exact-in (no opt-in)
    function _outsideMintSell(uint256 x) internal returns (int256 profit) {
        tyd.transfer(arb, x);
        vm.startPrank(arb);
        tyd.approve(address(market), type(uint256).max);
        yes.approve(address(router), type(uint256).max);
        no.approve(address(router), type(uint256).max);
        market.mint(x);
        uint256 t0 = tyd.balanceOf(arb);
        _sw(kYes, _zfo(kYes, false), -int256(x * 1e12));
        _sw(kNo, _zfo(kNo, false), -int256(x * 1e12));
        vm.stopPrank();
        profit = int256(tyd.balanceOf(arb)) - int256(t0) - int256(x);
        assertEq(yes.balanceOf(arb), 0);
        assertEq(no.balanceOf(arb), 0);
    }

    /// outside actor: buy x*1e12 YES and NO exact-out, burn the pairs
    function _outsideBuyBurn(uint256 x) internal returns (int256 profit) {
        tyd.transfer(arb, 1e10);
        vm.startPrank(arb);
        tyd.approve(address(router), type(uint256).max);
        yes.approve(address(market), type(uint256).max);
        no.approve(address(market), type(uint256).max);
        uint256 t0 = tyd.balanceOf(arb);
        _sw(kYes, _zfo(kYes, true), int256(x * 1e12));
        _sw(kNo, _zfo(kNo, true), int256(x * 1e12));
        market.burn(x * 1e12);
        vm.stopPrank();
        profit = int256(tyd.balanceOf(arb)) - int256(t0);
    }

    function _sw(PoolKey memory k, bool z, int256 amt) internal {
        router.swap(
            k,
            SwapParams(z, amt, z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

}
