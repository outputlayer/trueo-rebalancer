// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Blind3ForkBase} from "./Blind3ForkBase.sol";
import {IOrderManager} from "../../../src/trueo/hook/interfaces/IOrderManager.sol";
import {IERC20Like} from "../../../src/interfaces/ITrueo.sol";
import {RebalanceFlag} from "../../../src/libraries/RebalanceFlag.sol";

interface IPermit2Approve3 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// Audit guard (fork, block 53172900): burn-side rebalance whose NO purchase fills real OrderManager SELL orders
/// while the PoolManager holds no TYD. Owners must be paid their TYD in the same transaction (no PaymentDeferred).
contract Blind3ForkBurnPayoutTest is Blind3ForkBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant N_ORDERS = 5;
    uint128 internal constant ORDER_NO = 2e18; // 2 NO per order (~1 TYD)

    struct SellOrders {
        PoolKey k;
        address[] owners;
        uint32[] ids;
        uint128[] liq;
        int24[] lo;
        int24[] hi;
        bool zeroForOne; // input = outcome
    }

    /// `n` one-spacing orders that SELL the outcome of `k` for TYD, consecutive, just above the outcome's price
    /// (filled when the outcome is bought)
    function _sellOrders(PoolKey memory k, address outcome, uint256 n, uint128 amt)
        internal
        returns (SellOrders memory l)
    {
        l.k = k;
        l.owners = new address[](n);
        l.ids = new uint32[](n);
        l.liq = new uint128[](n);
        l.lo = new int24[](n);
        l.hi = new int24[](n);
        l.zeroForOne = Currency.unwrap(k.currency0) == outcome;
        int24 s = k.tickSpacing;
        int24 t = _tick(k);
        int24 base = _alignDown(t, s);
        for (uint256 i; i < n; i++) {
            int24 lo;
            if (l.zeroForOne) {
                // outcome is currency0: buying it raises the tick; order above the tick
                lo = base + int24(int256(i + 1)) * s;
            } else {
                // outcome is currency1: buying it lowers the tick; order below the tick
                int24 hi0 = base == t ? base - s : base;
                lo = hi0 - int24(int256(i + 1)) * s;
            }
            address owner = makeAddr(string(abi.encodePacked("seller", vm.toString(i))));
            deal(outcome, owner, amt);
            vm.startPrank(owner);
            IERC20Like(outcome).approve(PERMIT2, type(uint256).max);
            IPermit2Approve3(PERMIT2).approve(outcome, OM, type(uint160).max, type(uint48).max);
            uint32 id = IOrderManager(OM).createOrder(
                IOrderManager.CreateOrderParams({
                    poolKey: k,
                    amountIn: amt,
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
            l.liq[i] = uint128(IOrderManager(OM).pendingOrder(k.toId(), id).liquidity);
            assertGt(l.liq[i], 0);
            assertEq(IERC20Like(TYD).balanceOf(owner), 0);
        }
    }

    function _sFilled(SellOrders memory l, uint256 i) internal view returns (bool) {
        return IOrderManager(OM).pendingOrder(l.k.toId(), l.ids[i]).owner == address(0);
    }

    /// TYD a fully filled sell order pays (principal, rounded down as modifyLiquidity does)
    function _tydFill(SellOrders memory l, uint256 i) internal pure returns (uint256) {
        uint160 a = TickMath.getSqrtPriceAtTick(l.lo[i]);
        uint160 b = TickMath.getSqrtPriceAtTick(l.hi[i]);
        return l.zeroForOne
            ? SqrtPriceMath.getAmount1Delta(a, b, l.liq[i], false)
            : SqrtPriceMath.getAmount0Delta(a, b, l.liq[i], false);
    }

    /// every filled owner holds exactly its TYD now; unfilled owners hold none
    function _assertSellersPaid(SellOrders memory l) internal view returns (uint256 nFilled) {
        for (uint256 i; i < l.owners.length; i++) {
            uint256 bal = IERC20Like(TYD).balanceOf(l.owners[i]);
            if (_sFilled(l, i)) {
                nFilled++;
                assertApproxEqAbs(bal, _tydFill(l, i), 1, "filled seller not paid TYD in the same transaction");
            } else {
                assertEq(bal, 0, "unfilled seller received TYD");
            }
        }
    }

    struct T2 {
        int256 d;
        uint256 claimTyd; // trader's 6909 TYD claims
        uint256 trYes;
        uint256 recv;
        uint256 deferred; // PaymentDeferred events
        uint256 nReb;
        uint256 evProfit;
    }

    /// the trader sells YES with the opt-in, taking the TYD output as PoolManager claims (the PoolManager holds none)
    function _sellYesAsClaims(uint256 amt) internal returns (T2 memory r) {
        (PoolKey memory ky,) = _keys(PUMP);
        address yesT = _outcome(PUMP, true);
        deal(yesT, trader, amt);
        vm.prank(trader);
        IERC20Like(yesT).approve(address(router), type(uint256).max);
        bool z = Currency.unwrap(ky.currency0) == yesT;
        vm.recordLogs();
        vm.getRecordedLogs();
        vm.prank(trader);
        BalanceDelta d = router.swap(
            ky,
            SwapParams(z, -int256(amt), z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}),
            RebalanceFlag.encode()
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        r.d = BalanceDelta.unwrap(d);
        r.claimTyd = PM.balanceOf(trader, uint256(uint160(TYD)));
        r.trYes = IERC20Like(yesT).balanceOf(trader);
        r.recv = IERC20Like(TYD).balanceOf(recipient);
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length == 0) continue;
            if (logs[i].emitter == OM && logs[i].topics[0] == IOrderManager.PaymentDeferred.selector) r.deferred++;
            if (logs[i].emitter == address(module) && logs[i].topics[0] == bytes32(keccak256("Rebalanced(address,bool,uint256,uint256)"))) {
                r.nReb++;
                (,, r.evProfit) = abi.decode(logs[i].data, (bool, uint256, uint256));
            }
        }
    }

    function test_fb_burnSide_sellOrdersPaidSameTx_pmHoldsNoTyd_PUMP() public {
        (, PoolKey memory kn) = _keys(PUMP);
        address noT = _outcome(PUMP, false);
        // an earlier, unflagged NO dump (its own transaction) leaves a burn-side gap with the NO price low;
        // sell-NO orders are then placed just above that price, where the module's NO purchase will go
        swapHookData = "";
        _sellAs(makeAddr("earlier"), PUMP, false, 400e18);
        SellOrders memory l = _sellOrders(kn, noT, N_ORDERS, ORDER_NO);
        // the opted-in trade: a small YES sale, TYD out taken as claims since the PoolManager holds no TYD
        uint256 sellYes = 2e18;
        deal(TYD, address(PM), 0);
        uint256 s0 = vm.snapshotState();

        // baseline: the deployed hook
        T2 memory a = _sellYesAsClaims(sellYes);
        uint256 sumA = _sum(PUMP);
        assertLt(sumA, 0.99e18, "trade did not open a burn-side gap");
        for (uint256 i; i < N_ORDERS; i++) {
            assertFalse(_sFilled(l, i), "baseline trade fills a NO order");
        }
        vm.revertToState(s0);

        // module run
        _installDemo(true);
        T2 memory b = _sellYesAsClaims(sellYes);
        console.log("sum no module / module", sumA, _sum(PUMP));
        assertEq(b.d, a.d, "trader delta");
        assertEq(b.claimTyd, a.claimTyd, "trader TYD claims");
        assertEq(b.trYes, a.trYes, "trader YES");
        assertGe(b.recv, a.recv + module.minProfit(), "module did not rebalance");
        assertEq(b.nReb, 1);
        assertEq(b.evProfit, b.recv - a.recv);
        assertEq(b.deferred, 0, "OrderManager deferred a payment");
        uint256 nFilled = _assertSellersPaid(l);
        console.log("sell orders filled by the module", nFilled);
        // control: the module's purchase really filled orders and paid their owners
        assertGt(nFilled, 0, "no sell order filled by the module's NO purchase: case is vacuous");
        assertGt(IERC20Like(TYD).balanceOf(l.owners[0]), 0);
        _assertModuleEmpty(PUMP);
        assertEq(PM.balanceOf(address(module), uint256(uint160(TYD))), 0);
        assertEq(PM.balanceOf(address(module), uint256(uint160(noT))), 0);
    }
}
