// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {ForkFixture} from "../../fork/ForkFixture.sol";
import {IOrderManager} from "../../../src/trueo/hook/interfaces/IOrderManager.sol";
import {Order} from "../../../src/trueo/hook/libraries/Order.sol";
import {IERC20Like} from "../../../src/interfaces/ITrueo.sol";
import {RebalanceFlag} from "../../../src/libraries/RebalanceFlag.sol";

interface IPermit2Approve {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @notice Shared fork helpers for the blind pass-2 fork cases. Baseline = the REAL deployed hook code at
/// 0x3E83...e0C4 on the same state (snapshot/revert); run = demo hook + module plugged in (ForkFixture._installDemo).
abstract contract Blind2ForkBase is ForkFixture {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    PoolModifyLiquidityTest internal lp;

    struct FOut {
        int128 a0;
        int128 a1;
        uint160 sY;
        uint160 sN;
        int24 tY;
        int24 tN;
        uint256 sum;
        uint256 recv;
        uint256 trT;
        uint256 trY;
        uint256 trN;
        uint256 feeY; // FeeCollector: TYD fees tracked for the YES pool
        uint256 feeN;
        uint256 gas;
    }

    function setUp() public virtual override {
        super.setUp();
        _forkExtras();
    }

    function _forkExtras() internal {
        lp = new PoolModifyLiquidityTest(PM);
    }

    function _fsnap(address m) internal view returns (FOut memory o) {
        (PoolKey memory ky, PoolKey memory kn) = _keys(m);
        (o.sY, o.tY,,) = PM.getSlot0(ky.toId());
        (o.sN, o.tN,,) = PM.getSlot0(kn.toId());
        o.sum = _sum(m);
        o.recv = IERC20Like(TYD).balanceOf(recipient);
        o.trT = IERC20Like(TYD).balanceOf(trader);
        o.trY = IERC20Like(_outcome(m, true)).balanceOf(trader);
        o.trN = IERC20Like(_outcome(m, false)).balanceOf(trader);
        o.feeY = _feeTyd(ky);
        o.feeN = _feeTyd(kn);
    }

    /// opted-in (swapHookData) trader trade; buy = TYD in (amt TYD), else amt outcome in
    function _ftrade(address m, bool yesSide, bool buy, uint256 amt) internal returns (FOut memory o) {
        uint256 g = gasleft();
        BalanceDelta d = buy ? _buyAs(trader, m, yesSide, amt) : _sellAs(trader, m, yesSide, amt);
        uint256 used = g - gasleft();
        o = _fsnap(m);
        o.a0 = d.amount0();
        o.a1 = d.amount1();
        o.gas = used;
    }

    function _assertTraderSameF(FOut memory a, FOut memory b) internal pure {
        assertEq(a.a0, b.a0, "trader delta0");
        assertEq(a.a1, b.a1, "trader delta1");
        assertEq(a.trT, b.trT, "trader TYD");
        assertEq(a.trY, b.trY, "trader YES");
        assertEq(a.trN, b.trN, "trader NO");
    }

    /// baseline on the real hook (opt-in word in hookData too: the real hook ignores it)
    function _baseline(address m, bool yesSide, bool buy, uint256 amt) internal returns (FOut memory) {
        swapHookData = RebalanceFlag.encode();
        return _ftrade(m, yesSide, buy, amt);
    }

    /// same trade with the demo hook + module plugged in and the opt-in
    function _withModule(address m, bool yesSide, bool buy, uint256 amt) internal returns (FOut memory) {
        _installDemo(true);
        return _ftrade(m, yesSide, buy, amt);
    }

    /// pool tick after the trade on the real hook (dry run, state restored)
    function _postTick(address m, bool yesSide, bool buy, uint256 amt) internal returns (int24 t) {
        uint256 s = vm.snapshotState();
        _baseline(m, yesSide, buy, amt);
        t = _tick(_pool(m, yesSide));
        vm.revertToState(s);
    }

    function _alignDown(int24 t, int24 s) internal pure returns (int24) {
        int24 r = t / s * s;
        if (t < 0 && r != t) r -= s;
        return r;
    }

    /// `n` positions of liquidity 1, one spacing wide, spacing-aligned, from tick `from` upward or downward
    function _dust(PoolKey memory k, int24 from, bool up, uint256 n) internal {
        address c0 = Currency.unwrap(k.currency0);
        address c1 = Currency.unwrap(k.currency1);
        deal(c0, address(this), IERC20Like(c0).balanceOf(address(this)) + 1e20);
        deal(c1, address(this), IERC20Like(c1).balanceOf(address(this)) + 1e20);
        IERC20Like(c0).approve(address(lp), type(uint256).max);
        IERC20Like(c1).approve(address(lp), type(uint256).max);
        int24 s = k.tickSpacing;
        int24 base = _alignDown(from, s);
        for (uint256 i; i < n; i++) {
            int24 lo = up ? base + int24(int256(i)) * s : base - int24(int256(i + 1)) * s;
            lp.modifyLiquidity(k, ModifyLiquidityParams(lo, lo + s, 1, bytes32(uint256(0xd057 + i))), "");
        }
    }

    // ---- real OrderManager orders ----

    struct Ladder {
        PoolKey k;
        address[] owners;
        uint32[] ids;
        uint256[] liq;
        int24[] lo;
        int24[] hi;
        bool zeroForOne; // order direction (input TYD)
    }

    /// `n` orders of `amtTyd` TYD each, one spacing wide, consecutive, that BUY the outcome of `k` as its price
    /// falls (i.e. filled by sales of the outcome), starting next to the current tick
    function _orders(PoolKey memory k, uint256 n, uint128 amtTyd) internal returns (Ladder memory l) {
        l.k = k;
        l.owners = new address[](n);
        l.ids = new uint32[](n);
        l.liq = new uint256[](n);
        l.lo = new int24[](n);
        l.hi = new int24[](n);
        l.zeroForOne = Currency.unwrap(k.currency0) == TYD; // input TYD
        int24 s = k.tickSpacing;
        int24 t = _tick(k);
        int24 base = _alignDown(t, s);
        for (uint256 i; i < n; i++) {
            int24 lo;
            if (l.zeroForOne) {
                // outcome is currency1: its sales raise the tick; order above the tick
                lo = base + int24(int256(i + 1)) * s;
            } else {
                // outcome is currency0: its sales lower the tick; order below the tick (tickUpper < tick)
                int24 hi0 = base == t ? base - s : base;
                lo = hi0 - int24(int256(i + 1)) * s;
            }
            address owner = makeAddr(string(abi.encodePacked("owner", vm.toString(i))));
            deal(TYD, owner, amtTyd);
            vm.startPrank(owner);
            IERC20Like(TYD).approve(PERMIT2, type(uint256).max);
            IPermit2Approve(PERMIT2).approve(TYD, OM, type(uint160).max, type(uint48).max);
            uint32 id = IOrderManager(OM).createOrder(
                IOrderManager.CreateOrderParams({
                    poolKey: k,
                    amountIn: amtTyd,
                    tickLower: lo,
                    tickUpper: lo + s,
                    zeroForOne: l.zeroForOne,
                    enablePartialFill: false
                })
            );
            vm.stopPrank();
            l.owners[i] = owner;
            l.ids[i] = id;
            l.lo[i] = lo;
            l.hi[i] = lo + s;
            l.liq[i] = IOrderManager(OM).pendingOrder(k.toId(), id).liquidity;
            assertGt(l.liq[i], 0);
        }
    }

    /// outcome a fully filled order pays its owner (principal, rounded down as modifyLiquidity does)
    function _expectedFill(Ladder memory l, uint256 i) internal pure returns (uint256) {
        uint160 a = TickMath.getSqrtPriceAtTick(l.lo[i]);
        uint160 b = TickMath.getSqrtPriceAtTick(l.hi[i]);
        // zeroForOne order (TYD = currency0) ends as currency1; otherwise as currency0
        return l.zeroForOne
            ? SqrtPriceMath.getAmount1Delta(a, b, uint128(l.liq[i]), false)
            : SqrtPriceMath.getAmount0Delta(a, b, uint128(l.liq[i]), false);
    }

    function _filled(Ladder memory l, uint256 i) internal view returns (bool) {
        return IOrderManager(OM).pendingOrder(l.k.toId(), l.ids[i]).owner == address(0);
    }

    function _outcomeOf(PoolKey memory k) internal pure returns (address) {
        return Currency.unwrap(k.currency0) == TYD ? Currency.unwrap(k.currency1) : Currency.unwrap(k.currency0);
    }

    /// every filled order's owner holds exactly its fill (paid in this transaction); unfilled owners got nothing
    function _assertOwnersPaid(Ladder memory l) internal view returns (uint256 nFilled) {
        address out = _outcomeOf(l.k);
        for (uint256 i; i < l.owners.length; i++) {
            uint256 bal = IERC20Like(out).balanceOf(l.owners[i]);
            if (_filled(l, i)) {
                nFilled++;
                assertApproxEqAbs(bal, _expectedFill(l, i), 1, "filled owner not paid in the same transaction");
            } else {
                assertEq(bal, 0, "unfilled owner received outcome tokens");
            }
            assertEq(IERC20Like(TYD).balanceOf(l.owners[i]), 0, "owner TYD changed");
        }
    }

    function _omClaims(address token) internal view returns (uint256) {
        return PM.balanceOf(OM, uint256(uint160(token)));
    }

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }
}
