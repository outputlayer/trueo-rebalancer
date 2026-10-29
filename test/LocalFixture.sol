// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BaseTest} from "./utils/BaseTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
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
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {TruthMarketHookDemo} from "../src/trueo/hook/TruthMarketHookDemo.sol";
import {IOrderManager} from "../src/trueo/hook/interfaces/IOrderManager.sol";
import {TruthMarketSwapValidator} from "../src/trueo/validator/validators/TruthMarketSwapValidator.sol";
import {MockOutcomeToken} from "./mocks/MockOutcomeToken.sol";
import {MockMarketManager} from "./mocks/MockMarketManager.sol";
import {MockTruthMarket} from "./mocks/MockTruthMarket.sol";
import {MockOrderManager} from "./mocks/MockOrderManager.sol";
import {MockFeeCollector} from "./mocks/MockFeeCollector.sol";
import {RebalanceFlag} from "../src/libraries/RebalanceFlag.sol";

/// @notice Local v4 + Trueo hook + one YES/NO market. YES is currency0 of its pool and NO is currency1 of its
/// pool, the same mixed orientation as the Aero market 0xb1cF...173C.
abstract contract LocalFixture is BaseTest {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // flags 0x20C4 = beforeInitialize | beforeSwap | afterSwap | afterSwapReturnDelta, as on 0x3E83...e0C4
    address internal constant HOOK = address(uint160(0x7777 << 144) | uint160(0x20C4));
    address internal constant TYD = 0x5000000000000000000000000000000000000005;
    address internal constant YES = 0x1000000000000000000000000000000000000001;
    address internal constant NO = 0x9000000000000000000000000000000000000009;
    uint24 internal constant LP_FEE = 1; // as on the real markets
    int24 internal constant SPACING = 60;
    int24 internal constant FULL_LO = -887220;
    int24 internal constant FULL_HI = 887220;
    uint256 internal constant HOOK_FEE = 80; // feeNumerator of 0x3E83...e0C4: 0.8%
    uint128 internal constant LIQ = 1e15;
    uint32 internal constant REBALANCE_GAS = 5_000_000;

    TruthMarketHookDemo internal hook;
    TruthMarketSwapValidator internal validator;
    MockOrderManager internal om;
    MockFeeCollector internal fc;
    MockMarketManager internal mgr;
    MockTruthMarket internal market;
    MockERC20 internal tyd;
    MockOutcomeToken internal yes;
    MockOutcomeToken internal no;
    PoolSwapTest internal router;
    PoolModifyLiquidityTest internal lpRouter;
    PoolKey internal kYes;
    PoolKey internal kNo;

    address internal trader = makeAddr("trader");
    /// hookData of every trader swap made through _swap/_buy/_sell (empty = no opt-in)
    bytes internal swapHookData;

    function setUp() public virtual {
        deployArtifactsAndLabel();
        router = new PoolSwapTest(poolManager);
        lpRouter = new PoolModifyLiquidityTest(poolManager);

        mgr = new MockMarketManager();
        market = new MockTruthMarket();
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("TYD", "TYD", uint8(6)), TYD);
        deployCodeTo("MockOutcomeToken.sol:MockOutcomeToken", abi.encode("YES", address(market)), YES);
        deployCodeTo("MockOutcomeToken.sol:MockOutcomeToken", abi.encode("NO", address(market)), NO);
        tyd = MockERC20(TYD);
        yes = MockOutcomeToken(YES);
        no = MockOutcomeToken(NO);

        om = new MockOrderManager();
        fc = new MockFeeCollector();
        validator = new TruthMarketSwapValidator(poolManager, address(this));
        validator.grantRole(keccak256("OPERATOR_ROLE"), address(this));
        _deployHook("TruthMarketHookDemo.sol:TruthMarketHookDemo");

        market.init(mgr, ERC20(TYD), yes, no, LP_FEE, SPACING, HOOK);
        mgr.setActive(address(market), true);
        (kYes, kNo) = market.getPoolKeys();
        tyd.mint(address(this), 1e13);
        tyd.approve(address(market), type(uint256).max);
        market.mint(1e12);
        tyd.approve(address(lpRouter), type(uint256).max);
        yes.approve(address(lpRouter), type(uint256).max);
        no.approve(address(lpRouter), type(uint256).max);
        _initPool(kYes, YES, 0.6e18);
        _initPool(kNo, NO, 0.4e18);

        tyd.mint(trader, 1e12);
        vm.startPrank(trader);
        tyd.approve(address(router), type(uint256).max);
        yes.approve(address(router), type(uint256).max);
        no.approve(address(router), type(uint256).max);
        tyd.approve(address(market), type(uint256).max);
        market.mint(1e9); // 1000 YES and 1000 NO to sell
        vm.stopPrank();
    }

    /// deploys `artifact` at HOOK (constructor args as on Base) and wires it the way Trueo did
    function _deployHook(string memory artifact) internal {
        deployCodeTo(artifact, abi.encode(poolManager, IOrderManager(address(om)), address(fc), address(this)), HOOK);
        hook = TruthMarketHookDemo(HOOK);
        fc.setHookAddress(HOOK);
        hook.setFeeRate(HOOK_FEE);
        hook.setSwapValidator(address(validator));
        hook.setAuthorizedPoolInitializer(address(this), true);
    }

    /// initializes the pool at `priceWad` (TYD per outcome token), sets Trueo's [0, 1] validator bounds
    /// (copied from the Aero pools) and adds full-range liquidity LIQ
    function _initPool(PoolKey memory key, address outcome, uint256 priceWad) internal {
        bool outIs0 = Currency.unwrap(key.currency0) == outcome;
        poolManager.initialize(key, _sqrtFor(priceWad, outIs0));
        if (outIs0) validator.setBoundaries(key.toId(), -887160, -276360);
        else validator.setBoundaries(key.toId(), 276300, 887220);
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(FULL_LO, FULL_HI, int256(uint256(LIQ)), 0), "");
    }

    function _sqrtFor(uint256 priceWad, bool outIs0) internal pure returns (uint160) {
        if (outIs0) return uint160(Math.sqrt(FullMath.mulDiv(priceWad, 1 << 192, 1e30)));
        return uint160(Math.sqrt(FullMath.mulDiv(1 << 192, 1e30, priceWad)));
    }

    /// TYD per whole outcome token, WAD
    function _price(PoolKey memory key, address outcome) internal view returns (uint256) {
        (uint160 s,,,) = poolManager.getSlot0(key.toId());
        bool outIs0 = Currency.unwrap(key.currency0) == outcome;
        if (outIs0) return FullMath.mulDiv(FullMath.mulDiv(s, s, 1 << 96), 1e30, 1 << 96);
        return FullMath.mulDiv(FullMath.mulDiv(1 << 96, 1 << 96, s), 1e30, s);
    }

    function _sum() internal view returns (uint256) {
        return _price(kYes, YES) + _price(kNo, NO);
    }

    function _tick(PoolKey memory key) internal view returns (int24 t) {
        (, t,,) = poolManager.getSlot0(key.toId());
    }

    /// the trader's swaps from here on carry the rebalance opt-in
    function _optIn() internal {
        swapHookData = RebalanceFlag.encode();
    }

    /// trader buys the outcome of `key` paying `tydIn` TYD (exact in)
    function _buy(PoolKey memory key, address outcome, uint256 tydIn) internal returns (BalanceDelta) {
        return _swap(key, Currency.unwrap(key.currency0) != outcome, -int256(tydIn));
    }

    /// trader sells `amount` of the outcome of `key` (exact in)
    function _sell(PoolKey memory key, address outcome, uint256 amount) internal returns (BalanceDelta) {
        return _swap(key, Currency.unwrap(key.currency0) == outcome, -int256(amount));
    }

    function _swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta d) {
        vm.prank(trader);
        d = router.swap(
            key,
            SwapParams(
                zeroForOne, amountSpecified, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            swapHookData
        );
    }
}
