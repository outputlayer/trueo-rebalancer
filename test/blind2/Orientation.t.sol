// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Blind2Base} from "./Blind2Base.sol";
import {DecTruthMarket} from "./utils/DecTruthMarket.sol";
import {TrueoRebalancer} from "../../src/TrueoRebalancer.sol";
import {ITrueoManager} from "../../src/interfaces/ITrueo.sol";
import {MockOutcomeToken} from "../mocks/MockOutcomeToken.sol";
import {MockTruthMarket} from "../mocks/MockTruthMarket.sol";

/// Shared per-trade checks for the orientation and decimals suites.
abstract contract Blind2OrientBase is Blind2Base {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// |YES + NO - 1| after the trade above which a rebalance MUST happen (far above LP + 0.8% hook fee +
    /// thresholdBps; same guard as test_I2_traderIdentical_knownGaps_allAct)
    uint256 internal constant MUST_ACT_GAP = 0.03e18;
    /// how far past 1 the module may push YES + NO (one leg's fees on each side, generous)
    uint256 internal constant OVERSHOOT = 0.02e18;

    struct G {
        PoolKey ky;
        PoolKey kn;
        address pay;
        address yesT;
        address noT;
        uint256 gap; // outcome decimals - payment decimals
        TrueoRebalancer mod;
    }

    struct R {
        int128 a0;
        int128 a1;
        uint256 trPay;
        uint256 trY;
        uint256 trN;
        uint256 recv;
        uint256 sum;
    }

    function _priceG(PoolKey memory k, address outcome, uint256 gap) internal view returns (uint256) {
        (uint160 s,,,) = poolManager.getSlot0(k.toId());
        uint256 d = 10 ** (18 + gap);
        if (Currency.unwrap(k.currency0) == outcome) return FullMath.mulDiv(FullMath.mulDiv(s, s, 1 << 96), d, 1 << 96);
        return FullMath.mulDiv(FullMath.mulDiv(1 << 96, 1 << 96, s), d, s);
    }

    function _sumG(G memory g) internal view returns (uint256) {
        return _priceG(g.ky, g.yesT, g.gap) + _priceG(g.kn, g.noT, g.gap);
    }

    function _r(G memory g, BalanceDelta d) internal view returns (R memory r) {
        r.a0 = d.amount0();
        r.a1 = d.amount1();
        r.trPay = ERC20(g.pay).balanceOf(trader);
        r.trY = ERC20(g.yesT).balanceOf(trader);
        r.trN = ERC20(g.noT).balanceOf(trader);
        r.recv = ERC20(g.pay).balanceOf(recipient);
        r.sum = _sumG(g);
    }

    function _swapG(G memory g, bool onYes, bool buy, uint256 amt) internal returns (R memory) {
        PoolKey memory k = onYes ? g.ky : g.kn;
        bool outIs0 = Currency.unwrap(k.currency0) != g.pay;
        bool zeroForOne = buy ? !outIs0 : outIs0;
        swapHookData = _magic();
        BalanceDelta d = _swap(k, zeroForOne, -int256(amt));
        return _r(g, d);
    }

    function _dist(uint256 s) internal pure returns (uint256) {
        return s > 1e18 ? s - 1e18 : 1e18 - s;
    }

    /// one trade vs the deployed hook: trader identical; module acts (exactly one Rebalanced, profit > 0) when
    /// the gap is large; YES + NO moves toward 1 and not past it by more than OVERSHOOT; module holds nothing
    function _checkTrade(G memory g, bool onYes, bool buy, uint256 amt) internal {
        uint256 s0 = vm.snapshotState();
        _installOriginal();
        R memory a = _swapG(g, onYes, buy, amt);
        vm.revertToState(s0);
        _plugWith(address(g.mod), REBALANCE_GAS);
        _startRec();
        R memory b = _swapG(g, onYes, buy, amt);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(a.a0, b.a0, "trader delta0");
        assertEq(a.a1, b.a1, "trader delta1");
        assertEq(a.trPay, b.trPay, "trader payment token");
        assertEq(a.trY, b.trY, "trader YES");
        assertEq(a.trN, b.trN, "trader NO");
        assertEq(ERC20(g.pay).balanceOf(address(g.mod)), 0, "module holds payment token");
        assertEq(ERC20(g.yesT).balanceOf(address(g.mod)), 0, "module holds YES");
        assertEq(ERC20(g.noT).balanceOf(address(g.mod)), 0, "module holds NO");

        if (_dist(a.sum) > MUST_ACT_GAP) {
            assertEq(_rebalances(logs), 1, "exactly one rebalance");
            assertGt(b.recv, a.recv, "no profit on a large gap");
        }
        if (b.recv == a.recv) {
            assertEq(b.sum, a.sum, "prices moved without profit");
        } else {
            assertLe(_dist(b.sum), _dist(a.sum), "YES+NO moved away from 1");
            if (a.sum > 1e18) assertGe(b.sum + OVERSHOOT, 1e18, "pushed YES+NO below 1 by more than fees");
            else assertLe(b.sum, 1e18 + OVERSHOOT, "pushed YES+NO above 1 by more than fees");
        }
        console.log("sum after trade / after module", a.sum, b.sum);
        console.log("profit", b.recv - a.recv);
        vm.revertToState(s0);
    }

    /// buy and sell in each pool: both mint-side and burn-side rebalances
    function _fourTrades(G memory g, uint256 buyAmt, uint256 sellAmt) internal {
        _checkTrade(g, true, true, buyAmt);
        _checkTrade(g, false, true, buyAmt);
        _checkTrade(g, true, false, sellAmt);
        _checkTrade(g, false, false, sellAmt);
    }
}

