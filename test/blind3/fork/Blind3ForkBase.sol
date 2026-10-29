// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Blind2ForkBase} from "../../blind2/fork/Blind2ForkBase.sol";
import {TruthMarketHookDemo} from "../../../src/trueo/hook/TruthMarketHookDemo.sol";
import {TrueoRebalancer} from "../../../src/TrueoRebalancer.sol";
import {IERC20Like, ITrueoMarket} from "../../../src/interfaces/ITrueo.sol";
import {RebalanceFlag} from "../../../src/libraries/RebalanceFlag.sol";

/// @notice Blind pass-3 fork helpers on top of Blind2ForkBase. Baseline = the REAL deployed hook code at
/// 0x3E83...e0C4 on the same snapshot; run = demo hook code at the same address + the module.
abstract contract Blind3ForkBase is Blind2ForkBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant CALL_OVERHEAD = 30_000;

    struct FRun {
        FOut o;
        uint256 nReb;
        bool evMint;
        uint256 evAmount;
        uint256 evProfit;
        uint256 modSwaps; // PoolManager Swap events with sender == module
    }

    /// module run configuration (applied after _installDemo)
    uint32 internal fGas = 5_000_000;
    uint32 internal fMin = 1_000_000;

    function _demoCfg(address r) internal {
        _installDemo(false);
        vm.startPrank(DEPLOYER);
        TruthMarketHookDemo(REAL_HOOK).setRebalancer(r);
        TruthMarketHookDemo(REAL_HOOK).setRebalanceGas(fGas);
        TruthMarketHookDemo(REAL_HOOK).setRebalanceGasMin(fMin);
        vm.stopPrank();
    }

    /// pre-funded trade: deal + approve first, then measure only the router call
    function _ftradeG(address m, bool yesSide, bool buy, uint256 amt) internal returns (FOut memory o) {
        PoolKey memory k = _pool(m, yesSide);
        address outcome = _outcome(m, yesSide);
        address tin = buy ? TYD : outcome;
        deal(tin, trader, IERC20Like(tin).balanceOf(trader) + amt);
        vm.prank(trader);
        IERC20Like(tin).approve(address(router), type(uint256).max);
        bool z = Currency.unwrap(k.currency0) == tin;
        vm.prank(trader);
        uint256 g = gasleft();
        BalanceDelta d = router.swap(
            k,
            SwapParams(z, -int256(amt), z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            swapHookData
        );
        uint256 used = g - gasleft();
        o = _fsnap(m);
        o.a0 = d.amount0();
        o.a1 = d.amount1();
        o.gas = used;
    }

    function _fparse(FRun memory r, Vm.Log[] memory logs) internal view {
        bytes32 mod = bytes32(uint256(uint160(address(module))));
        for (uint256 i; i < logs.length; i++) {
            Vm.Log memory l = logs[i];
            if (l.topics.length == 0) continue;
            if (l.emitter == address(module) && l.topics[0] == TrueoRebalancer.Rebalanced.selector) {
                r.nReb++;
                (r.evMint, r.evAmount, r.evProfit) = abi.decode(l.data, (bool, uint256, uint256));
            } else if (l.emitter == address(PM) && l.topics[0] == IPoolManager.Swap.selector && l.topics[2] == mod) {
                r.modSwaps++;
            }
        }
    }

    /// baseline on the real hook (word in hookData too: the real hook ignores it)
    function _fbase(address m, bool yesSide, bool buy, uint256 amt) internal returns (FRun memory r) {
        swapHookData = RebalanceFlag.encode();
        r.o = _ftradeG(m, yesSide, buy, amt);
    }

    /// same trade with the demo hook + module (fGas / fMin), logs parsed
    function _fmod(address m, bool yesSide, bool buy, uint256 amt) internal returns (FRun memory r) {
        _demoCfg(address(module));
        swapHookData = RebalanceFlag.encode();
        vm.recordLogs();
        vm.getRecordedLogs();
        r.o = _ftradeG(m, yesSide, buy, amt);
        _fparse(r, vm.getRecordedLogs());
    }

    /// baseline and module run from the same snapshot; state left as after the module run
    function _fpair(address m, bool yesSide, bool buy, uint256 amt) internal returns (FRun memory a, FRun memory b) {
        uint256 s0 = vm.snapshotState();
        a = _fbase(m, yesSide, buy, amt);
        vm.revertToState(s0);
        b = _fmod(m, yesSide, buy, amt);
    }

    /// acted: trader identical, one Rebalanced, recipient gain == event profit >= minProfit, module empty
    function _fActed(address m, FRun memory a, FRun memory b) internal view returns (uint256 profit) {
        _assertTraderSameF(a.o, b.o);
        assertGe(b.o.recv, a.o.recv, "recipient lost");
        profit = b.o.recv - a.o.recv;
        assertGe(profit, module.minProfit(), "module did not act");
        assertEq(b.nReb, 1, "exactly one Rebalanced");
        assertEq(b.evProfit, profit, "event profit != recipient gain");
        _assertModuleEmpty(m);
    }

    /// idle: trader identical, prices, fees and recipient unchanged, module empty
    function _fIdle(address m, FRun memory a, FRun memory b) internal view {
        _assertTraderSameF(a.o, b.o);
        assertEq(b.o.recv, a.o.recv, "recipient changed");
        assertEq(b.o.sY, a.o.sY, "YES pool price");
        assertEq(b.o.sN, a.o.sN, "NO pool price");
        assertEq(b.o.feeY, a.o.feeY, "fee YES pool");
        assertEq(b.o.feeN, a.o.feeN, "fee NO pool");
        _assertModuleEmpty(m);
    }

    function _dist(uint256 s) internal pure returns (uint256) {
        return s > 1e18 ? s - 1e18 : 1e18 - s;
    }

    function _gasAddedF(FRun memory a, FRun memory b) internal pure returns (uint256) {
        return b.o.gas > a.o.gas ? b.o.gas - a.o.gas : 0;
    }

    function _saleDownF(PoolKey memory k) internal pure returns (bool) {
        return Currency.unwrap(k.currency0) != TYD;
    }
}

/// @notice Fork base without the module (hook-only tests: burner sweeps), so these do not depend on the module.
abstract contract Blind3ForkHookBase is Blind3ForkBase {
    function setUp() public virtual override {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        uint256 blockNumber = vm.envOr("FORK_BLOCK", FORK_BLOCK);
        if (blockNumber == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, blockNumber);
        router = new PoolSwapTest(PM);
        _forkExtras();
    }
}
