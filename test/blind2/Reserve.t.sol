// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Blind2Base} from "./Blind2Base.sol";
import {TruthMarketHookDemo} from "../../src/trueo/hook/TruthMarketHookDemo.sol";
import {IOrderManager} from "../../src/trueo/hook/interfaces/IOrderManager.sol";
import {GasBurnerRebalancer} from "../mocks/TestRebalancers.sol";
import {TwoSwapRouter} from "../mocks/TwoSwapRouter.sol";

/// Gas-gate additions of the revised specification (the stub hook the tests were written against lacked them).
interface IGasMinHook {
    event RebalanceGasMinSet(uint32 rebalanceGasMin);

    function rebalanceGasMin() external view returns (uint32);
    function setRebalanceGasMin(uint32) external;
}

/// Property 5 (specification, revised gas gate): gate = avail := gasleft() - rebalanceGasReserve (0 if negative);
/// call the rebalancer iff avail >= rebalanceGasMin, with gas min(rebalanceGas, avail).: rebalanceGasReserve, storage layout, and "no gas limit at which a trade succeeds
/// without the rebalancer makes it fail with one".
contract Blind2ReserveTest is Blind2Base {
    address internal constant HOOK2 = address(uint160(0x8888 << 144) | uint160(0x20C4));

    event RebalanceGasReserveUpdated(uint32 oldReserve, uint32 newReserve);

    // ---------------------------------------------------------------- reserve setter

    function test_p5_reserveDefaultIsOneMillion() public view {
        assertEq(hook.rebalanceGasReserve(), 1_000_000);
    }

    function test_p5_reserveDefault_onFreshDemoDeploy() public {
        deployCodeTo(
            "TruthMarketHookDemo.sol:TruthMarketHookDemo",
            abi.encode(poolManager, IOrderManager(address(om)), address(fc), address(this)),
            HOOK2
        );
        assertEq(TruthMarketHookDemo(HOOK2).rebalanceGasReserve(), 1_000_000);
        assertEq(TruthMarketHookDemo(HOOK2).rebalanceGas(), 0);
        assertEq(address(TruthMarketHookDemo(HOOK2).rebalancer()), address(0));
    }

    function test_p5_onlyDefaultAdminSetsReserve() public {
        address op = makeAddr("operator");
        hook.grantRole(keccak256("OPERATOR_ROLE"), op);
        address[3] memory who = [trader, op, admin];
        for (uint256 i; i < 3; i++) {
            vm.prank(who[i]);
            vm.expectRevert(
                abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, who[i], bytes32(0))
            );
            hook.setRebalanceGasReserve(7);
        }
        assertEq(hook.rebalanceGasReserve(), 1_000_000);

        vm.expectEmit(true, true, true, true, HOOK);
        emit RebalanceGasReserveUpdated(1_000_000, 2_500_000);
        hook.setRebalanceGasReserve(2_500_000);
        assertEq(hook.rebalanceGasReserve(), 2_500_000);

        // another DEFAULT_ADMIN_ROLE holder may too (down to the floor, final fix pass; was 0)
        hook.grantRole(bytes32(0), op);
        uint32 floor = TruthMarketHookDemo(HOOK).MIN_REBALANCE_GAS_RESERVE();
        vm.prank(op);
        hook.setRebalanceGasReserve(floor);
        assertEq(hook.rebalanceGasReserve(), floor);
    }

    function test_p5_otherRebalancerSetters_adminOnly() public {
        vm.startPrank(trader);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, trader, bytes32(0))
        );
        hook.setRebalancer(address(module));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, trader, bytes32(0))
        );
        hook.setRebalanceGas(1);
        vm.stopPrank();
        vm.expectRevert(TruthMarketHookDemo.InvalidRebalancer.selector);
        hook.setRebalancer(makeAddr("eoa"));
    }

    // ---------------------------------------------------------------- storage layout

    /// slots 0-6 equal those of the original TruthMarketHook wired the same way; slot 7 packs
    /// rebalancer | rebalanceGas << 160 | reserve << 192; slot 8 is empty
    function test_p5_storageLayout() public {
        deployCodeTo(
            "TruthMarketHook.sol:TruthMarketHook",
            abi.encode(poolManager, IOrderManager(address(om)), address(fc), address(this)),
            HOOK2
        );
        TruthMarketHookDemo orig = TruthMarketHookDemo(HOOK2); // same ABI for the shared functions
        orig.setFeeRate(HOOK_FEE);
        orig.setSwapValidator(address(validator));
        orig.setAuthorizedPoolInitializer(address(this), true);

        hook.setRebalancer(address(module));
        hook.setRebalanceGas(5_000_000);
        hook.setRebalanceGasReserve(1_234_567);

        for (uint256 i; i < 7; i++) {
            assertEq(vm.load(HOOK, bytes32(i)), vm.load(HOOK2, bytes32(i)), "slot 0-6 differ from TruthMarketHook");
        }
        IGasMinHook(HOOK).setRebalanceGasMin(777_777);
        uint256 want = uint256(uint160(address(module))) | (uint256(5_000_000) << 160) | (uint256(1_234_567) << 192)
            | (uint256(777_777) << 224);
        assertEq(uint256(vm.load(HOOK, bytes32(uint256(7)))), want, "slot 7 packing");
        assertEq(vm.load(HOOK, bytes32(uint256(8))), bytes32(0), "slot 8");
        assertEq(vm.load(HOOK2, bytes32(uint256(7))), bytes32(0));
        // a few known values in the shared slots
        assertEq(uint256(vm.load(HOOK, bytes32(uint256(1)))), HOOK_FEE, "feeNumerator slot 1");
        assertEq(address(uint160(uint256(vm.load(HOOK, bytes32(uint256(2)))))), address(om), "orderManager slot 2");
        assertEq(address(uint160(uint256(vm.load(HOOK, bytes32(uint256(3)))))), address(fc), "feeCollector slot 3");
        assertEq(address(uint160(uint256(vm.load(HOOK, bytes32(uint256(4)))))), address(validator), "validator slot 4");
        assertTrue(hook.authorizedPoolInitializers(address(this)));
    }

    /// defaults packed in slot 7 right after deploy: reserve 1M (bits 192-223), min 750k (bits 224-255)
    function test_p5_slot7_defaults() public view {
        assertEq(uint256(vm.load(HOOK, bytes32(uint256(7)))), (uint256(1_000_000) << 192) | (uint256(750_000) << 224));
        assertEq(vm.load(HOOK, bytes32(uint256(8))), bytes32(0));
    }

    // ---------------------------------------------------------------- rebalanceGasMin setter

    function test_p5_gasMinDefault_andAdminOnly() public {
        assertEq(IGasMinHook(HOOK).rebalanceGasMin(), 750_000);
        address op = makeAddr("operator");
        hook.grantRole(keccak256("OPERATOR_ROLE"), op);
        address[3] memory who = [trader, op, admin];
        for (uint256 i; i < 3; i++) {
            vm.prank(who[i]);
            vm.expectRevert(
                abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, who[i], bytes32(0))
            );
            IGasMinHook(HOOK).setRebalanceGasMin(5);
        }
        assertEq(IGasMinHook(HOOK).rebalanceGasMin(), 750_000);
        vm.expectEmit(false, false, false, true, HOOK);
        emit IGasMinHook.RebalanceGasMinSet(250_000);
        IGasMinHook(HOOK).setRebalanceGasMin(250_000);
        assertEq(IGasMinHook(HOOK).rebalanceGasMin(), 250_000);
        // the other packed fields are untouched
        assertEq(hook.rebalanceGasReserve(), 1_000_000);
        assertEq(uint256(vm.load(HOOK, bytes32(uint256(7)))) >> 224, 250_000);
    }

    // ---------------------------------------------------------------- gas sweep

    GasBurnerRebalancer internal burner;
    TwoSwapRouter internal two;

    function _callData(bool route) internal view returns (address to, bytes memory data) {
        if (route) {
            bool yOut0 = Currency.unwrap(kYes.currency0) != TYD;
            bool nOut0 = Currency.unwrap(kNo.currency0) != TYD;
            // buy YES with 40 TYD (flag), then buy NO with 30 TYD (no flag)
            return (
                address(two),
                abi.encodeCall(TwoSwapRouter.run, (kYes, !yOut0, 40e6, kNo, !nOut0, 30e6, trader))
            );
        }
        bool z = Currency.unwrap(kYes.currency0) == TYD; // buy YES
        return (
            address(router),
            abi.encodeCall(
                PoolSwapTest.swap,
                (
                    kYes,
                    SwapParams(z, -int256(40e6), z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
                    PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                    _magic()
                )
            )
        );
    }

    function _try(bool route, uint256 g) internal returns (bool ok, uint256 used) {
        (address to, bytes memory data) = _callData(route);
        vm.prank(trader);
        uint256 before = gasleft();
        (ok,) = to.call{gas: g}(data);
        used = before - gasleft();
    }

    /// smallest gas at which the trade succeeds with rebalancer = 0 (binary search, state reverted each try)
    function _threshold(bool route, uint256 s0) internal returns (uint256 lo) {
        lo = 30_000;
        uint256 hi = 4_000_000;
        while (hi - lo > 200) {
            uint256 mid = (lo + hi) / 2;
            vm.revertToState(s0);
            _unplug();
            (bool ok,) = _try(route, mid);
            if (ok) hi = mid;
            else lo = mid;
        }
        lo = hi;
    }

    function _sweep(bool route) internal {
        burner = new GasBurnerRebalancer();
        two = new TwoSwapRouter(poolManager);
        tyd.transfer(address(two), 1e9);
        two.setHookData(_magic(), "");
        hook.setRebalanceGas(REBALANCE_GAS);
        uint256 s0 = vm.snapshotState();

        uint256 g0 = _threshold(route, s0);
        assertGt(g0, 50_000, "threshold sanity");
        uint256 fired;
        uint256 partialFires; // fired with less than rebalanceGas (avail < rebalanceGas)
        uint256 firstFire;
        uint256 g = g0 + 5_000; // margin for the hook's opt-in/gate check itself (a few hundred gas)
        while (g <= 9_000_000) {
            vm.revertToState(s0);
            _unplug();
            (bool okBase, uint256 usedBase) = _try(route, g);
            vm.revertToState(s0);
            hook.setRebalancer(address(burner));
            (bool ok, uint256 used) = _try(route, g);
            if (okBase) assertTrue(ok, "trade fails with a gas-burning rebalancer where it succeeds without");
            // the burner eats everything it is given, and it is given at least rebalanceGasMin (default 750k)
            if (ok && okBase && used >= usedBase + 700_000) {
                fired++;
                if (firstFire == 0) firstFire = g;
                if (used < usedBase + REBALANCE_GAS) partialFires++;
                assertLe(used, usedBase + REBALANCE_GAS + 30_000, "rebalancer got more than rebalanceGas");
            }
            // fine steps where avail crosses rebalanceGasMin and where it crosses rebalanceGas
            // (each firing burns up to rebalanceGas: ~45 points keep the test far below Foundry's per-test gas cap)
            g += (g > 1_800_000 && g < 3_200_000) ? 31_013 : (g > 6_000_000 && g < 7_000_000) ? 97_003 : 331_013;
        }
        assertGt(fired, 10, "the burner never fired: sweep proves nothing");
        assertGt(partialFires, 5, "no firing with avail between rebalanceGasMin and rebalanceGas");
        // avail >= rebalanceGasMin (750k) needs gasleft() >= reserve + min = 1.75M at the hook
        assertGt(firstFire, 1_750_000, "fired with avail below rebalanceGasMin");
        assertLe(firstFire, 3_000_000, "burner fires only far above reserve + rebalanceGasMin");
        vm.revertToState(s0);
        hook.setRebalancer(address(burner));
        (bool okTop, uint256 usedTop) = _try(route, 9_000_000);
        assertTrue(okTop);
        assertGe(usedTop, REBALANCE_GAS, "burner did not get rebalanceGas at 9M");
    }

    function test_p5_gasSweep_singleSwap_burnerNeverBreaksTrade() public {
        _sweep(false);
    }

    function test_p5_gasSweep_twoSwapRoute_flagOnFirst() public {
        _sweep(true);
    }

    /// reserve raised to 3M: the burner fires only when gasleft() at the hook >= reserve + min (3.75M); the trade
    /// always succeeds
    function test_p5_reserveRaised_skipsRebalancerBelowThreshold() public {
        burner = new GasBurnerRebalancer();
        hook.setRebalancer(address(burner));
        hook.setRebalanceGas(REBALANCE_GAS);
        hook.setRebalanceGasReserve(3_000_000);
        two = new TwoSwapRouter(poolManager);
        (bool ok, uint256 used) = _try(false, 3_600_000);
        assertTrue(ok);
        assertLt(used, 700_000, "fired although avail < rebalanceGasMin");
        (ok, used) = _try(false, 9_500_000);
        assertTrue(ok);
        assertGe(used, REBALANCE_GAS, "did not get rebalanceGas with plenty of gas");
    }

    // ---------------------------------------------------------------- the real module under a tight limit

    /// gas used by the opted-in trade with the rebalancer unplugged (state restored)
    function _plainGas(uint256 s0) internal returns (uint256 used) {
        vm.revertToState(s0);
        _unplug();
        bool ok;
        (ok, used) = _try(false, 3_000_000);
        assertTrue(ok);
    }

    /// trader gas = no-module gas + reserve + 1.5M with rebalanceGas 5M: avail lies between rebalanceGasMin and
    /// rebalanceGas, so the module runs with less gas than rebalanceGas and still delivers on a profitable gap
    function test_p5_tightLimit_moduleRunsWithLessGas() public {
        hook.setRebalanceGas(REBALANCE_GAS);
        uint256 s0 = vm.snapshotState();
        uint256 used0 = _plainGas(s0);
        uint256 limit = used0 + 1_000_000 + 1_500_000;

        vm.revertToState(s0);
        _installOriginal();
        (bool okA,) = _try(false, limit);
        assertTrue(okA);
        Out memory a = _snapOut(kYes, kNo);

        vm.revertToState(s0);
        hook.setRebalancer(address(module));
        vm.expectCall(address(module), _onSwapSel(), 1);
        (bool ok, uint256 used) = _try(false, limit);
        assertTrue(ok, "trade failed under the tight limit");
        Out memory b = _snapOut(kYes, kNo);
        _assertTraderSame(a, b);
        _assertActed(a, b, MIN_PROFIT);
        assertLt(used, used0 + REBALANCE_GAS, "module cannot have had rebalanceGas here");
    }

    /// avail below rebalanceGasMin: the module is not called at all, the trade is the deployed hook's
    function test_p5_belowGasMin_moduleSkipped() public {
        hook.setRebalanceGas(REBALANCE_GAS);
        uint256 s0 = vm.snapshotState();
        uint256 used0 = _plainGas(s0);
        uint256 limit = used0 + 1_000_000 + 400_000;

        vm.revertToState(s0);
        _installOriginal();
        (bool okA,) = _try(false, limit);
        assertTrue(okA);
        Out memory a = _snapOut(kYes, kNo);

        vm.revertToState(s0);
        hook.setRebalancer(address(module));
        vm.expectCall(address(module), _onSwapSel(), 0);
        (bool ok,) = _try(false, limit);
        assertTrue(ok);
        _assertIdle(a, _snapOut(kYes, kNo));
    }

    /// rebalanceGasMin lowered to 200k: the same limit now runs the module (with ~400k avail)
    function test_p5_lowerGasMin_enablesCall() public {
        hook.setRebalanceGas(REBALANCE_GAS);
        IGasMinHook(HOOK).setRebalanceGasMin(200_000);
        uint256 s0 = vm.snapshotState();
        uint256 used0 = _plainGas(s0);
        vm.revertToState(s0);
        hook.setRebalancer(address(module));
        vm.expectCall(address(module), _onSwapSel(), 1);
        (bool ok,) = _try(false, used0 + 1_000_000 + 400_000);
        assertTrue(ok);
        _assertModuleEmpty();
    }
}
