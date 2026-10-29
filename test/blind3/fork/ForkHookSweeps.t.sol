// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Blind3ForkHookBase} from "./Blind3ForkBase.sol";
import {GasBurnerRebalancer} from "../../mocks/TestRebalancers.sol";
import {TwoSwapRouter} from "../../mocks/TwoSwapRouter.sol";
import {TruthMarketHookDemo} from "../../../src/trueo/hook/TruthMarketHookDemo.sol";
import {IERC20Like} from "../../../src/interfaces/ITrueo.sol";
import {RebalanceFlag} from "../../../src/libraries/RebalanceFlag.sol";

/// Test-plan items 54-55 on the Base fork: gas-limit sweeps with a rebalancer that burns all it gets. Hook only (no
/// module), so these run independently of the module implementation.
/// Run: BASE_RPC_URL=https://mainnet.base.org forge test --match-path "test/blind3/fork/*" -vv
contract Blind3ForkHookSweepsTest is Blind3ForkHookBase {
    GasBurnerRebalancer internal burner;
    TwoSwapRouter internal two;
    address[] internal coolList;
    address internal constant VM_ADDR = 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D;

    function setUp() public override {
        super.setUp();
        burner = new GasBurnerRebalancer();
        two = new TwoSwapRouter(PM);
    }

    function _swapCallF(PoolKey memory k, address tin, uint256 amt) internal view returns (bytes memory) {
        bool z = Currency.unwrap(k.currency0) == tin;
        return abi.encodeCall(
            PoolSwapTest.swap,
            (
                k,
                SwapParams(z, -int256(amt), z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
                PoolSwapTest.TestSettings(false, false),
                RebalanceFlag.encode()
            )
        );
    }

    /// funds the trader for a single opted-in swap and returns its calldata
    function _single(address m, bool yesSide, bool buy, uint256 amt) internal returns (bytes memory) {
        PoolKey memory k = _pool(m, yesSide);
        address tin = buy ? TYD : _outcome(m, yesSide);
        deal(tin, trader, IERC20Like(tin).balanceOf(trader) + amt * 4);
        vm.prank(trader);
        IERC20Like(tin).approve(address(router), type(uint256).max);
        return _swapCallF(k, tin, amt);
    }

    function _cfg(address r, uint32 reserve, uint32 minGas) internal {
        _installDemo(false);
        vm.startPrank(DEPLOYER);
        TruthMarketHookDemo(REAL_HOOK).setRebalancer(r);
        TruthMarketHookDemo(REAL_HOOK).setRebalanceGas(5_000_000);
        TruthMarketHookDemo(REAL_HOOK).setRebalanceGasReserve(reserve);
        TruthMarketHookDemo(REAL_HOOK).setRebalanceGasMin(minGas);
        vm.stopPrank();
    }

    function _go(address to, bytes memory data, uint256 g, bool asTrader) internal returns (bool ok, uint256 used) {
        if (asTrader) vm.prank(trader);
        uint256 before = gasleft();
        (ok,) = to.call{gas: g}(data);
        used = before - gasleft();
    }

    /// every account the trade touches (dry run with state-diff recording, rebalancer 0) plus the burner
    function _discover(address to, bytes memory data, bool asTrader, uint32 reserve, uint32 minGas) internal {
        coolList.push(address(burner));
        uint256 s = vm.snapshotState();
        _cfg(address(0), reserve, minGas);
        vm.startStateDiffRecording();
        _go(to, data, 30_000_000, asTrader);
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        vm.revertToState(s);
        for (uint256 i; i < acc.length; i++) {
            address a = acc[i].account;
            if (a == VM_ADDR || a == address(this)) continue;
            bool seen;
            for (uint256 j; j < coolList.length; j++) {
                if (coolList[j] == a) {
                    seen = true;
                    break;
                }
            }
            if (!seen) coolList.push(a);
        }
    }

    function _coolF() internal {
        for (uint256 i; i < coolList.length; i++) {
            vm.cool(coolList[i]);
        }
    }

    function _tryF(address r, address to, bytes memory data, uint256 g, bool asTrader, uint256 s0, uint32 reserve, uint32 minGas)
        internal
        returns (bool ok, uint256 used)
    {
        vm.revertToState(s0);
        _cfg(r, reserve, minGas);
        _coolF();
        (ok, used) = _go(to, data, g, asTrader);
    }

    // ---------------------------------------------------------------- 55: floor sweeps

    function _floorSweep(address to, bytes memory data, bool asTrader, string memory name) internal {
        _discover(to, data, asTrader, 150_000, 0);
        uint256 s0 = vm.snapshotState();
        (bool okP, uint256 plain) = _tryF(address(0), to, data, 30_000_000, asTrader, s0, 150_000, 0);
        assertTrue(okP, "plain trade failed");
        uint256 fired;
        uint256 passed;
        uint256 failedBase;
        for (uint256 g = plain - 50_000; g <= plain + 150_000 + 300_000; g += 2_000) {
            (bool okBase, uint256 usedBase) = _tryF(address(0), to, data, g, asTrader, s0, 150_000, 0);
            if (!okBase) {
                failedBase++;
                continue;
            }
            passed++;
            (bool ok, uint256 used) = _tryF(address(burner), to, data, g, asTrader, s0, 150_000, 0);
            assertTrue(ok, string.concat(name, ": fails with the burner at gas limit ", vm.toString(g)));
            if (used >= usedBase + 10_000) fired++;
        }
        console.log(name);
        console.log("  plain gas (cooled) / limits passing / burner fired", plain, passed, fired);
        console.log("  limits failing without the rebalancer", failedBase);
        assertGt(passed, 150, "sweep too sparse");
        assertGt(failedBase, 0, "sweep does not start below the plain trade's own threshold");
        assertGt(fired, 50, "the burner fired at too few limits");
        vm.revertToState(s0);
    }

    function test_f55_floorSweep_AERO_buyYes() public {
        bytes memory d = _single(AERO, true, true, 200e6);
        _floorSweep(address(router), d, true, "AERO buy YES 200");
    }

    function test_f55_floorSweep_AERO_sellYes() public {
        bytes memory d = _single(AERO, true, false, 10e18);
        _floorSweep(address(router), d, true, "AERO sell YES 10");
    }

    function test_f55_floorSweep_PUMP_buyNo() public {
        bytes memory d = _single(PUMP, false, true, 50e6);
        _floorSweep(address(router), d, true, "PUMP buy NO 50");
    }

    function test_f55_floorSweep_PUMP_sellNo() public {
        bytes memory d = _single(PUMP, false, false, 500e18);
        _floorSweep(address(router), d, true, "PUMP sell NO 500");
    }

    function test_f55_floorSweep_route_wordOnLastHop() public {
        (PoolKey memory ky, PoolKey memory kn) = _keys(AERO);
        deal(TYD, address(two), 1e12);
        deal(_outcome(AERO, true), address(two), 1e22);
        two.setHookData("", RebalanceFlag.encode());
        bool z1 = Currency.unwrap(ky.currency0) != TYD; // sell YES
        bool z2 = Currency.unwrap(kn.currency0) == TYD; // buy NO
        bytes memory d = abi.encodeCall(TwoSwapRouter.run, (ky, z1, 10e18, kn, z2, 10e6, trader));
        _floorSweep(address(two), d, false, "AERO route sell YES 10 -> buy NO 10 (word on hop 2)");
    }

    // ---------------------------------------------------------------- 54: reserve covers a later hop's order fill

    function test_f54_defaultReserve_laterHopFillsOrder_burnerSweep() public {
        (PoolKey memory ky, PoolKey memory kn) = _keys(PUMP);
        Ladder memory l = _orders(kn, 1, 10e6);
        deal(TYD, address(two), 1e12);
        deal(_outcome(PUMP, false), address(two), 1e22);
        two.setHookData(RebalanceFlag.encode(), "");
        bool z1 = Currency.unwrap(ky.currency0) == TYD; // buy YES
        bool z2 = Currency.unwrap(kn.currency0) != TYD; // sell NO
        bytes memory d = abi.encodeCall(TwoSwapRouter.run, (ky, z1, 50e6, kn, z2, 200e18, trader));
        uint256 s0 = vm.snapshotState();

        // guard: hop 2 fills the order, and its owner is paid in the same transaction
        (bool okG,) = _tryF(address(0), address(two), d, 30_000_000, false, s0, 1_000_000, 1_000_000);
        assertTrue(okG);
        assertTrue(_filled(l, 0), "hop 2 does not fill the order: case is vacuous");
        _assertOwnersPaid(l);

        uint256 fired;
        uint256 passed;
        for (uint256 g = 300_000; g <= 8_400_000; g += 100_000) {
            (bool okBase, uint256 usedBase) = _tryF(address(0), address(two), d, g, false, s0, 1_000_000, 1_000_000);
            if (!okBase) continue;
            passed++;
            (bool ok, uint256 used) = _tryF(address(burner), address(two), d, g, false, s0, 1_000_000, 1_000_000);
            assertTrue(ok, string.concat("route fails with the burner at gas limit ", vm.toString(g)));
            assertTrue(_filled(l, 0), "order not filled with the burner");
            if (used >= usedBase + 900_000) fired++;
        }
        console.log("route limits passing / burner fired", passed, fired);
        assertGt(passed, 50);
        assertGt(fired, 10, "the burner fired at too few limits");
        vm.revertToState(s0);
    }
}
