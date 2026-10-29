// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Blind3ForkBase} from "./Blind3ForkBase.sol";
import {TruthMarketHookDemo} from "../../../src/trueo/hook/TruthMarketHookDemo.sol";
import {IOrderManager} from "../../../src/trueo/hook/interfaces/IOrderManager.sol";
import {TrueoRebalancer} from "../../../src/TrueoRebalancer.sol";
import {IERC20Like, ITrueoMarket, ITrueoManager} from "../../../src/interfaces/ITrueo.sol";
import {RebalanceFlag} from "../../../src/libraries/RebalanceFlag.sol";

/// TruthMarketManager (0x61A9...95d7, implementation 0x7BDa...5999; ABI from Sourcify)
interface IManagerAdmin {
    function truthMarketMastercopy() external view returns (address);
    function oracleCouncilAddress() external view returns (address);
    function paymentToken() external view returns (address);
    function safeBoxAddress() external view returns (address);
    function uniswapV3Factory() external view returns (address);
    function rewardWallet() external view returns (address);
    function escalationAddress() external view returns (address);
    function truthMarketV2Mastercopy() external view returns (address);
    function uniswapV4HookAddress() external view returns (address);
    function setAddresses(address, address, address, address, address, address, address, address, address) external;
    function createMarketV2(
        string memory question,
        string memory source,
        string memory info,
        uint256 endOfTrading,
        uint256 yesNoTokenCap,
        address rewardToken,
        uint256 rewardAmount,
        string memory yesSymbol,
        string memory noSymbol,
        uint24 fee,
        int24 tickSpacing
    ) external returns (address);
}

interface IFeeCollectorAdmin {
    function setHookAddress(address) external;
}