/// All four token orientations (YES currency0/currency1 x NO currency0/currency1), decimals gap 12.
contract Blind2OrientationTest is Blind2OrientBase {
    function _addr(uint8 top, uint8 low) internal pure returns (address) {
        return address((uint160(top) << 152) | uint160(low));
    }

    function _orient(bool yesIs0, bool noIs0) internal {
        // TYD = 0x50...05: an address below it is currency0 of its pool, above it currency1
        address y = yesIs0 ? _addr(0x11, 0x11) : _addr(0x91, 0x91);
        address n = noIs0 ? _addr(0x22, 0x22) : _addr(0xA2, 0xA2);
        (MockTruthMarket m, PoolKey memory ky, PoolKey memory kn) = _newMarket(y, n, 0.6e18, 0.4e18, true, 0);
        module.register(address(m));
        assertEq(Currency.unwrap(ky.currency0) == y, yesIs0, "YES orientation");
        assertEq(Currency.unwrap(kn.currency0) == n, noIs0, "NO orientation");
        G memory g = G(ky, kn, TYD, y, n, 12, module);
        _fourTrades(g, 50e6, 80e18);
    }

    function test_orient_yes0_no1() public {
        _orient(true, false);
    }

    function test_orient_yes1_no0() public {
        _orient(false, true);
    }

    function test_orient_yes0_no0() public {
        _orient(true, true);
    }

    function test_orient_yes1_no1() public {
        _orient(false, false);
    }
}

