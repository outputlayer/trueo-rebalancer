// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {ModuleFixture} from "../ModuleFixture.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IOrderManager} from "../../src/trueo/hook/interfaces/IOrderManager.sol";
import {TrueoRebalancer} from "../../src/TrueoRebalancer.sol";
import {RebalanceFlag} from "../../src/libraries/RebalanceFlag.sol";
import {MockTruthMarket} from "../mocks/MockTruthMarket.sol";
import {MockOutcomeToken} from "../mocks/MockOutcomeToken.sol";
import {MockOrderManager} from "../mocks/MockOrderManager.sol";

/// @notice Shared helpers of the blind pass-2 local tests.
/// Baseline = the deployed TruthMarketHook's code (src/trueo/hook/TruthMarketHook.sol, byte-identical to Base) put
/// at the same hook address with the same storage; the run under test = demo hook + module, from the same snapshot.
abstract contract Blind2Base is ModuleFixture {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// What a trader swap left behind (state, not logs: logs of reverted frames are recorded too).
    struct Out {
        bool ok;
        int128 a0; // trader's delta
        int128 a1;
        uint160 sY; // pool prices after the whole transaction
        uint160 sN;
        int24 tY;
        int24 tN;
        uint256 recv; // profit recipient TYD balance
        uint256 trTyd; // trader balances
        uint256 trYes;
        uint256 trNo;
        uint256 fYt; // FeeCollector.poolFeeAccumulated[pool][currency]
        uint256 fYy;
        uint256 fNt;
        uint256 fNn;
        uint256 c6909t; // PoolManager ERC-6909 claims of the FeeCollector
        uint256 c6909y;
        uint256 c6909n;
        uint256 gas; // gas of the trader's router call
    }

    // ---- hook code swaps ----

    /// Put the ORIGINAL TruthMarketHook code at HOOK (storage kept; its constructor re-runs and resets
    /// feeNumerator, so the fee is restored).
    function _installOriginal() internal {
        address om_ = address(hook.orderManager());
        deployCodeTo(
            "TruthMarketHook.sol:TruthMarketHook",
            abi.encode(poolManager, IOrderManager(om_), address(fc), address(this)),
            HOOK
        );
        hook.setFeeRate(HOOK_FEE);
    }

    function _plugWith(address r, uint32 gas_) internal {
        hook.setRebalancer(r);
        hook.setRebalanceGas(gas_);
    }

    function _unplug() internal {
        hook.setRebalancer(address(0));
    }

    function _setMinProfit(uint256 mp) internal {
        vm.prank(admin);
        module.setParams(recipient, mp, MAX_SIZE, THRESHOLD_BPS);
    }

    // ---- measuring ----

    function _snapOut(PoolKey memory ky, PoolKey memory kn) internal view returns (Out memory o) {
        (o.sY, o.tY,,) = poolManager.getSlot0(ky.toId());
        (o.sN, o.tN,,) = poolManager.getSlot0(kn.toId());
        o.recv = tyd.balanceOf(recipient);
        o.trTyd = tyd.balanceOf(trader);
        o.trYes = ERC20(_outOf(ky)).balanceOf(trader);
        o.trNo = ERC20(_outOf(kn)).balanceOf(trader);
        o.fYt = fc.poolFeeAccumulated(ky.toId(), Currency.wrap(TYD));
        o.fYy = fc.poolFeeAccumulated(ky.toId(), Currency.wrap(_outOf(ky)));
        o.fNt = fc.poolFeeAccumulated(kn.toId(), Currency.wrap(TYD));
        o.fNn = fc.poolFeeAccumulated(kn.toId(), Currency.wrap(_outOf(kn)));
        o.c6909t = poolManager.balanceOf(address(fc), uint256(uint160(TYD)));
        o.c6909y = poolManager.balanceOf(address(fc), uint256(uint160(_outOf(ky))));
        o.c6909n = poolManager.balanceOf(address(fc), uint256(uint160(_outOf(kn))));
    }

    /// the non-TYD currency of a market pool
    function _outOf(PoolKey memory k) internal pure returns (address) {
        return Currency.unwrap(k.currency0) == TYD ? Currency.unwrap(k.currency1) : Currency.unwrap(k.currency0);
    }

    /// trader swap on `k` (buy: TYD in, else outcome in), exact-in `amt`, with `hd`; recorded on market (ky, kn)
    function _trade(PoolKey memory k, bool buy, uint256 amt, bytes memory hd, PoolKey memory ky, PoolKey memory kn)
        internal
        returns (Out memory o)
    {
        swapHookData = hd;
        bool outIs0 = Currency.unwrap(k.currency0) != TYD;
        bool zeroForOne = buy ? !outIs0 : outIs0;
        uint256 g = gasleft();
        BalanceDelta d = _swap(k, zeroForOne, -int256(amt));
        uint256 used = g - gasleft();
        o = _snapOut(ky, kn);
        o.ok = true;
        o.a0 = d.amount0();
        o.a1 = d.amount1();
        o.gas = used;
    }

    function _tradeMain(PoolKey memory k, bool buy, uint256 amt, bytes memory hd) internal returns (Out memory) {
        return _trade(k, buy, amt, hd, kYes, kNo);
    }

    // ---- assertions ----

    function _assertTraderSame(Out memory a, Out memory b) internal pure {
        assertEq(a.a0, b.a0, "trader delta0");
        assertEq(a.a1, b.a1, "trader delta1");
        assertEq(a.trTyd, b.trTyd, "trader TYD");
        assertEq(a.trYes, b.trYes, "trader YES");
        assertEq(a.trNo, b.trNo, "trader NO");
    }

    /// everything (trader, both prices, all fee claims, recipient) identical
    function _assertAllSame(Out memory a, Out memory b) internal pure {
        _assertTraderSame(a, b);
        assertEq(a.sY, b.sY, "YES pool price");
        assertEq(a.sN, b.sN, "NO pool price");
        assertEq(a.tY, b.tY, "YES pool tick");
        assertEq(a.tN, b.tN, "NO pool tick");
        assertEq(a.fYt, b.fYt, "fee YES pool TYD");
        assertEq(a.fYy, b.fYy, "fee YES pool YES");
        assertEq(a.fNt, b.fNt, "fee NO pool TYD");
        assertEq(a.fNn, b.fNn, "fee NO pool NO");
        assertEq(a.c6909t, b.c6909t, "6909 TYD");
        assertEq(a.c6909y, b.c6909y, "6909 YES");
        assertEq(a.c6909n, b.c6909n, "6909 NO");
        assertEq(a.recv, b.recv, "recipient");
    }

    /// module did nothing on top of the baseline run `a`
    function _assertIdle(Out memory a, Out memory b) internal view {
        _assertAllSame(a, b);
        _assertModuleEmpty();
    }

    /// module acted: profit >= minProfit reached the recipient, the module holds nothing
    function _assertActed(Out memory base, Out memory run, uint256 minProfit_) internal view {
        assertGe(run.recv, base.recv + minProfit_, "module did not deliver profit");
        _assertModuleEmpty();
    }

    function _assertLogsEqual(Vm.Log[] memory a, Vm.Log[] memory b) internal pure {
        assertEq(a.length, b.length, "log count");
        for (uint256 i; i < a.length; i++) {
            assertEq(a[i].emitter, b[i].emitter, "log emitter");
            assertEq(a[i].data, b[i].data, "log data");
            assertEq(a[i].topics.length, b[i].topics.length, "log topics");
            for (uint256 j; j < a[i].topics.length; j++) {
                assertEq(a[i].topics[j], b[i].topics[j], "log topic");
            }
        }
    }

    /// start (or restart) log recording with an empty buffer
    function _startRec() internal {
        vm.recordLogs();
        vm.getRecordedLogs();
    }

    function _onSwapSel() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(TrueoRebalancer.onSwap.selector);
    }

    function _magic() internal pure returns (bytes memory) {
        return RebalanceFlag.encode();
    }

    // ---- liquidity shapes ----

    function _alignDown(int24 t, int24 s) internal pure returns (int24) {
        int24 r = t / s * s;
        if (t < 0 && r != t) r -= s;
        return r;
    }

    /// `n` positions [t_i, t_i + spacing] of liquidity `liq`, consecutive, starting next to the current tick and
    /// going in the direction the price moves when `outcome` is SOLD (sell = true) or BOUGHT (sell = false).
    /// `saltBase` only separates positions (salts); the first rung always starts one spacing from the current
    /// aligned tick. Returns the first and last boundary tick of the ladder.
    function _ladder(PoolKey memory k, bool sell, uint256 n, uint128 liq, uint256 skip)
        internal
        returns (int24 first, int24 last)
    {
        bool outIs0 = Currency.unwrap(k.currency0) != TYD;
        bool down = sell ? outIs0 : !outIs0; // selling currency0 lowers the tick
        int24 s = k.tickSpacing;
        int24 base = _alignDown(_tick(k), s);
        for (uint256 i = skip; i < skip + n; i++) {
            int24 j = int24(int256(i - skip + 1));
            int24 lo = down ? base - j * s : base + j * s;
            lpRouter.modifyLiquidity(k, ModifyLiquidityParams(lo, lo + s, int256(uint256(liq)), bytes32(i)), "");
            if (i == skip) first = down ? lo + s : lo;
            last = down ? lo : lo + s;
        }
    }

    // ---- extra markets (same mock market code => same codehash) ----

    function _newMarket(address yesAddr, address noAddr, uint256 pY, uint256 pN, bool initNo, uint128 extraLiq)
        internal
        returns (MockTruthMarket m, PoolKey memory ky, PoolKey memory kn)
    {
        m = new MockTruthMarket();
        deployCodeTo("MockOutcomeToken.sol:MockOutcomeToken", abi.encode("Y2", address(m)), yesAddr);
        deployCodeTo("MockOutcomeToken.sol:MockOutcomeToken", abi.encode("N2", address(m)), noAddr);
        m.init(mgr, ERC20(TYD), MockOutcomeToken(yesAddr), MockOutcomeToken(noAddr), LP_FEE, SPACING, HOOK);
        mgr.setActive(address(m), true);
        (ky, kn) = m.getPoolKeys();
        tyd.approve(address(m), type(uint256).max);
        m.mint(1e12);
        MockOutcomeToken(yesAddr).approve(address(lpRouter), type(uint256).max);
        MockOutcomeToken(noAddr).approve(address(lpRouter), type(uint256).max);
        _initPool(ky, yesAddr, pY);
        if (extraLiq > 0) {
            lpRouter.modifyLiquidity(ky, ModifyLiquidityParams(FULL_LO, FULL_HI, int256(uint256(extraLiq)), "x"), "");
        }
        if (initNo) {
            _initPool(kn, noAddr, pN);
            if (extraLiq > 0) {
                lpRouter.modifyLiquidity(
                    kn, ModifyLiquidityParams(FULL_LO, FULL_HI, int256(uint256(extraLiq)), "x"), ""
                );
            }
        }
        vm.startPrank(trader);
        MockOutcomeToken(yesAddr).approve(address(router), type(uint256).max);
        MockOutcomeToken(noAddr).approve(address(router), type(uint256).max);
        tyd.approve(address(m), type(uint256).max);
        m.mint(1e9);
        vm.stopPrank();
    }

    /// Sum of prices of a market given its keys
    function _sumOf(PoolKey memory ky, PoolKey memory kn) internal view returns (uint256) {
        return _price(ky, _outOf(ky)) + _price(kn, _outOf(kn));
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }
}
