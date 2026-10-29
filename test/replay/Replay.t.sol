// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
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
import {RebalanceFlag} from "../../src/libraries/RebalanceFlag.sol";
import {ForkConstants} from "../fork/ForkConstants.sol";

interface IFeeCollectorView {
    function poolFeeAccumulated(PoolId, Currency) external view returns (uint256);
}

/// @notice Level 3: replays trader swaps from data/trader_swaps.jsonl on a Base fork, once with the current hook
/// and once with the demo hook + rebalancer, and writes one CSV row per swap to reports/replay.csv.
/// Run: REPLAY=1 forge test --match-contract ReplayTest -vv   (needs an archive BASE_RPC_URL)
contract ReplayTest is Test, ForkConstants {
    using PoolIdLibrary for PoolKey;

    address internal constant RECIPIENT = address(0xBEEF);
    address internal trader = makeAddr("replay-trader");

    struct Row {
        bytes32 txHash;
        uint256 blockNumber;
        address market;
        bool yesSide;
        bool zeroForOne;
        int256 amountSpecified;
        uint256 gasLimit;
        uint256 nSwaps;
    }

    struct Result {
        bool ok;
        int256 d0;
        int256 d1;
        uint256[4] fees; // FeeCollector accrual: trader pool c0, c1; other pool c0, c1
        uint256 profit;
        uint256 gas;
    }

    function test_replay() public {
        if (!vm.envOr("REPLAY", false)) vm.skip(true);
        string memory rpc = vm.envString("BASE_RPC_URL");
        string memory input = vm.envOr("REPLAY_INPUT", string("data/trader_swaps.jsonl"));
        string memory output = vm.envOr("REPLAY_OUTPUT", string("reports/replay.csv"));
        uint256 limit = vm.envOr("REPLAY_LIMIT", uint256(500));
        uint256 offset = vm.envOr("REPLAY_OFFSET", uint256(0)); // rows to skip, for batched runs
        vm.writeFile(
            output,
            "tx_hash,block,market,side,zero_for_one,amount_specified,status,trader_match,"
            "d0_base,d1_base,d0_mod,d1_mod,fees_not_less,fee_tyd_base,fee_tyd_mod,profit_tyd,"
            "gas_base,gas_mod,module_ran,module_ran_at_gas_limit,basefee\n"
        );
        // REPLAY_FORK=block forks at block-1 instead of just before the tx: no re-execution of earlier txs of the
        // block, which is far faster on a public RPC; baseline and module still run on identical state
        bool blockMode = keccak256(bytes(vm.envOr("REPLAY_FORK", string("tx")))) == keccak256("block");
        uint256 n;
        uint256 seen;
        for (string memory line = vm.readLine(input); bytes(line).length > 0 && n < limit; line = vm.readLine(input)) {
            if (seen++ < offset) continue;
            Row memory row = _parse(line);
            n++;
            if (row.nSwaps != 1) {
                Result memory none;
                _write(output, row, "skip_multi", none, none, false, 0, true, 0, 0);
                continue;
            }
            if (row.txHash != bytes32(0) && !blockMode) vm.createSelectFork(rpc, row.txHash);
            else vm.createSelectFork(rpc, row.blockNumber - 1);
            _replayOne(output, row);
        }
    }

    function _replayOne(string memory output, Row memory row) internal {
        (PoolKey memory kYes, PoolKey memory kNo) = ITrueoMarket(row.market).getPoolKeys();
        (PoolKey memory key, PoolKey memory other) = row.yesSide ? (kYes, kNo) : (kNo, kYes);
        PoolSwapTest router = new PoolSwapTest(PM);
        _fund(router, key, row);
        uint256 snap = vm.snapshotState();
        Result memory base = _swap(router, key, other, row, gasleft(), bytes(""));
        vm.revertToState(snap);
        (bool registered, TrueoRebalancer module) = _install(row.market);
        if (!registered) {
            Result memory none;
            _write(output, row, "not_registrable", base, none, false, block.basefee, true, 0, 0);
            return;
        }
        Result memory withMod = _swap(router, key, other, row, _modGas(row), RebalanceFlag.encode());
        assertEq(address(TruthMarketHookDemo(REAL_HOOK).rebalancer()), address(module));
        string memory status = base.ok ? (withMod.ok ? "ok" : "mod_failed") : "base_failed";
        bool notLess = true;
        for (uint256 i; i < 4; i++) {
            if (withMod.fees[i] < base.fees[i]) notLess = false;
        }
        _write(
            output,
            row,
            status,
            base,
            withMod,
            withMod.profit > 0,
            block.basefee,
            notLess,
            _tydFees(base, key, other),
            _tydFees(withMod, key, other)
        );
    }

    /// gas limit of the module leg. REPLAY_GAS: unlimited (default) | real (the trader's historical gas limit) |
    /// headroom (real + 6M) | real+<gas> (real + that much, e.g. real+1500000: a frontend adding fixed headroom)
    function _modGas(Row memory row) internal view returns (uint256) {
        string memory mode = vm.envOr("REPLAY_GAS", string("unlimited"));
        bytes32 gm = keccak256(bytes(mode));
        if (gm == keccak256("real")) return row.gasLimit;
        if (gm == keccak256("headroom")) return row.gasLimit + 6_000_000;
        string[] memory parts = vm.split(mode, "+");
        if (parts.length == 2 && keccak256(bytes(parts[0])) == keccak256("real")) {
            return row.gasLimit + vm.parseUint(parts[1]);
        }
        return gasleft();
    }

    function _parse(string memory line) internal view returns (Row memory r) {
        if (vm.keyExistsJson(line, ".tx_hash")) {
            bytes memory raw = vm.parseJson(line, ".tx_hash");
            if (raw.length == 32) r.txHash = abi.decode(raw, (bytes32));
        }
        r.blockNumber = vm.parseJsonUint(line, ".block");
        r.market = vm.parseJsonAddress(line, ".market");
        r.yesSide = keccak256(bytes(vm.parseJsonString(line, ".side"))) == keccak256("yes");
        r.zeroForOne = vm.parseJsonBool(line, ".zero_for_one");
        r.amountSpecified = vm.parseJsonInt(line, ".amount_specified");
        r.gasLimit = vm.keyExistsJson(line, ".gas_limit") ? vm.parseJsonUint(line, ".gas_limit") : 30_000_000;
        r.nSwaps = vm.keyExistsJson(line, ".n_swaps_in_tx") ? vm.parseJsonUint(line, ".n_swaps_in_tx") : 1;
    }

    function _fund(PoolSwapTest router, PoolKey memory key, Row memory row) internal {
        address cin = Currency.unwrap(row.zeroForOne ? key.currency0 : key.currency1);
        uint256 amt = row.amountSpecified < 0 ? uint256(-row.amountSpecified) : type(uint128).max;
        deal(cin, trader, amt);
        vm.prank(trader);
        IERC20Like(cin).approve(address(router), type(uint256).max);
    }

    /// demo code in place of the real hook (storage kept, fee restored) + a registered module; false when the
    /// market cannot be registered at this block (inactive in the manager)
    function _install(address market) internal returns (bool registered, TrueoRebalancer module) {
        uint256 fee = TruthMarketHookDemo(REAL_HOOK).feeNumerator();
        deployCodeTo(
            "TruthMarketHookDemo.sol:TruthMarketHookDemo", abi.encode(PM, IOrderManager(OM), FC, DEPLOYER), REAL_HOOK
        );
        module = new TrueoRebalancer(PM, REAL_HOOK, ITrueoManager(MANAGER), CLONE_CODEHASH, address(this));
        module.setParams(RECIPIENT, 5, 10_000e6, 10);
        module.setEnabled(true);
        try module.register(market) {
            registered = true;
        } catch {
            return (false, module);
        }
        vm.startPrank(DEPLOYER);
        TruthMarketHookDemo(REAL_HOOK).setFeeRate(fee);
        TruthMarketHookDemo(REAL_HOOK).setRebalancer(address(module));
        TruthMarketHookDemo(REAL_HOOK).setRebalanceGas(uint32(vm.envOr("REPLAY_REBALANCE_GAS", uint256(5_000_000))));
        vm.stopPrank();
    }

    function _swap(PoolSwapTest router, PoolKey memory key, PoolKey memory other, Row memory row, uint256 gasLimit, bytes memory hookData)
        internal
        returns (Result memory r)
    {
        uint256[4] memory f0 = _fees(key, other);
        uint256 p0 = IERC20Like(TYD).balanceOf(RECIPIENT);
        bytes memory data = abi.encodeCall(
            PoolSwapTest.swap,
            (
                key,
                SwapParams(
                    row.zeroForOne,
                    row.amountSpecified,
                    row.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                ),
                PoolSwapTest.TestSettings(false, false),
                hookData
            )
        );
        uint256 g = gasleft();
        vm.prank(trader);
        (bool ok, bytes memory ret) = address(router).call{gas: gasLimit}(data);
        r.gas = g - gasleft();
        r.ok = ok;
        if (ok) {
            BalanceDelta d = abi.decode(ret, (BalanceDelta));
            (r.d0, r.d1) = (d.amount0(), d.amount1());
        }
        uint256[4] memory f1 = _fees(key, other);
        for (uint256 i; i < 4; i++) {
            r.fees[i] = f1[i] - f0[i];
        }
        r.profit = IERC20Like(TYD).balanceOf(RECIPIENT) - p0;
    }

    function _fees(PoolKey memory key, PoolKey memory other) internal view returns (uint256[4] memory f) {
        IFeeCollectorView fc = IFeeCollectorView(FC);
        f[0] = fc.poolFeeAccumulated(key.toId(), key.currency0);
        f[1] = fc.poolFeeAccumulated(key.toId(), key.currency1);
        f[2] = fc.poolFeeAccumulated(other.toId(), other.currency0);
        f[3] = fc.poolFeeAccumulated(other.toId(), other.currency1);
    }

    function _tydFees(Result memory r, PoolKey memory key, PoolKey memory other) internal pure returns (uint256 t) {
        if (Currency.unwrap(key.currency0) == TYD) t += r.fees[0];
        else t += r.fees[1];
        if (Currency.unwrap(other.currency0) == TYD) t += r.fees[2];
        else t += r.fees[3];
    }

    function _write(
        string memory output,
        Row memory row,
        string memory status,
        Result memory b,
        Result memory m,
        bool ranAtLimit,
        uint256 basefee,
        bool feesNotLess,
        uint256 feeTydBase,
        uint256 feeTydMod
    ) internal {
        string memory s = string.concat(
            vm.toString(row.txHash),
            ",",
            vm.toString(row.blockNumber),
            ",",
            vm.toString(row.market),
            ",",
            row.yesSide ? "yes" : "no",
            ",",
            row.zeroForOne ? "true" : "false",
            ",",
            vm.toString(row.amountSpecified),
            ",",
            status,
            ",",
            (b.d0 == m.d0 && b.d1 == m.d1) ? "true" : "false",
            ","
        );
        s = string.concat(
            s,
            vm.toString(b.d0),
            ",",
            vm.toString(b.d1),
            ",",
            vm.toString(m.d0),
            ",",
            vm.toString(m.d1),
            ",",
            feesNotLess ? "true" : "false",
            ",",
            vm.toString(feeTydBase),
            ",",
            vm.toString(feeTydMod),
            ",",
            vm.toString(m.profit),
            ","
        );
        s = string.concat(
            s,
            vm.toString(b.gas),
            ",",
            vm.toString(m.gas),
            ",",
            m.profit > 0 ? "true" : "false",
            ",",
            ranAtLimit ? "true" : "false",
            ",",
            vm.toString(basefee)
        );
        vm.writeLine(output, s);
    }
}
