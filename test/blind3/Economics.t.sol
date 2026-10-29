// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console} from "forge-std/console.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Blind3Base} from "./Blind3Base.sol";
import {MockTruthMarket} from "../mocks/MockTruthMarket.sol";

/// Test-plan items 25-39: where the sum lands, size limits, minProfit, thresholds, decide-before-acting, PoolManager
/// balances, token cap, near-optimal size, protocol fee.
contract Blind3EconomicsTest is Blind3Base {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // ---------------------------------------------------------------- 25

    function test_e25_sumLands_mintSide() public {
        (Run memory a, Run memory b) = _pairMain(true, true, -50e6);
        _assertActedR(_main(), a, b);
        console.log("sum after trade / after module", a.sum, b.sum);
        assertGt(a.sum, 1.0095e18, "trade gap too small for this check");
        assertGe(b.sum, 1e18, "mint side pushed YES + NO below 1");
        assertLe(b.sum, 1.0095e18, "mint side stopped above 1.0095");
    }

    function test_e25_sumLands_burnSide() public {
        (Run memory a, Run memory b) = _pairMain(true, false, -50e18);
        _assertActedR(_main(), a, b);
        console.log("sum after trade / after module", a.sum, b.sum);
        assertLt(a.sum, 0.9905e18, "trade gap too small for this check");
        assertLe(b.sum, 1e18, "burn side pushed YES + NO above 1");
        assertGe(b.sum, 0.9905e18, "burn side stopped below 0.9905");
    }

    // ---------------------------------------------------------------- 26

    function test_e26_maxSizeBinding() public {
        _setParams(MIN_PROFIT, 1e6, THRESHOLD_BPS);
        (Run memory a, Run memory b) = _pairMain(true, true, -50e6);
        uint256 profit = _assertActedR(_main(), a, b);
        assertTrue(b.evMint);
        assertEq(b.evAmount, 1e6, "amount != maxSize");
        assertEq(b.yesMinted, 1e18, "minted YES != maxSize pairs");
        assertEq(profit, b.evProfit);
    }

    // ---------------------------------------------------------------- 27

    function test_e27_eventMatchesReality_mint() public {
        (Run memory a, Run memory b) = _pairMain(true, true, -50e6);
        uint256 profit = _assertActedR(_main(), a, b);
        assertTrue(b.evMint, "mint flag after a YES purchase");
        assertEq(b.evProfit, profit);
        assertEq(b.yesMintCount, 1, "one mint to the module");
        assertEq(b.evAmount * 1e12, b.yesMinted, "Rebalanced.amount x 1e12 != YES minted to the module");
        assertEq(b.modSwaps, 2, "exactly two swaps by the module");
    }

    function test_e27_eventMatchesReality_burn() public {
        (Run memory a, Run memory b) = _pairMain(true, false, -50e18);
        uint256 profit = _assertActedR(_main(), a, b);
        assertFalse(b.evMint, "burn flag after a YES sale");
        assertEq(b.evProfit, profit);
        assertEq(b.yesMintCount, 0, "minted on the burn side");
        assertEq(b.evAmount * 1e12, b.yesBurned, "Rebalanced.amount x 1e12 != YES burned by the module");
        assertEq(b.modSwaps, 2, "exactly two swaps by the module");
    }

    // ---------------------------------------------------------------- 28

    function test_e28_minProfitBlocks() public {
        uint256 s0 = vm.snapshotState();
        (Run memory c, Run memory d) = _pairMain(true, true, -50e6);
        uint256 p = _assertActedR(_main(), c, d); // control
        assertLt(p, 1_000e6);
        vm.revertToState(s0);
        _setParams(1_000e6, MAX_SIZE, THRESHOLD_BPS);
        (Run memory a, Run memory b) = _pairMain(true, true, -50e6);
        _assertIdleR(_main(), a, b);
        assertEq(b.modSwaps, 0);
    }

    // ---------------------------------------------------------------- 29

    function test_e29_tinyTrade_idle() public {
        uint256 s0 = vm.snapshotState();
        (Run memory a, Run memory b) = _pairMain(true, true, -1e4);
        _assertIdleR(_main(), a, b);
        // control: same setup, a larger purchase must be rebalanced
        vm.revertToState(s0);
        (Run memory c, Run memory d) = _pairMain(true, true, -50e6);
        _assertActedR(_main(), c, d);
        assertGt(d.o.recv, c.o.recv, "control: recipient balance did not increase");
    }

    function test_e29_threshold1bps_insideFeeBand_idle() public {
        uint256 s0 = vm.snapshotState();
        _setParams(MIN_PROFIT, MAX_SIZE, 1);
        (Run memory a, Run memory b) = _pairMain(true, true, -2e6);
        assertGt(a.sum, 1.0001e18, "gap not above the 1 bps threshold");
        assertLt(a.sum, 1.008e18, "gap not inside the hook-fee band");
        _assertIdleR(_main(), a, b);
        // control: a large purchase with the same settings is rebalanced
        vm.revertToState(s0);
        _setParams(MIN_PROFIT, MAX_SIZE, 1);
        (Run memory c, Run memory d) = _pairMain(true, true, -50e6);
        _assertActedR(_main(), c, d);
    }

    // ---------------------------------------------------------------- 30

    function test_e30_decideBeforeSideEffects() public {
        uint256 s0 = vm.snapshotState();
        (Run memory a0, Run memory b0) = _pairMain(true, true, -200e6);
        uint256 p = _assertActedR(_main(), a0, b0);
        console.log("profit P", p);
        vm.revertToState(s0);

        _setParams(p + 1, MAX_SIZE, THRESHOLD_BPS);
        (Run memory a, Run memory b) = _pairMain(true, true, -200e6);
        _assertIdleR(_main(), a, b);
        assertEq(b.modSwaps, 0, "a swap by the module (even in a reverted frame)");
        assertEq(b.modTransfers, 0, "a token moved to or from the module (even in a reverted frame)");
        assertEq(b.yesMintCount, 0);
        console.log("gas added", _gasAdded(a, b));
        assertLt(_gasAdded(a, b), 300_000, "deciding not to act cost >= 300k");
    }

    // ---------------------------------------------------------------- 31

    function test_e31_smallGaps_neverMintAndRevert() public {
        Mkt memory M = _main();
        uint256 x = 0.1e6;
        while (_postSum(M, T(true, true, -int256(x), 0)) <= 1.0081e18) {
            x += 0.1e6;
            assertLt(x, 20e6, "threshold search ran away");
        }
        uint256 start = x - 0.1e6;
        console.log("first 0.1-step purchase above 1.0081 (units)", x);
        uint256 idle;
        uint256 acted;
        uint256 s0 = vm.snapshotState();
        for (uint256 amt = start; amt <= start + 1.5e6; amt += 0.02e6) {
            vm.revertToState(s0);
            (Run memory a, Run memory b) = _pairT(M, T(true, true, -int256(amt), 0));
            _assertTraderSame(a.o, b.o);
            _assertEmptyM(M);
            if (b.o.recv == a.o.recv) {
                idle++;
                _assertIdleR(M, a, b);
                assertEq(b.yesMintCount, 0, string.concat("YES minted to the module, then reverted, at ", vm.toString(amt)));
                assertLt(_gasAdded(a, b), 300_000, "idle run cost >= 300k");
            } else {
                acted++;
                assertGt(b.o.recv, a.o.recv, "profit");
                assertGe(b.o.recv - a.o.recv, MIN_PROFIT);
            }
        }
        console.log("idle / acted", idle, acted);
        assertGt(idle, 0, "no idle amount: the sweep does not reach the fee band");
        assertGt(acted, 0, "no acting amount: the sweep does not reach a profitable gap");
    }

    // ---------------------------------------------------------------- 32

    function test_e32_nearBoundary_tinyOptIn() public {
        int24 t0 = _tick(kYes);
        int24 T6 = t0 + 6 * SPACING;
        int24 tb = T6 % SPACING == 0 ? T6 : (T6 > 0 ? (T6 / SPACING + 1) * SPACING : (T6 / SPACING) * SPACING);
        assertEq(tb % SPACING, 0);
        assertGe(tb, T6);
        assertLt(tb - SPACING, T6);
        lpRouter.modifyLiquidity(kYes, ModifyLiquidityParams(tb, tb + 600, 1e14, bytes32("nb")), "");
        // unflagged purchase that stops exactly on tb (YES is currency0: buying YES raises the tick)
        uint160 lim = TickMath.getSqrtPriceAtTick(tb);
        _swapRaw(kYes, _zfo(kYes, true), -1000e6, lim, "");
        (uint160 sp, int24 tk,,) = poolManager.getSlot0(kYes.toId());
        assertEq(sp, lim, "did not stop exactly on the boundary");
        assertEq(tk, tb);
        assertGt(_sum(), 1.015e18, "gap too small");

        uint256 s0 = vm.snapshotState();
        uint256[3] memory amts = [uint256(1), 2, 10];
        for (uint256 i; i < 3; i++) {
            vm.revertToState(s0);
            (Run memory a, Run memory b) = _pairMain(true, true, -int256(amts[i]));
            uint256 p = _assertActedR(_main(), a, b);
            assertGt(p, 0);
            assertTrue(b.evMint);
        }
    }

    // ---------------------------------------------------------------- 33 / 34: PoolManager short of YES

    function test_e33_pmShortOfYes_burnSide() public {
        uint256 s0 = vm.snapshotState();
        (Run memory a0, Run memory b0) = _pairMain(true, false, -200e18);
        _assertActedR(_main(), a0, b0);
        uint256 S = b0.evAmount;
        assertGt(S, 2, "normal size");
        vm.revertToState(s0);

        deal(YES, address(poolManager), (S / 2) * 1e12);
        (Run memory a, Run memory b) = _pairMain(true, false, -200e18);
        _assertActedR(_main(), a, b);
        assertFalse(b.evMint);
        assertLe(b.evAmount, S / 2, "bought more YES than the PoolManager holds");
        console.log("normal size / capped size", S, b.evAmount);
    }

    function test_e34_pmHoldsNoYes_idleCheap() public {
        uint256 s0 = vm.snapshotState();
        (Run memory c, Run memory d) = _pairMain(true, false, -200e18); // control: acts with normal balances
        _assertActedR(_main(), c, d);
        vm.revertToState(s0);
        deal(YES, address(poolManager), 0);
        (Run memory a, Run memory b) = _pairMain(true, false, -200e18);
        _assertIdleR(_main(), a, b);
        assertLe(_gasAdded(a, b), 60_000, "exit with no YES in the PoolManager cost > 60k");
    }

    // ---------------------------------------------------------------- 35: PoolManager short of TYD

    function test_e35_pmShortOfTyd_mintSide() public {
        uint256 s0 = vm.snapshotState();
        (Run memory a0, Run memory b0) = _pairMain(true, true, -50e6);
        _assertActedR(_main(), a0, b0);
        uint256 S = b0.evAmount;
        assertGt(S, 2);
        vm.revertToState(s0);

        deal(TYD, address(poolManager), S);
        (Run memory a, Run memory b) = _pairMain(true, true, -50e6);
        _assertActedR(_main(), a, b);
        assertTrue(b.evMint);
        assertLe(b.evAmount, S / 2, "took more than half the PoolManager's TYD");
        console.log("normal size / capped size", S, b.evAmount);
    }

    // ---------------------------------------------------------------- 36 / 37: token cap

    function test_e36_capBlocksMintSideOnly() public {
        market.setCap(yes.totalSupply());
        uint256 s0 = vm.snapshotState();
        (Run memory a, Run memory b) = _pairMain(true, true, -50e6);
        _assertIdleR(_main(), a, b);
        assertLe(_gasAdded(a, b), 80_000, "cap exit cost > 80k");
        vm.revertToState(s0);
        (Run memory c, Run memory d) = _pairMain(true, false, -200e18);
        _assertActedR(_main(), c, d);
        assertFalse(d.evMint);
    }

    function test_e37_partialCapRoom() public {
        uint256 s0 = vm.snapshotState();
        (Run memory a0, Run memory b0) = _pairMain(true, true, -50e6);
        _assertActedR(_main(), a0, b0);
        uint256 S = b0.evAmount;
        vm.revertToState(s0);

        uint256 R = S / 4;
        assertGt(R, 1e5, "normal size too small");
        uint256 cap = yes.totalSupply() + R * 1e12;
        market.setCap(cap);
        (Run memory a, Run memory b) = _pairMain(true, true, -50e6);
        _assertActedR(_main(), a, b);
        assertTrue(b.evMint);
        assertLe(b.evAmount, R, "minted past the cap room");
        assertLe(yes.totalSupply(), cap);
        assertLe(no.totalSupply(), cap);
    }

    // ---------------------------------------------------------------- 38: near-optimal size

    function _nearOptimal(bool buy, int256 amt) internal {
        uint256 s0 = vm.snapshotState();
        (Run memory a, Run memory b) = _pairMain(true, buy, amt);
        uint256 p = _assertActedR(_main(), a, b);
        uint256 x = b.evAmount;
        assertEq(b.evMint, buy);
        console.log("size / profit", x, p);

        vm.revertToState(s0);
        _setParams(MIN_PROFIT, x * 98 / 100, THRESHOLD_BPS);
        (Run memory c, Run memory d) = _pairMain(true, buy, amt);
        _assertTraderSame(c.o, d.o);
        assertLe(d.o.recv - c.o.recv, p, "a 2% smaller size earned more");
        assertLe(d.evAmount, x * 98 / 100);

        // outside actor at 1.02 x on the pre-rebalance state (no module)
        vm.revertToState(s0);
        _unplug();
        _tradeMain(kYes, buy, uint256(-amt), _magic());
        int256 outside = buy ? _outsideMintSell(x * 102 / 100) : _outsideBuyBurn(x * 102 / 100);
        console.log("outside actor at 1.02x");
        console.logInt(outside);
        assertLe(outside, int256(p), "a 2% larger size earns more than the module's");
    }

    function test_e38_nearOptimal_mint() public {
        _nearOptimal(true, -100e6);
    }

    function test_e38_nearOptimal_burn() public {
        _nearOptimal(false, -300e18);
    }

    // ---------------------------------------------------------------- 39: protocol fee

    function test_e39_protocolFeeBothWays_actsAndLandsLower() public {
        _protocolFee(kYes, 1000, 1000);
        _protocolFee(kNo, 1000, 1000);
        (Run memory a, Run memory b) = _pairMain(true, true, -50e6);
        _assertActedR(_main(), a, b);
        assertLe(b.sum, 1.0105e18, "sum above 1.0105");
        assertGe(b.sum, 1e18);
    }

    address internal constant YES5 = 0x3000000000000000000000000000000000000003; // < TYD: currency0
    address internal constant NO5 = 0xB00000000000000000000000000000000000000B; // > TYD: currency1

    /// deep market with YES + NO = pY + pN; YES is currency0 of its pool, NO is currency1 of its pool
    function _gapMarket(uint256 pY, uint256 pN) internal returns (Mkt memory M) {
        (MockTruthMarket m, PoolKey memory ky, PoolKey memory kn) = _newMarket(YES5, NO5, pY, pN, true, 1e17);
        module.register(address(m));
        M = _mkt(address(m), ky, kn);
    }

    /// control: without any protocol fee the gap beats the LP + hook fees and is rebalanced (state restored)
    function _controlNoFee(Mkt memory M, T memory t) internal {
        uint256 s = vm.snapshotState();
        (Run memory c, Run memory d) = _pairT(M, t);
        _assertActedR(M, c, d);
        vm.revertToState(s);
    }

    /// mint side, sum 1.0086: break-even ~1.00807 without a protocol fee, ~1.00908 with 0.1% on both module legs.
    /// The module sells YES (zeroForOne on the YES pool) and NO (oneForZero on the NO pool).
    function _asymMint(bool feeOnModuleLegs) internal returns (Run memory a, Run memory b, Mkt memory M) {
        M = _gapMarket(0.6e18, 0.4086e18);
        _controlNoFee(M, T(true, true, -1e4, 0));
        if (feeOnModuleLegs) {
            _protocolFee(M.ky, 1000, 0);
            _protocolFee(M.kn, 0, 1000);
        } else {
            _protocolFee(M.ky, 0, 1000);
            _protocolFee(M.kn, 1000, 0);
        }
        (a, b) = _pairT(M, T(true, true, -1e4, 0));
        console.log("sum", a.sum);
    }

    /// burn side, sum 0.9914: break-even ~0.99206 without, ~0.99107 with 0.1% on both module legs.
    /// The module buys YES (oneForZero on the YES pool) and NO (zeroForOne on the NO pool).
    function _asymBurn(bool feeOnModuleLegs) internal returns (Run memory a, Run memory b, Mkt memory M) {
        M = _gapMarket(0.6e18, 0.3914e18);
        _controlNoFee(M, T(true, false, -1e16, 0));
        if (feeOnModuleLegs) {
            _protocolFee(M.ky, 0, 1000);
            _protocolFee(M.kn, 1000, 0);
        } else {
            _protocolFee(M.ky, 1000, 0);
            _protocolFee(M.kn, 0, 1000);
        }
        (a, b) = _pairT(M, T(true, false, -1e16, 0));
        console.log("sum", a.sum);
    }

    function test_e39_asymmetricProtocolFee_mint_feeOnOtherDirection_acts() public {
        (Run memory a, Run memory b, Mkt memory M) = _asymMint(false);
        _assertActedR(M, a, b);
        assertTrue(b.evMint);
    }

    function test_e39_asymmetricProtocolFee_mint_feeOnModuleDirection_idle() public {
        (Run memory a, Run memory b, Mkt memory M) = _asymMint(true);
        _assertIdleR(M, a, b);
        assertLt(_gasAdded(a, b), 100_000, "fee-aware precheck should stop early");
    }

    function test_e39_asymmetricProtocolFee_burn_feeOnOtherDirection_acts() public {
        (Run memory a, Run memory b, Mkt memory M) = _asymBurn(false);
        _assertActedR(M, a, b);
        assertFalse(b.evMint);
    }

    function test_e39_asymmetricProtocolFee_burn_feeOnModuleDirection_idle() public {
        (Run memory a, Run memory b, Mkt memory M) = _asymBurn(true);
        _assertIdleR(M, a, b);
        assertLt(_gasAdded(a, b), 100_000, "fee-aware precheck should stop early");
    }
}