/// Decimals gaps other than 12 (payment token with 18 or 12 decimals vs 18-decimal outcomes), through the
/// test-only DecTruthMarket whose mint/burn rule is decimals-based; a gap-12 control runs the same path.
contract Blind2DecimalsTest is Blind2OrientBase {
    using PoolIdLibrary for PoolKey;

    function _addr(uint8 top, uint8 low) internal pure returns (address) {
        return address((uint160(top) << 152) | uint160(low));
    }

    function _sqrtG(uint256 priceWad, bool outIs0, uint256 gap) internal pure returns (uint160) {
        uint256 d = 10 ** (18 + gap);
        if (outIs0) return uint160(Math.sqrt(FullMath.mulDiv(priceWad, 1 << 192, d)));
        return uint160(Math.sqrt(FullMath.mulDiv(1 << 192, d, priceWad)));
    }

    function _initPoolG(PoolKey memory k, address outcome, uint256 priceWad, uint256 gap, uint128 liq) internal {
        bool outIs0 = Currency.unwrap(k.currency0) == outcome;
        poolManager.initialize(k, _sqrtG(priceWad, outIs0, gap));
        // validator bounds [0, 1] payment token per outcome, aligned as on the Aero pools
        int24 t1 = _alignDown(TickMath.getTickAtSqrtPrice(_sqrtG(1e18, outIs0, gap)), SPACING);
        if (outIs0) validator.setBoundaries(k.toId(), -887160, t1);
        else validator.setBoundaries(k.toId(), t1, 887220);
        lpRouter.modifyLiquidity(k, ModifyLiquidityParams(FULL_LO, FULL_HI, int256(uint256(liq)), 0), "");
    }

    /// a module for this market code (marketCodehash pins the code); size cap 10k whole payment tokens
    function _moduleFor(address dm, PoolKey memory ky, PoolKey memory kn, uint8 payDec, uint256 gap)
        internal
        virtual
        returns (TrueoRebalancer mod)
    {
        mod = new TrueoRebalancer(poolManager, HOOK, ITrueoManager(address(mgr)), dm.codehash, admin);
        vm.startPrank(admin);
        mod.setParams(recipient, 5, 10_000 * 10 ** uint256(payDec), THRESHOLD_BPS);
        mod.setEnabled(true);
        vm.stopPrank();
        mod.register(dm);
        assertEq(uint256(mod.marketOf(ky.toId()).gap), gap, "MarketInfo.gap");
        assertEq(uint256(mod.marketOf(kn.toId()).gap), gap, "MarketInfo.gap");
    }

    function _decMarket(uint8 payDec) internal returns (G memory g) {
        uint256 gap = 18 - uint256(payDec);
        address pay = _addr(0x50, 0x06); // just above TYD: same orientation as the fixture market
        address y = _addr(0x13, 0x13);
        address n = _addr(0x93, 0x93);
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("PAY", "PAY", payDec), pay);
        DecTruthMarket dm = new DecTruthMarket();
        deployCodeTo("MockOutcomeToken.sol:MockOutcomeToken", abi.encode("YD", address(dm)), y);
        deployCodeTo("MockOutcomeToken.sol:MockOutcomeToken", abi.encode("ND", address(dm)), n);
        dm.init(mgr, ERC20(pay), MockOutcomeToken(y), MockOutcomeToken(n), LP_FEE, SPACING, HOOK);
        assertEq(dm.factor(), 10 ** gap);
        mgr.setActive(address(dm), true);
        (PoolKey memory ky, PoolKey memory kn) = dm.getPoolKeys();

        TrueoRebalancer mod = _moduleFor(address(dm), ky, kn, payDec, gap);

        // liquidity holding the same WHOLE-token amounts as the gap-12 fixture (L scales with 10**((12-gap)/2))
        uint128 liq = uint128(uint256(LIQ) * 10 ** ((12 - gap) / 2));
        uint256 one = 10 ** uint256(payDec);
        MockERC20(pay).mint(address(this), 1e7 * one);
        MockERC20(pay).approve(address(dm), type(uint256).max);
        dm.mint(1e6 * one);
        MockERC20(pay).approve(address(lpRouter), type(uint256).max);
        MockOutcomeToken(y).approve(address(lpRouter), type(uint256).max);
        MockOutcomeToken(n).approve(address(lpRouter), type(uint256).max);
        _initPoolG(ky, y, 0.6e18, gap, liq);
        _initPoolG(kn, n, 0.4e18, gap, liq);

        MockERC20(pay).mint(trader, 1e6 * one);
        vm.startPrank(trader);
        MockERC20(pay).approve(address(router), type(uint256).max);
        MockOutcomeToken(y).approve(address(router), type(uint256).max);
        MockOutcomeToken(n).approve(address(router), type(uint256).max);
        MockERC20(pay).approve(address(dm), type(uint256).max);
        dm.mint(1000 * one); // 1000 YES and 1000 NO to sell
        vm.stopPrank();
        assertEq(ERC20(y).balanceOf(trader), 1000e18);

        g = G(ky, kn, pay, y, n, gap, mod);
        console.log("sum at start", _sumG(g));
    }

    function test_decimals_gap0_payment18() public {
        _fourTrades(_decMarket(18), 50e18, 80e18);
    }

    function test_decimals_gap6_payment12() public {
        _fourTrades(_decMarket(12), 50e12, 80e18);
    }

    /// control: the same decimals-generic path at the fixture's gap 12
    function test_decimals_gap12_control() public {
        _fourTrades(_decMarket(6), 50e6, 80e18);
    }
}
