pragma solidity ^0.8.24;

import {console} from "forge-std/console.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IOrderManager} from "./interfaces/IOrderManager.sol";
import {IFeeCollector} from "./interfaces/IFeeCollector.sol";
import {ISwapValidator} from "./interfaces/ISwapValidator.sol";
import {IPausablePool} from "./interfaces/IPausablePool.sol";
import {TransientSlot} from "./libraries/TransientSlot.sol";
import {Roles} from "./libraries/Roles.sol";
import {ITrueoRebalancer} from "../../interfaces/ITrueoRebalancer.sol";
import {RebalanceFlag} from "../../libraries/RebalanceFlag.sol";

contract TruthMarketHookDemo is BaseHook, AccessControl, IPausablePool {
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;
    using TransientSlot for TransientSlot.Int256Slot;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    bytes32 private constant PREVIOUS_TICK_SLOT = keccak256("org.truemarkets.hook.previous-tick");

    uint256 public constant FEE_DENOMINATOR = 10000;
    uint256 public feeNumerator = 0; // Default 0%, set to 36 for 0.36%

    IOrderManager public orderManager;
    address public feeCollector;
    ISwapValidator public swapValidator;

    mapping(address => bool) public authorizedPoolInitializers;
    mapping(PoolId => bool) public override poolPaused;

    // Rebalancer (demo addition) ////////////////////////////////////

    ITrueoRebalancer public rebalancer;
    uint32 public rebalanceGas;
    /// @notice Gas kept for the rest of the trader's transaction when the rebalancer is called
    uint32 public rebalanceGasReserve = 1_000_000;
    /// @notice Least gas worth forwarding: the rebalancer is called only when gasleft() - reserve reaches this.
    /// Default 750,000: above the most module gas measured over the hook's swap history (710k); the recommended
    /// rebalanceGas is 1,500,000.
    uint32 public rebalanceGasMin = 750_000;
    /// @notice Lowest rebalanceGasReserve the admin can set, so that no setting can make a trader's swap revert.
    /// Measured on a Base fork (block 53172900, real AERO and PUMP markets, PoolSwapTest router, every account cold,
    /// a rebalancer burning all it gets, rebalanceGasMin 0, tightest gas limits): a single swap needs at most
    /// 56,640 gas after the call returns (rest of afterSwap + PoolManager + router settlement; AERO buy YES 56,640,
    /// AERO sell YES 55,663, PUMP buy NO 56,640, PUMP sell NO 54,687; 1k resolution). Floor = 2 x 56,640 rounded
    /// up to 50k.
    /// Not covered by the floor: later hops of a route (a hop 2 filling an OrderManager order needed 342,773), which
    /// is why the opt-in goes on the last Trueo hop only and the default reserve stays 1,000,000.
    uint32 public constant MIN_REBALANCE_GAS_RESERVE = 150_000;

    error InvalidRebalancer();
    error RebalanceGasReserveBelowFloor(uint32 reserve, uint32 floor);

    event RebalancerUpdated(address indexed oldRebalancer, address indexed newRebalancer);
    event RebalanceGasUpdated(uint32 oldGas, uint32 newGas);
    event RebalanceGasReserveUpdated(uint32 oldReserve, uint32 newReserve);
    event RebalanceGasMinSet(uint32 rebalanceGasMin);

    // Errors ////////////////////////////////////////////////////////

    error InvalidRecipient();
    error FeeAmountTooLarge();
    error UnauthorizedPoolInitializer();
    error PoolIsPaused(PoolId poolId);

    // Events ////////////////////////////////////////////////////////

    event FeeCollected(PoolId indexed poolId, Currency indexed currency, uint256 amount);
    event FeeCollectorUpdated(address indexed oldCollector, address indexed newCollector);
    event FeeRateUpdated(uint256 oldRate, uint256 newRate);
    event SettleOrderFailed(PoolId poolId, int24 tickLower, int24 tickUpper, int256 liquidityDelta, bytes32 salt);
    event SwapValidatorUpdated(address indexed oldValidator, address indexed newValidator);
    event OrderManagerUpdated(address indexed oldManager, address indexed newManager);
    event PoolInitializerUpdated(address indexed initializer, bool authorized);
    event PoolPauseStatusChanged(PoolId indexed poolId, bool paused);

    constructor(IPoolManager _poolManager, IOrderManager _orderManager, address _feeCollector, address _admin)
        BaseHook(_poolManager)
    {
        orderManager = _orderManager;
        feeCollector = _feeCollector;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeInitialize(address sender, PoolKey calldata, uint160) internal override returns (bytes4) {
        if (!authorizedPoolInitializers[sender]) revert UnauthorizedPoolInitializer();
        return BaseHook.beforeInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        if (poolPaused[poolId]) revert PoolIsPaused(poolId);

        // Get the current tick directly from slot0 instead of calculating from sqrtPriceX96
        // This accounts for Uniswap's tick adjustment behavior where the pool may set
        // currentTick = tickNext - 1 when sqrtPriceX96 == sqrtPriceNextX96 and zeroForOne = true
        (, int24 tick,,) = poolManager.getSlot0(key.toId());

        TransientSlot.Int256Slot slot = TransientSlot.asInt256(PREVIOUS_TICK_SLOT);
        slot.tstore(int256(tick));

        return (BaseHook.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4 selector, int128 hookDelta) {
        (selector, hookDelta) = _afterSwapTrueo(sender, key, params, delta, hookData);
        // Demo addition: last step, after validator, movePoolTick and fee. Any failure reverts only the rebalancer.
        // Only a swap whose hookData ends with the opt-in word calls it; without it the hook is the original.
        address r = address(rebalancer);
        if (r != address(0) && RebalanceFlag.isSet(hookData)) {
            // Gas: the rebalancer gets g = min(rebalanceGas, gasleft() - reserve), and is called only if g != 0 and
            // g >= rebalanceGasMin (if g is too little the rebalancer runs out of gas and only its call reverts), so
            // rebalanceGas = 0 or < rebalanceGasMin means no call at all. Whatever it burns, the hook keeps about the
            // reserve (the call is passed at most gasleft() - reserve, less the few hundred gas spent before the CALL;
            // the 63/64 rule only leaves more), so the reserve must cover everything after this call: the rest of
            // afterSwap, the PoolManager, the router's settlement and any later swap of the transaction with the
            // OrderManager fills it triggers (the setter enforces MIN_REBALANCE_GAS_RESERVE for the single-swap part).
            // Integration rule: put the opt-in word only on the LAST Trueo hop of a route.
            uint256 left = gasleft();
            uint256 reserve = rebalanceGasReserve;
            uint256 g = left > reserve ? left - reserve : 0;
            uint256 cap = rebalanceGas;
            if (g > cap) g = cap;
            if (g != 0 && g >= rebalanceGasMin) {
                bytes memory data = abi.encodeCall(ITrueoRebalancer.onSwap, (key));
                // Low-level call: no extcodesize check (an address whose code vanished must not revert the swap),
                // result and returndata ignored.
                assembly ("memory-safe") {
                    pop(call(g, r, 0, add(data, 0x20), mload(data), 0, 0))
                }
            }
        }
    }

    /// @dev The original TruthMarketHook._afterSwap body, unchanged.
    function _afterSwapTrueo(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal returns (bytes4, int128) {
        // Validate swap first if validator is set
        if (address(swapValidator) != address(0)) {
            swapValidator.validateAfterSwap(sender, key, params, delta, hookData);
        }

        TransientSlot.Int256Slot slot = TransientSlot.asInt256(PREVIOUS_TICK_SLOT);
        int24 fromTick = int24(slot.tload());

        // Get the post-swap tick directly from slot0 instead of calculating from sqrtPriceX96
        // This ensures we use the actual tick value that Uniswap has set, accounting for the
        // edge case where tick may be adjusted by -1 when the swap ends exactly at a tick boundary
        (uint160 sqrtPriceX96, int24 toTick,,) = poolManager.getSlot0(key.toId());

        orderManager.movePoolTick(key, fromTick, toTick, sqrtPriceX96);

        if (feeNumerator == 0) {
            return (BaseHook.afterSwap.selector, 0);
        }

        // For exactOut (positive amount): specified token is output
        // For exactIn (negative amount): specified token is input
        bool isCurrency0Specified = params.amountSpecified > 0 ? !params.zeroForOne : params.zeroForOne;

        (Currency currencyUnspecified, int128 amountUnspecified) =
            (isCurrency0Specified) ? (key.currency1, delta.amount1()) : (key.currency0, delta.amount0());

        if (amountUnspecified < 0) amountUnspecified = -amountUnspecified;

        uint256 feeAmount = Math.mulDiv(uint256(int256(amountUnspecified)), feeNumerator, FEE_DENOMINATOR);

        if (feeAmount > 0) {
            poolManager.mint(feeCollector, currencyUnspecified.toId(), feeAmount);

            // Track fee by pool in the fee collection contract
            IFeeCollector(feeCollector).trackPoolFee(key.toId(), currencyUnspecified, feeAmount);

            emit FeeCollected(key.toId(), currencyUnspecified, feeAmount);
        }

        // Validate fee amount fits in int128 before conversion
        if (feeAmount > uint256(uint128(type(int128).max))) {
            revert FeeAmountTooLarge();
        }

        return (BaseHook.afterSwap.selector, feeAmount.toInt128());
    }

    // Admin functions ////////////////////////////////////////////////

    /// @notice Set the rebalancer called at the end of afterSwap (zero disables it)
    /// @param _rebalancer A contract, or address(0)
    function setRebalancer(address _rebalancer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_rebalancer != address(0) && _rebalancer.code.length == 0) revert InvalidRebalancer();
        address old = address(rebalancer);
        rebalancer = ITrueoRebalancer(_rebalancer);
        emit RebalancerUpdated(old, _rebalancer);
    }

    /// @notice Set the gas forwarded to the rebalancer
    /// @param _gas Gas limit of the rebalancer call
    function setRebalanceGas(uint32 _gas) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint32 old = rebalanceGas;
        rebalanceGas = _gas;
        emit RebalanceGasUpdated(old, _gas);
    }

    /// @notice Set the gas the hook keeps for the rest of the trader's transaction when it calls the rebalancer
    /// @param _reserve Kept back from the rebalancer: it gets at most gasleft() - _reserve. Must cover all the
    /// trader's work after the call (rest of the swap, settlement, later swaps of the route). At least
    /// MIN_REBALANCE_GAS_RESERVE (the measured single-swap need x 2); routes need more (default 1,000,000).
    function setRebalanceGasReserve(uint32 _reserve) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_reserve < MIN_REBALANCE_GAS_RESERVE) {
            revert RebalanceGasReserveBelowFloor(_reserve, MIN_REBALANCE_GAS_RESERVE);
        }
        uint32 old = rebalanceGasReserve;
        rebalanceGasReserve = _reserve;
        emit RebalanceGasReserveUpdated(old, _reserve);
    }

    /// @notice Set the least gas the hook forwards to the rebalancer
    /// @param _min The rebalancer is called only when gasleft() - rebalanceGasReserve >= _min (it then gets
    /// min(rebalanceGas, gasleft() - rebalanceGasReserve))
    function setRebalanceGasMin(uint32 _min) external onlyRole(DEFAULT_ADMIN_ROLE) {
        rebalanceGasMin = _min;
        emit RebalanceGasMinSet(_min);
    }

    /// @notice Set the fee collector contract address
    /// @param newCollector The new fee collector contract address
    function setFeeCollector(address newCollector) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newCollector == address(0)) revert InvalidRecipient();
        address oldCollector = feeCollector;
        feeCollector = newCollector;
        emit FeeCollectorUpdated(oldCollector, newCollector);
    }

    /// @notice Set the fee rate numerator
    /// @param newNumerator The new fee numerator (36 = 0.36%)
    function setFeeRate(uint256 newNumerator) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldRate = feeNumerator;
        feeNumerator = newNumerator;
        emit FeeRateUpdated(oldRate, newNumerator);
    }

    /// @notice Set the swap validator contract
    /// @param _swapValidator The address of the swap validator (or zero to disable)
    function setSwapValidator(address _swapValidator) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address oldValidator = address(swapValidator);
        swapValidator = ISwapValidator(_swapValidator);
        emit SwapValidatorUpdated(oldValidator, _swapValidator);
    }

    /// @notice Set whether an address is authorized to initialize pools using this hook
    /// @param initializer The address to authorize or deauthorize
    /// @param authorized Whether the address is authorized
    function setAuthorizedPoolInitializer(address initializer, bool authorized) external onlyRole(DEFAULT_ADMIN_ROLE) {
        authorizedPoolInitializers[initializer] = authorized;
        emit PoolInitializerUpdated(initializer, authorized);
    }

    /// @notice Set the order manager contract
    /// @param _orderManager The address of the order manager
    function setOrderManager(address _orderManager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_orderManager == address(0)) revert InvalidRecipient();
        address oldManager = address(orderManager);
        orderManager = IOrderManager(_orderManager);
        emit OrderManagerUpdated(oldManager, _orderManager);
    }

    /// @inheritdoc IPausablePool
    function pausePool(PoolId poolId) external override onlyRole(Roles.OPERATOR_ROLE) {
        poolPaused[poolId] = true;
        emit PoolPauseStatusChanged(poolId, true);
    }

    /// @inheritdoc IPausablePool
    function unpausePool(PoolId poolId) external override onlyRole(Roles.OPERATOR_ROLE) {
        poolPaused[poolId] = false;
        emit PoolPauseStatusChanged(poolId, false);
    }
}
