// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {TruthMarketHookDemo} from "../../src/trueo/hook/TruthMarketHookDemo.sol";
import {IOrderManager} from "../../src/trueo/hook/interfaces/IOrderManager.sol";
import {TrueoRebalancer} from "../../src/TrueoRebalancer.sol";
import {ITrueoManager, ITrueoMarket, IERC20Like} from "../../src/interfaces/ITrueo.sol";
import {ForkConstants} from "./ForkConstants.sol";
import {RebalanceFlag} from "../../src/libraries/RebalanceFlag.sol";

interface IFeeCollectorView {
    function poolFeeAccumulated(PoolId, Currency) external view returns (uint256);
}

/// @notice Base fork at FORK_BLOCK (env FORK_BLOCK overrides; 0 = latest) with the real Trueo contracts.
/// Skips every test when BASE_RPC_URL is unset. An archive endpoint is needed for a pinned block.
abstract contract ForkFixture is Test, ForkConstants {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint32 internal constant REBALANCE_GAS = 5_000_000;

    TrueoRebalancer internal module;
    PoolSwapTest internal router;
    address internal trader = makeAddr("trader");
    address internal recipient = makeAddr("recipient");
    /// hookData of every swap made through _swapAs/_buyAs/_sellAs (empty = no opt-in)
    bytes internal swapHookData;

    function setUp() public virtual {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        uint256 blockNumber = vm.envOr("FORK_BLOCK", FORK_BLOCK);
        if (blockNumber == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, blockNumber);
        router = new PoolSwapTest(PM);
        module = new TrueoRebalancer(PM, REAL_HOOK, ITrueoManager(MANAGER), CLONE_CODEHASH, address(this));
        module.setParams(recipient, 5, 10_000e6, 10);
        module.setEnabled(true);
        module.register(AERO);
        module.register(PUMP);
    }

    /// Puts the demo hook's code at 0x3E83...e0C4. The address already carries the flags (low bits 0x20C4) and
    /// the storage (roles, orderManager, feeCollector, swapValidator, initializers, pauses) stays. The constructor
    /// re-runs there: it re-grants the admin role (already held) and resets feeNumerator to 0 through its inline
    /// initializer, so the fee is restored from the value read before.
    function _installDemo(bool plugIn) internal {
        uint256 fee = TruthMarketHookDemo(REAL_HOOK).feeNumerator();
        deployCodeTo(
            "TruthMarketHookDemo.sol:TruthMarketHookDemo", abi.encode(PM, IOrderManager(OM), FC, DEPLOYER), REAL_HOOK
        );
        vm.prank(DEPLOYER);
        TruthMarketHookDemo(REAL_HOOK).setFeeRate(fee);
        if (plugIn) _plugIn();
    }

    function _plugIn() internal {
        vm.startPrank(DEPLOYER);
        TruthMarketHookDemo(REAL_HOOK).setRebalancer(address(module));
        TruthMarketHookDemo(REAL_HOOK).setRebalanceGas(REBALANCE_GAS);
        vm.stopPrank();
        _optIn();
    }

    /// swaps from here on carry the rebalance opt-in
    function _optIn() internal {
        swapHookData = RebalanceFlag.encode();
    }

    function _keys(address market) internal view returns (PoolKey memory kYes, PoolKey memory kNo) {
        return ITrueoMarket(market).getPoolKeys();
    }

    function _outcome(address market, bool yesSide) internal view returns (address) {
        return yesSide ? ITrueoMarket(market).yesToken() : ITrueoMarket(market).noToken();
    }

    /// TYD per whole outcome token, WAD
    function _price(PoolKey memory k, address outcome) internal view returns (uint256) {
        (uint160 s,,,) = PM.getSlot0(k.toId());
        if (Currency.unwrap(k.currency0) == outcome) {
            return FullMath.mulDiv(FullMath.mulDiv(s, s, 1 << 96), 1e30, 1 << 96);
        }
        return FullMath.mulDiv(FullMath.mulDiv(1 << 96, 1 << 96, s), 1e30, s);
    }

    function _sum(address market) internal view returns (uint256) {
        (PoolKey memory kYes, PoolKey memory kNo) = _keys(market);
        return _price(kYes, _outcome(market, true)) + _price(kNo, _outcome(market, false));
    }

    function _tick(PoolKey memory k) internal view returns (int24 t) {
        (, t,,) = PM.getSlot0(k.toId());
    }

    function _pool(address market, bool yesSide) internal view returns (PoolKey memory k) {
        (PoolKey memory kYes, PoolKey memory kNo) = _keys(market);
        return yesSide ? kYes : kNo;
    }

    /// `who` buys the outcome with `tydIn` TYD (exact in); funds itself with deal
    function _buyAs(address who, address market, bool yesSide, uint256 tydIn) internal returns (BalanceDelta) {
        PoolKey memory k = _pool(market, yesSide);
        deal(TYD, who, IERC20Like(TYD).balanceOf(who) + tydIn);
        return _swapAs(who, k, TYD, Currency.unwrap(k.currency0) == TYD, -int256(tydIn));
    }

    /// `who` sells `amount` of the outcome (exact in); funds itself with deal
    function _sellAs(address who, address market, bool yesSide, uint256 amount) internal returns (BalanceDelta) {
        PoolKey memory k = _pool(market, yesSide);
        address outcome = _outcome(market, yesSide);
        deal(outcome, who, IERC20Like(outcome).balanceOf(who) + amount);
        return _swapAs(who, k, outcome, Currency.unwrap(k.currency0) == outcome, -int256(amount));
    }

    function _swapAs(address who, PoolKey memory k, address tokenIn, bool zeroForOne, int256 amountSpecified)
        internal
        returns (BalanceDelta d)
    {
        vm.startPrank(who);
        IERC20Like(tokenIn).approve(address(router), type(uint256).max);
        d = router.swap(
            k,
            SwapParams(
                zeroForOne, amountSpecified, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(false, false),
            swapHookData
        );
        vm.stopPrank();
    }

    function _feeTyd(PoolKey memory k) internal view returns (uint256) {
        return IFeeCollectorView(FC).poolFeeAccumulated(k.toId(), Currency.wrap(TYD));
    }

    function _rebalances(Vm.Log[] memory logs) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == TrueoRebalancer.Rebalanced.selector) n++;
        }
    }

    function _assertModuleEmpty(address market) internal view {
        assertEq(IERC20Like(TYD).balanceOf(address(module)), 0);
        assertEq(IERC20Like(_outcome(market, true)).balanceOf(address(module)), 0);
        assertEq(IERC20Like(_outcome(market, false)).balanceOf(address(module)), 0);
    }
}
