// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {ITrueoRebalancer} from "./interfaces/ITrueoRebalancer.sol";
import {ITrueoMarket, ITrueoManager, ITrueoHook, ITrueoValidator, IERC20Like} from "./interfaces/ITrueo.sol";
import {RebalanceMath} from "./libraries/RebalanceMath.sol";

/// @title TrueoRebalancer
/// @notice Called by the Trueo hook at the end of afterSwap. Restores YES + NO ~= 1 payment token in the same
/// transaction by minting/burning a pair and trading it on both pools, and sends the captured spread to
/// profitRecipient. Holds no funds between calls. It sizes the rebalance on a model of both pools, returns with no
/// side effect unless the model profit reaches minProfit, then executes the whole size in one shot: one mint and two
/// sales, or one burn and two purchases. Any failure (out of gas included) reverts the whole call. The hook calls it
/// only for swaps whose hookData carries the trader's opt-in (RebalanceFlag), through a gas-capped low-level call
/// whose result it ignores, so the trader's swap is unaffected.
contract TrueoRebalancer is ITrueoRebalancer {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    /// @dev keccak256("TrueoRebalancer.lock")
    bytes32 internal constant LOCK_SLOT = 0xcbcba2ad181aa8a1e21649e9fac7fc371e94b4180f5ea021ae0bd3ced45ea8d1;
    uint8 internal constant STATUS_FINALIZED = 7;
    uint16 internal constant MAX_THRESHOLD_BPS = 10_000;

    IPoolManager public immutable poolManager;
    address public immutable hook;
    ITrueoManager public immutable manager;
    bytes32 public immutable marketCodehash;

    address public admin;
    address public profitRecipient;
    uint256 public minProfit; // payment-token units
    uint256 public maxSize; // payment-token units per rebalance
    uint16 public thresholdBps; // minimum |YES + NO - 1| before acting
    bool public enabled;
    /// per-market off switch (default: every registered market is on)
    mapping(address => bool) public marketDisabled;

    struct MarketInfo {
        address market;
        uint8 gap; // outcome decimals - payment decimals
        uint24 fee;
        int24 tickSpacing;
        address tyd;
        address yes;
        address no;
    }

    mapping(PoolId => MarketInfo) internal _markets;

    error NotHook();
    error NotAdmin();
    error ZeroAddress();
    error BadParams();
    error NotTrueoMarket();
    error PartialFill();
    error NotProfitable(int256 profit);
    error Unsettled();
    error BalanceChanged();
    error TransferFailed();

    event Registered(address indexed market);
    event ParamsSet(address profitRecipient, uint256 minProfit, uint256 maxSize, uint16 thresholdBps);
    event EnabledSet(bool enabled);
    event AdminSet(address admin);
    event Rebalanced(address indexed market, bool mint, uint256 amount, uint256 profit);
    event MarketEnabledSet(address indexed market, bool enabled);

    constructor(
        IPoolManager _poolManager,
        address _hook,
        ITrueoManager _manager,
        bytes32 _marketCodehash,
        address _admin
    ) {
        if (address(_poolManager) == address(0) || _hook == address(0) || address(_manager) == address(0)) {
            revert ZeroAddress();
        }
        if (_admin == address(0)) revert ZeroAddress();
        poolManager = _poolManager;
        hook = _hook;
        manager = _manager;
        marketCodehash = _marketCodehash;
        admin = _admin;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    // ---- admin ----

    function setParams(address _profitRecipient, uint256 _minProfit, uint256 _maxSize, uint16 _thresholdBps)
        external
        onlyAdmin
    {
        if (_profitRecipient == address(0)) revert ZeroAddress();
        // the module would pay itself (BalanceChanged) or leave the profit in the PoolManager for anyone to take
        if (_profitRecipient == address(this) || _profitRecipient == address(poolManager)) revert BadParams();
        // the model may be off by the rounding of its two swaps (2 x ROUND_PER_STEP): a lower minProfit would
        // start rebalances whose real profit can round to nothing
        if (_minProfit <= 2 * RebalanceMath.ROUND_PER_STEP || _thresholdBps > MAX_THRESHOLD_BPS) revert BadParams();
        profitRecipient = _profitRecipient;
        minProfit = _minProfit;
        maxSize = _maxSize;
        thresholdBps = _thresholdBps;
        emit ParamsSet(_profitRecipient, _minProfit, _maxSize, _thresholdBps);
    }

    function setEnabled(bool _enabled) external onlyAdmin {
        if (_enabled && profitRecipient == address(0)) revert BadParams();
        enabled = _enabled;
        emit EnabledSet(_enabled);
    }

    /// @notice Turns the module off (or back on) for one registered market
    function setMarketEnabled(address market, bool on) external onlyAdmin {
        marketDisabled[market] = !on;
        emit MarketEnabledSet(market, on);
    }

    function setAdmin(address _admin) external onlyAdmin {
        if (_admin == address(0)) revert ZeroAddress();
        admin = _admin;
        emit AdminSet(_admin);
    }

    /// @notice Records a genuine, active Trueo market whose pools use this hook. Permissionless: everything is
    /// read from the codehash-pinned market. Grants the market standing allowances (it pulls TYD in mint and
    /// burns YES/NO from this contract in burn); the contract holds no funds between calls.
    function register(address market) external {
        if (market.codehash != marketCodehash || !manager.isActiveMarket(market)) revert NotTrueoMarket();
        ITrueoMarket m = ITrueoMarket(market);
        (PoolKey memory kYes, PoolKey memory kNo) = m.getPoolKeys();
        MarketInfo memory info = MarketInfo({
            market: market,
            gap: 0,
            fee: kYes.fee,
            tickSpacing: kYes.tickSpacing,
            tyd: m.paymentToken(),
            yes: m.yesToken(),
            no: m.noToken()
        });
        uint8 outDec = IERC20Like(info.yes).decimals();
        uint8 payDec = IERC20Like(info.tyd).decimals();
        if (payDec > outDec || IERC20Like(info.no).decimals() != outDec) revert NotTrueoMarket();
        info.gap = outDec - payDec;
        (PoolKey memory eYes, PoolKey memory eNo) = _keys(info);
        if (
            PoolId.unwrap(eYes.toId()) != PoolId.unwrap(kYes.toId())
                || PoolId.unwrap(eNo.toId()) != PoolId.unwrap(kNo.toId())
        ) revert NotTrueoMarket();
        _markets[kYes.toId()] = info;
        _markets[kNo.toId()] = info;
        _approve(info.tyd, market);
        _approve(info.yes, market);
        _approve(info.no, market);
        emit Registered(market);
    }

    function marketOf(PoolId id) external view returns (MarketInfo memory) {
        return _markets[id];
    }

    // ---- hook entry ----

    /// @inheritdoc ITrueoRebalancer
    function onSwap(PoolKey calldata key) external {
        if (msg.sender != hook) revert NotHook();
        bool locked;
        bytes32 slot = LOCK_SLOT;
        assembly ("memory-safe") {
            locked := tload(slot)
        }
        // our own swaps re-enter through the hook: ignore them
        if (locked) return;
        assembly ("memory-safe") {
            tstore(slot, 1)
        }
        _rebalance(key.toId());
        assembly ("memory-safe") {
            tstore(slot, 0)
        }
    }

    // ---- internals ----

    function _rebalance(PoolId id) internal virtual {
        if (!enabled) return;
        // a caller between sync and settle: our own sync would steal its payment
        if (Currency.unwrap(poolManager.getSyncedCurrency()) != address(0)) return;
        MarketInfo memory m = _markets[id];
        if (m.market == address(0) || marketDisabled[m.market]) return;
        (PoolKey memory kYes, PoolKey memory kNo) = _keys(m);
        if (!_tradable(m, kYes, kNo)) return;

        uint256 scale = 10 ** m.gap;
        (uint160 sY,, uint24 pfY, uint24 lpY) = poolManager.getSlot0(kYes.toId());
        (uint160 sN,, uint24 pfN, uint24 lpN) = poolManager.getSlot0(kNo.toId());
        if (sY == 0 || sN == 0) return; // a pool without a price
        bool yOut0 = Currency.unwrap(kYes.currency0) == m.yes;
        bool nOut0 = Currency.unwrap(kNo.currency0) == m.no;
        uint256 priceY = RebalanceMath.priceWad(sY, yOut0, scale);
        uint256 priceN = RebalanceMath.priceWad(sN, nOut0, scale);
        uint256 band = RebalanceMath.WAD * thresholdBps / 10_000;
        bool mint;
        if (priceY + priceN > RebalanceMath.WAD + band) mint = true;
        else if (priceY + priceN + band < RebalanceMath.WAD) mint = false;
        else return;
        uint256 hookFee = ITrueoHook(hook).feeNumerator();
        uint24 feeY = _swapFee(pfY, lpY, mint == yOut0);
        uint24 feeN = _swapFee(pfN, lpN, mint == nOut0);
        // cheap exit before walking the pools: the first unit already loses to the swap fees (LP + protocol)
        // and the hook fee
        if (!RebalanceMath.gainful(priceY, priceN, feeY, feeN, hookFee, mint)) return;
        uint256 hi = _hi(m, mint, scale);
        if (hi == 0) return;

        RebalanceMath.Curve memory cY =
            _curve(kYes, yOut0, feeY, mint, RebalanceMath.Stop(true, priceN, feeN, hookFee, scale));
        RebalanceMath.Curve memory cN =
            _curve(kNo, nOut0, feeN, mint, RebalanceMath.Stop(true, priceY, feeY, hookFee, scale));
        uint256 x = RebalanceMath.size(cY, cN, hi, scale, hookFee);
        // decide before any side effect: no take, mint, payment or swap unless the model profit reaches minProfit
        if (x == 0 || RebalanceMath.estimateProfit(cY, cN, x, scale, hookFee) < int256(minProfit)) return;

        uint256[3] memory before = _balances(m);
        uint256 profit =
            mint ? _mintAndSell(m, kYes, kNo, cY, cN, x, scale) : _buyAndBurn(m, kYes, kNo, cY, cN, x, scale);
        _checkClean(m, before);
        emit Rebalanced(m.market, mint, x, profit);
    }

    function _tradable(MarketInfo memory m, PoolKey memory kYes, PoolKey memory kNo) internal view returns (bool) {
        if (manager.paused()) return false;
        ITrueoMarket mk = ITrueoMarket(m.market);
        if (mk.paused() || mk.getCurrentStatus() == STATUS_FINALIZED) return false;
        ITrueoHook h = ITrueoHook(hook);
        return !h.poolPaused(kYes.toId()) && !h.poolPaused(kNo.toId());
    }

    /// Largest size: maxSize, capped by the tokens the PoolManager holds (it pays out only those, and the trader's
    /// input arrives only after this call: routers settle after the swap), and in mint by the room left under the
    /// market's token cap. Burn takes size x scale YES and NO out; mint takes size TYD up front and the profit at
    /// the end, hence half. The /2 cap relies on outcome prices <= 1 TYD (Trueo's validator bounds), so that
    /// profit < size; without those bounds only the module's final take could revert (the module's call fails,
    /// the trader's swap is unaffected).
    function _hi(MarketInfo memory m, bool mint, uint256 scale) internal view returns (uint256 hi) {
        hi = maxSize;
        if (!mint) {
            address pm = address(poolManager);
            return _min(hi, _min(IERC20Like(m.yes).balanceOf(pm), IERC20Like(m.no).balanceOf(pm)) / scale);
        }
        hi = _min(hi, IERC20Like(m.tyd).balanceOf(address(poolManager)) / 2);
        uint256 cap = ITrueoMarket(m.market).yesNoTokenCap();
        uint256 sy = IERC20Like(m.yes).totalSupply();
        uint256 sn = IERC20Like(m.no).totalSupply();
        uint256 supply = sy > sn ? sy : sn;
        if (supply >= cap) return 0;
        uint256 room = (cap - supply) / scale;
        if (room < hi) hi = room;
    }

    /// the fee Pool.swap charges in this direction: LP fee combined with the protocol fee, pips
    function _swapFee(uint24 protocolFee, uint24 lpFee, bool zeroForOne) internal pure returns (uint24) {
        uint16 pf = zeroForOne
            ? ProtocolFeeLibrary.getZeroForOneFee(protocolFee)
            : ProtocolFeeLibrary.getOneForZeroFee(protocolFee);
        return pf == 0 ? lpFee : ProtocolFeeLibrary.calculateSwapFee(pf, lpFee);
    }

    function _curve(PoolKey memory k, bool outIs0, uint24 fee, bool mint, RebalanceMath.Stop memory stop)
        internal
        view
        returns (RebalanceMath.Curve memory)
    {
        bool zeroForOne = mint == outIs0;
        return RebalanceMath.build(
            poolManager, k.toId(), k.tickSpacing, outIs0, mint, fee, _limit(k.toId(), zeroForOne), stop
        );
    }

    /// sqrt price the swap may end at without the validator rejecting the post-swap tick
    function _limit(PoolId id, bool zeroForOne) internal view returns (uint160) {
        int24 lower = TickMath.MIN_TICK;
        int24 upper = TickMath.MAX_TICK;
        address v = ITrueoHook(hook).swapValidator();
        if (v != address(0)) {
            (int24 l, int24 u, bool set) = ITrueoValidator(v).poolBoundaries(id);
            if (set) (lower, upper) = (l, u);
        }
        // ending exactly on sqrt(lower) leaves tick = lower - 1, hence the +1
        if (zeroForOne) {
            if (lower <= TickMath.MIN_TICK) return TickMath.MIN_SQRT_PRICE + 1;
            return TickMath.getSqrtPriceAtTick(lower) + 1;
        }
        if (upper >= TickMath.MAX_TICK) return TickMath.MAX_SQRT_PRICE - 1;
        return TickMath.getSqrtPriceAtTick(upper + 1) - 1;
    }

    /// Mint side: take x TYD, mint x into n = x * scale YES and NO, pay both into the PoolManager before the
    /// sales (the OrderManager pays filled orders from the PoolManager's balance), sell n YES and n NO
    /// exact-in, check the real profit and take it to profitRecipient.
    function _mintAndSell(
        MarketInfo memory m,
        PoolKey memory kYes,
        PoolKey memory kNo,
        RebalanceMath.Curve memory cY,
        RebalanceMath.Curve memory cN,
        uint256 x,
        uint256 scale
    ) internal returns (uint256 profit) {
        uint256 n = x * scale;
        poolManager.take(Currency.wrap(m.tyd), address(this), x);
        ITrueoMarket(m.market).mint(x);
        _pay(m.yes, n);
        _pay(m.no, n);
        uint256 out = _sellExactIn(kYes, cY, n) + _sellExactIn(kNo, cN, n);
        if (out < x + minProfit) revert NotProfitable(int256(out) - int256(x));
        profit = out - x;
        poolManager.take(Currency.wrap(m.tyd), profitRecipient, profit);
    }

    /// Burn side, mirroring the mint side's pay-before-sell: take n = x * scale YES and NO out of the PoolManager
    /// (it holds them, see _hi), burn them for TYD and pay all of it in before the two exact-out purchases, so
    /// the TYD the OrderManager pays to the owners of sell orders those purchases fill is already in the
    /// PoolManager (it defers a payout when its actual balance is short). Then check the real profit and take it.
    function _buyAndBurn(
        MarketInfo memory m,
        PoolKey memory kYes,
        PoolKey memory kNo,
        RebalanceMath.Curve memory cY,
        RebalanceMath.Curve memory cN,
        uint256 x,
        uint256 scale
    ) internal returns (uint256 profit) {
        uint256 n = x * scale;
        poolManager.take(Currency.wrap(m.yes), address(this), n);
        poolManager.take(Currency.wrap(m.no), address(this), n);
        uint256 t0 = IERC20Like(m.tyd).balanceOf(address(this));
        ITrueoMarket(m.market).burn(n);
        uint256 got = IERC20Like(m.tyd).balanceOf(address(this)) - t0;
        _pay(m.tyd, got);
        uint256 cost = _buyExactOut(kYes, cY, n) + _buyExactOut(kNo, cN, n);
        if (got < cost + minProfit) revert NotProfitable(int256(got) - int256(cost));
        profit = got - cost;
        poolManager.take(Currency.wrap(m.tyd), profitRecipient, profit);
    }

    /// exact-in sale of n outcome units; reverts unless all n are sold
    function _sellExactIn(PoolKey memory k, RebalanceMath.Curve memory c, uint256 n) internal returns (uint256) {
        BalanceDelta d = poolManager.swap(k, SwapParams(c.outIs0, -int256(n), c.limit), "");
        (int128 outcome, int128 pay) = c.outIs0 ? (d.amount0(), d.amount1()) : (d.amount1(), d.amount0());
        if (int256(outcome) != -int256(n) || pay <= 0) revert PartialFill();
        return uint256(int256(pay));
    }

    /// exact-out purchase of n outcome units; reverts unless all n are bought
    function _buyExactOut(PoolKey memory k, RebalanceMath.Curve memory c, uint256 n) internal returns (uint256) {
        BalanceDelta d = poolManager.swap(k, SwapParams(!c.outIs0, int256(n), c.limit), "");
        (int128 outcome, int128 pay) = c.outIs0 ? (d.amount0(), d.amount1()) : (d.amount1(), d.amount0());
        if (int256(outcome) != int256(n) || pay >= 0) revert PartialFill();
        return uint256(-int256(pay));
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _pay(address token, uint256 amount) internal {
        poolManager.sync(Currency.wrap(token));
        _transfer(token, address(poolManager), amount);
        poolManager.settle();
    }

    function _balances(MarketInfo memory m) internal view returns (uint256[3] memory b) {
        b[0] = IERC20Like(m.tyd).balanceOf(address(this));
        b[1] = IERC20Like(m.yes).balanceOf(address(this));
        b[2] = IERC20Like(m.no).balanceOf(address(this));
    }

    /// every PoolManager delta of this contract is closed and no token stayed behind
    function _checkClean(MarketInfo memory m, uint256[3] memory before) internal view {
        if (
            poolManager.currencyDelta(address(this), Currency.wrap(m.tyd)) != 0
                || poolManager.currencyDelta(address(this), Currency.wrap(m.yes)) != 0
                || poolManager.currencyDelta(address(this), Currency.wrap(m.no)) != 0
        ) revert Unsettled();
        uint256[3] memory afterB = _balances(m);
        if (afterB[0] != before[0] || afterB[1] != before[1] || afterB[2] != before[2]) revert BalanceChanged();
    }

    function _keys(MarketInfo memory m) internal view returns (PoolKey memory kYes, PoolKey memory kNo) {
        kYes = _key(m.yes, m.tyd, m.fee, m.tickSpacing);
        kNo = _key(m.no, m.tyd, m.fee, m.tickSpacing);
    }

    function _key(address outcome, address tyd, uint24 fee, int24 tickSpacing) internal view returns (PoolKey memory) {
        (address c0, address c1) = outcome < tyd ? (outcome, tyd) : (tyd, outcome);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), fee, tickSpacing, IHooks(hook));
    }

    function _transfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory r) = token.call(abi.encodeCall(IERC20Like.transfer, (to, amount)));
        if (!ok || (r.length != 0 && !abi.decode(r, (bool)))) revert TransferFailed();
    }

    function _approve(address token, address spender) internal {
        (bool ok, bytes memory r) = token.call(abi.encodeCall(IERC20Like.approve, (spender, type(uint256).max)));
        if (!ok || (r.length != 0 && !abi.decode(r, (bool)))) revert TransferFailed();
    }
}