/// Test-plan item 64: a new market created through the real manager pointed at a fresh demo hook.
contract Blind3ForkNewMarketTest is Blind3ForkBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    address internal constant NEWHOOK = address(uint160(0x7777 << 144) | uint160(0x20C4));

    function _sqrtFor(uint256 priceWad, bool outIs0) internal pure returns (uint160) {
        if (outIs0) return uint160(Math.sqrt(FullMath.mulDiv(priceWad, 1 << 192, 1e30)));
        return uint160(Math.sqrt(FullMath.mulDiv(1 << 192, 1e30, priceWad)));
    }

    function _seed(PoolKey memory k, address outcome, uint256 priceWad) internal {
        bool outIs0 = Currency.unwrap(k.currency0) == outcome;
        PM.initialize(k, _sqrtFor(priceWad, outIs0));
        if (outIs0) IValidatorAdmin(VALIDATOR).setBoundaries(k.toId(), -887160, -276360);
        else IValidatorAdmin(VALIDATOR).setBoundaries(k.toId(), 276300, 887220);
        lp.modifyLiquidity(k, ModifyLiquidityParams(-887220, 887220, 1e15, 0), "");
    }

    function test_f64_newMarketThroughRealManager() public {
        // demo hook at a fresh 0x...20C4 address, wired like the deployed one
        deployCodeTo(
            "TruthMarketHookDemo.sol:TruthMarketHookDemo", abi.encode(PM, IOrderManager(OM), FC, address(this)), NEWHOOK
        );
        TruthMarketHookDemo h = TruthMarketHookDemo(NEWHOOK);
        h.setFeeRate(HOOK_FEE);
        h.setSwapValidator(VALIDATOR);
        h.setAuthorizedPoolInitializer(address(this), true);
        vm.startPrank(DEPLOYER);
        IAccessControl(OM).grantRole(keccak256("V4_HOOK_ROLE"), NEWHOOK);
        IFeeCollectorAdmin(FC).setHookAddress(NEWHOOK);
        IAccessControl(VALIDATOR).grantRole(keccak256("OPERATOR_ROLE"), address(this));
        vm.stopPrank();

        // the Safe points the manager at the new hook (every other field unchanged) and creates a market
        IManagerAdmin mg = IManagerAdmin(MANAGER);
        address[8] memory v = [
            mg.truthMarketMastercopy(),
            mg.oracleCouncilAddress(),
            mg.paymentToken(),
            mg.safeBoxAddress(),
            mg.uniswapV3Factory(),
            mg.rewardWallet(),
            mg.escalationAddress(),
            mg.truthMarketV2Mastercopy()
        ];
        vm.prank(SAFE);
        mg.setAddresses(v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7], NEWHOOK);
        assertEq(mg.uniswapV4HookAddress(), NEWHOOK);
        assertEq(mg.truthMarketV2Mastercopy(), v[7]);
        assertEq(mg.paymentToken(), v[2]);
        uint256 eot = block.timestamp + 30 days;
        vm.prank(SAFE);
        address mk = mg.createMarketV2("Blind3?", "src", "info", eot, 1e30, address(0), 0, "BY", "BN", 1, 60);
        assertEq(mk.codehash, CLONE_CODEHASH);
        (PoolKey memory ky, PoolKey memory kn) = ITrueoMarket(mk).getPoolKeys();
        assertEq(address(ky.hooks), NEWHOOK);
        address yesT = ITrueoMarket(mk).yesToken();
        address noT = ITrueoMarket(mk).noToken();

        // seed both pools at 0.6 / 0.4 with full-range liquidity
        deal(TYD, address(this), 1e13);
        IERC20Like(TYD).approve(mk, type(uint256).max);
        ITrueoMarket(mk).mint(10_000e6);
        IERC20Like(TYD).approve(address(lp), type(uint256).max);
        IERC20Like(yesT).approve(address(lp), type(uint256).max);
        IERC20Like(noT).approve(address(lp), type(uint256).max);
        _seed(ky, yesT, 0.6e18);
        _seed(kn, noT, 0.4e18);

        TrueoRebalancer mod2 = new TrueoRebalancer(PM, NEWHOOK, ITrueoManager(MANAGER), CLONE_CODEHASH, address(this));
        mod2.setParams(recipient, 5, 10_000e6, 10);
        mod2.setEnabled(true);
        mod2.register(mk);
        assertEq(mod2.marketOf(ky.toId()).market, mk);

        // trader buys YES for 200 TYD with the opt-in
        deal(TYD, trader, 1e9);
        vm.prank(trader);
        IERC20Like(TYD).approve(address(router), type(uint256).max);
        bool z = Currency.unwrap(ky.currency0) == TYD;
        SwapParams memory sp = SwapParams(z, -200e6, z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
        h.setRebalanceGas(5_000_000);
        uint256 s0 = vm.snapshotState();

        vm.prank(trader);
        BalanceDelta dA = router.swap(ky, sp, PoolSwapTest.TestSettings(false, false), RebalanceFlag.encode());
        uint256 sumA = _price(ky, yesT) + _price(kn, noT);
        uint256 yesA = IERC20Like(yesT).balanceOf(trader);
        vm.revertToState(s0);

        h.setRebalancer(address(mod2));
        uint256 r0 = IERC20Like(TYD).balanceOf(recipient);
        vm.recordLogs();
        vm.getRecordedLogs();
        vm.prank(trader);
        BalanceDelta dB = router.swap(ky, sp, PoolSwapTest.TestSettings(false, false), RebalanceFlag.encode());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 sumB = _price(ky, yesT) + _price(kn, noT);
        assertEq(BalanceDelta.unwrap(dA), BalanceDelta.unwrap(dB), "trader delta");
        assertEq(IERC20Like(yesT).balanceOf(trader), yesA);
        uint256 gain = IERC20Like(TYD).balanceOf(recipient) - r0;
        assertGe(gain, 5, "new market not rebalanced");
        uint256 n;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(mod2) && logs[i].topics[0] == TrueoRebalancer.Rebalanced.selector) n++;
        }
        assertEq(n, 1);
        console.log("sum no module / module", sumA, sumB);
        assertGt(sumA, 1.0095e18);
        assertLe(sumB, 1.0095e18, "sum above 1.0095 after the rebalance");
        assertGe(sumB, 1e18);
        assertEq(IERC20Like(TYD).balanceOf(address(mod2)), 0);
        assertEq(IERC20Like(yesT).balanceOf(address(mod2)), 0);
        assertEq(IERC20Like(noT).balanceOf(address(mod2)), 0);
    }
}

interface IValidatorAdmin {
    function setBoundaries(PoolId poolId, int24 lo, int24 hi) external;
}
