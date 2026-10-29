// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console} from "forge-std/console.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Blind2Base} from "./Blind2Base.sol";
import {TrueoRebalancer} from "../../src/TrueoRebalancer.sol";
import {MockTruthMarket} from "../mocks/MockTruthMarket.sol";

/// Property 8: validator bounds below MIN_TICK, recipient checks, per-market switch, protocol-fee-aware
/// precheck, unpriced pool.
contract Blind2FixesTest is Blind2Base {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    address internal constant YES2 = 0x2000000000000000000000000000000000000002;
    address internal constant NO2 = 0xA00000000000000000000000000000000000000A;
    address internal constant YES3 = 0x3000000000000000000000000000000000000003;
    address internal constant NO3 = 0xB00000000000000000000000000000000000000B;
    address internal constant YES4 = 0x4000000000000000000000000000000000000004;
    address internal constant NO4 = 0xC00000000000000000000000000000000000000C;

    event MarketEnabledSet(address indexed market, bool enabled);
    event ParamsSet(address profitRecipient, uint256 minProfit, uint256 maxSize, uint16 thresholdBps);

    // ---------------------------------------------------------------- validator bounds beyond the tick range

    function _wideBounds(bool upperToo) internal {
        validator.setBoundaries(kYes.toId(), -1_000_000, upperToo ? int24(1_000_000) : int24(-276360));
        validator.setBoundaries(kNo.toId(), -1_000_000, upperToo ? int24(1_000_000) : int24(887220));
    }

    function _actsVsDeployed(PoolKey memory k, bool buy, uint256 amt) internal {
        uint256 s0 = vm.snapshotState();
        _installOriginal();
        Out memory a = _tradeMain(k, buy, amt, _magic());
        vm.revertToState(s0);
        _plugWith(address(module), REBALANCE_GAS);
        Out memory b = _tradeMain(k, buy, amt, _magic());
        _assertTraderSame(a, b);
        _assertActed(a, b, MIN_PROFIT);
    }

    /// mint side: the module sells YES (YES is currency0: the tick falls toward the lower bound)
    function test_p8_lowerBoundBelowMinTick_mint() public {
        _wideBounds(false);
        _actsVsDeployed(kYes, true, 50e6);
    }

    /// burn side: the module buys NO (NO is currency1: the tick falls toward the lower bound)
    function test_p8_lowerBoundBelowMinTick_burn() public {
        _wideBounds(false);
        _actsVsDeployed(kYes, false, 80e18);
    }

    function test_p8_bothBoundsBeyondTickRange() public {
        _wideBounds(true);
        _actsVsDeployed(kNo, true, 50e6);
        _actsVsDeployed(kNo, false, 80e18);
    }

    // ---------------------------------------------------------------- setParams recipient checks

    function _rejects(address r) internal {
        vm.prank(admin);
        (bool ok, bytes memory ret) =
            address(module).call(abi.encodeCall(TrueoRebalancer.setParams, (r, MIN_PROFIT, MAX_SIZE, THRESHOLD_BPS)));
        assertFalse(ok, "recipient accepted");
        bytes4 sel = bytes4(ret);
        assertTrue(
            sel == TrueoRebalancer.BadParams.selector || sel == TrueoRebalancer.ZeroAddress.selector,
            "unexpected error"
        );
        assertEq(module.profitRecipient(), recipient, "recipient changed");
    }

    function test_p8_setParams_rejectsModuleAndPoolManagerAndZero() public {
        _rejects(address(module));
        _rejects(address(poolManager));
        _rejects(address(0));
    }

    function test_p8_setParams_acceptsOrdinaryRecipient_adminOnly() public {
        address r2 = makeAddr("r2");
        vm.prank(trader);
        vm.expectRevert(TrueoRebalancer.NotAdmin.selector);
        module.setParams(r2, 5, 1e6, 20);
        vm.expectEmit(false, false, false, true, address(module));
        emit ParamsSet(r2, 5, 1e6, 20);
        vm.prank(admin);
        module.setParams(r2, 5, 1e6, 20);
        assertEq(module.profitRecipient(), r2);
        assertEq(module.minProfit(), 5);
        assertEq(module.maxSize(), 1e6);
        assertEq(module.thresholdBps(), 20);
    }

    // ---------------------------------------------------------------- per-market switch

    function test_p8_setMarketEnabled_adminOnly_andEvent() public {
        vm.prank(trader);
        vm.expectRevert(TrueoRebalancer.NotAdmin.selector);
        module.setMarketEnabled(address(market), false);
        assertFalse(module.marketDisabled(address(market)));

        vm.expectEmit(true, false, false, true, address(module));
        emit MarketEnabledSet(address(market), false);
        vm.prank(admin);
        module.setMarketEnabled(address(market), false);
        assertTrue(module.marketDisabled(address(market)));

        vm.expectEmit(true, false, false, true, address(module));
        emit MarketEnabledSet(address(market), true);
        vm.prank(admin);
        module.setMarketEnabled(address(market), true);
        assertFalse(module.marketDisabled(address(market)));
    }

    function test_p8_setMarketEnabled_stopsOnlyThatMarket() public {
        (MockTruthMarket m2, PoolKey memory ky2, PoolKey memory kn2) = _newMarket(YES2, NO2, 0.6e18, 0.4e18, true, 0);
        module.register(address(m2));
        vm.prank(admin);
        module.setMarketEnabled(address(market), false);

        uint256 s0 = vm.snapshotState();
        _installOriginal();
        Out memory a1 = _tradeMain(kYes, true, 50e6, _magic());
        Out memory a2 = _trade(ky2, true, 50e6, _magic(), ky2, kn2);
        vm.revertToState(s0);

        _plugWith(address(module), REBALANCE_GAS);
        Out memory b1 = _tradeMain(kYes, true, 50e6, _magic());
        _assertIdle(a1, b1); // market 1: off
        Out memory b2 = _trade(ky2, true, 50e6, _magic(), ky2, kn2);
        _assertTraderSame(a2, b2);
        assertGt(b2.recv, b1.recv, "market 2 not rebalanced"); // market 2: on
        assertEq(MockTruthMarket(address(m2)).yesToken().balanceOf(address(module)), 0);
        assertEq(MockTruthMarket(address(m2)).noToken().balanceOf(address(module)), 0);
        _assertModuleEmpty();

        // switch market 1 back on: it rebalances again
        vm.prank(admin);
        module.setMarketEnabled(address(market), true);
        uint256 r = tyd.balanceOf(recipient);
        _tradeMain(kYes, true, 50e6, _magic());
        assertGt(tyd.balanceOf(recipient), r, "market 1 not back on");
    }

    // ---------------------------------------------------------------- protocol fee in the precheck

    /// YES + NO = 1.0086: beats LP fee (1 pip) + hook fee (0.8%) [threshold ~1.00807] but not once a 0.1%
    /// protocol fee is added on both pools [threshold ~1.00909]
    function _gapMarket() internal returns (PoolKey memory ky, PoolKey memory kn) {
        MockTruthMarket m3;
        (m3, ky, kn) = _newMarket(YES3, NO3, 0.6e18, 0.4086e18, true, 1e17);
        module.register(address(m3));
        console.log("sum before", _sumOf(ky, kn));
    }

    function _protocolFee(PoolKey memory ky, PoolKey memory kn) internal {
        vm.prank(address(0x4444)); // PoolManager owner in the local deployment
        poolManager.setProtocolFeeController(address(this));
        uint24 pf = 1000 | (1000 << 12);
        poolManager.setProtocolFee(ky, pf);
        poolManager.setProtocolFee(kn, pf);
        (,, uint24 got,) = poolManager.getSlot0(ky.toId());
        assertEq(got, pf);
    }

    function _gapRun(bool withProtocolFee) internal returns (Out memory a, Out memory b) {
        (PoolKey memory ky, PoolKey memory kn) = _gapMarket();
        if (withProtocolFee) _protocolFee(ky, kn);
        uint256 s0 = vm.snapshotState();
        _unplug(); // same hook code, rebalancer = 0: the gas baseline
        a = _trade(ky, true, 1e4, _magic(), ky, kn);
        vm.revertToState(s0);
        _plugWith(address(module), REBALANCE_GAS);
        b = _trade(ky, true, 1e4, _magic(), ky, kn);
        _assertTraderSame(a, b);
        console.log("module gas", b.gas - a.gas);
    }

    /// control: without the protocol fee the same gap is rebalanced (so the next test is not vacuous)
    function test_p8_gapBeatsFees_withoutProtocolFee_rebalanced() public {
        (Out memory a, Out memory b) = _gapRun(false);
        assertGt(b.recv, a.recv, "control: gap not rebalanced without a protocol fee");
    }

    function test_p8_protocolFee_gapBeatsOnlyLpFee_cheapNoop() public {
        (Out memory a, Out memory b) = _gapRun(true);
        _assertIdle(a, b);
        assertLt(b.gas - a.gas, 60_000, "precheck too expensive");
    }

    // ---------------------------------------------------------------- unpriced pool

    function test_p8_unpricedPool_onSwapReturns() public {
        (MockTruthMarket m4, PoolKey memory ky, PoolKey memory kn) = _newMarket(YES4, NO4, 0.6e18, 0, false, 0);
        module.register(address(m4));
        (uint160 sN,,,) = poolManager.getSlot0(kn.toId());
        assertEq(sN, 0, "NO pool must be unpriced");

        vm.prank(HOOK);
        module.onSwap(ky);
        vm.prank(HOOK);
        module.onSwap(kn);

        // and through a real opted-in trade on the priced pool
        _plugWith(address(module), REBALANCE_GAS);
        uint256 s0 = vm.snapshotState();
        _unplug();
        Out memory a = _trade(ky, true, 50e6, _magic(), ky, ky);
        vm.revertToState(s0);
        Out memory b = _trade(ky, true, 50e6, _magic(), ky, ky);
        _assertIdle(a, b);
        assertLt(b.gas - a.gas, 60_000, "unpriced pool not an early exit");
        assertEq(MockTruthMarket(address(m4)).yesToken().balanceOf(address(module)), 0);
    }
}
