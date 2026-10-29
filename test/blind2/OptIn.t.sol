// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Blind2Base} from "./Blind2Base.sol";
import {MultiSwapRouter} from "./utils/MultiSwapRouter.sol";
import {RebalanceFlag} from "../../src/libraries/RebalanceFlag.sol";
import {TrueoRebalancer} from "../../src/TrueoRebalancer.sol";

/// Properties 1-4: opt-in flag, identity of every swap of a multi-swap unlock, hookData robustness,
/// no recursion.
contract Blind2OptInTest is Blind2Base {
    MultiSwapRouter internal msr;

    function setUp() public virtual override {
        super.setUp();
        msr = new MultiSwapRouter(poolManager);
        msr.watch(kYes, kNo, address(fc));
        tyd.transfer(address(msr), 1e11);
        yes.transfer(address(msr), 1e23);
        no.transfer(address(msr), 1e23);
    }

    // ---------------------------------------------------------------- routes

    /// mint side: every leg buys an outcome (YES + NO rises). burn side: every leg sells one (YES + NO falls).
    function _route(bool mintSide, uint256 n, bytes[] memory hd) internal view returns (MultiSwapRouter.Leg[] memory l) {
        l = new MultiSwapRouter.Leg[](n);
        PoolKey[3] memory ks = [kYes, kNo, kYes];
        uint256[3] memory buyTyd = [uint256(40e6), 30e6, 20e6];
        uint256[3] memory sellAmt = [uint256(60e18), 50e18, 30e18];
        for (uint256 i; i < n; i++) {
            bool outIs0 = Currency.unwrap(ks[i].currency0) != TYD;
            bool z = mintSide ? !outIs0 : outIs0;
            int256 amt = mintSide ? -int256(buyTyd[i]) : -int256(sellAmt[i]);
            l[i] = MultiSwapRouter.Leg(ks[i], z, amt, hd[i]);
        }
    }

    function _hds(uint256 n, uint256 flagAt, bytes memory other) internal pure returns (bytes[] memory hd) {
        hd = new bytes[](3);
        for (uint256 i; i < 3; i++) {
            hd[i] = (i + 1 == flagAt) ? RebalanceFlag.encode() : other;
        }
        n;
    }

    function _assertRecEq(MultiSwapRouter.Rec memory a, MultiSwapRouter.Rec memory b) internal pure {
        assertEq(a.a0, b.a0, "swap delta0");
        assertEq(a.a1, b.a1, "swap delta1");
        assertEq(a.s1, b.s1, "YES pool price after swap");
        assertEq(a.s2, b.s2, "NO pool price after swap");
        assertEq(a.f1t, b.f1t, "fee claim YES pool TYD");
        assertEq(a.f1o, b.f1o, "fee claim YES pool YES");
        assertEq(a.f2t, b.f2t, "fee claim NO pool TYD");
        assertEq(a.f2o, b.f2o, "fee claim NO pool NO");
    }

    // ---------------------------------------------------------------- property 1: no flag => bit-identical

    /// Rebalancer plugged in, NO opt-in word: every swap of 1-, 2- and 3-swap unlocks, mint and burn side, with
    /// empty / 32-byte non-magic / magic-then-extra-byte hookData, is identical to the deployed TruthMarketHook:
    /// per-swap deltas, both pools' prices, FeeCollector claims, end state, and every log.
    function test_p1_noFlag_multiSwap_identicalToDeployedHook() public {
        bytes[3] memory others = [bytes(""), abi.encode(uint256(7)), abi.encodePacked(RebalanceFlag.MAGIC, uint8(1))];
        vm.expectCall(address(module), _onSwapSel(), 0);
        uint256 s0 = vm.snapshotState();
        for (uint256 side; side < 2; side++) {
            for (uint256 n = 1; n <= 3; n++) {
                for (uint256 h; h < 3; h++) {
                    MultiSwapRouter.Leg[] memory legs = _route(side == 0, n, _hds(n, 0, others[h]));

                    vm.revertToState(s0);
                    _installOriginal();
                    _startRec();
                    MultiSwapRouter.Rec[] memory base = msr.run(legs);
                    Vm.Log[] memory baseLogs = vm.getRecordedLogs();
                    Out memory baseEnd = _snapOut(kYes, kNo);

                    vm.revertToState(s0);
                    _plugWith(address(module), REBALANCE_GAS);
                    _startRec();
                    MultiSwapRouter.Rec[] memory got = msr.run(legs);
                    Vm.Log[] memory gotLogs = vm.getRecordedLogs();
                    Out memory gotEnd = _snapOut(kYes, kNo);

                    assertEq(got.length, n);
                    for (uint256 i; i < n; i++) {
                        _assertRecEq(base[i], got[i]);
                    }
                    _assertLogsEqual(baseLogs, gotLogs);
                    _assertAllSame(baseEnd, gotEnd);
                    _assertModuleEmpty();
                }
            }
        }
    }

    /// Single trader swap through the plain router without the word: identical to the deployed hook.
    function test_p1_noFlag_singleSwap_identical() public {
        uint256 s0 = vm.snapshotState();
        _installOriginal();
        Out memory a = _tradeMain(kYes, true, 50e6, "");
        vm.revertToState(s0);
        _plugWith(address(module), REBALANCE_GAS);
        vm.expectCall(address(module), _onSwapSel(), 0);
        Out memory b = _tradeMain(kYes, true, 50e6, "");
        _assertAllSame(a, b);
        _assertModuleEmpty();
    }

    // ---------------------------------------------------------------- property 2: flag on swap k

    function _flagOnK(bool mintSide, uint256 n, uint256 k) internal {
        MultiSwapRouter.Leg[] memory legs = _route(mintSide, n, _hds(n, k, ""));
        uint256 s0 = vm.snapshotState();
        _installOriginal();
        MultiSwapRouter.Rec[] memory base = msr.run(legs);
        uint256 recv0 = tyd.balanceOf(recipient);
        vm.revertToState(s0);

        _plugWith(address(module), REBALANCE_GAS);
        vm.expectCall(address(module), _onSwapSel(), 1);
        _startRec();
        MultiSwapRouter.Rec[] memory got = msr.run(legs);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // swaps before k: everything identical; swap k: the trader's delta identical (the module runs after it)
        for (uint256 i; i + 1 < k; i++) {
            _assertRecEq(base[i], got[i]);
        }
        assertEq(got[k - 1].a0, base[k - 1].a0, "flagged swap delta0");
        assertEq(got[k - 1].a1, base[k - 1].a1, "flagged swap delta1");
        // the module ran exactly once and it delivered
        assertEq(_rebalances(logs), 1, "Rebalanced count");
        assertGt(tyd.balanceOf(recipient), recv0, "no profit: module did not act");
        _assertModuleEmpty();
    }

    function test_p2_flagOnSwap1of3_mint() public {
        _flagOnK(true, 3, 1);
    }

    function test_p2_flagOnSwap2of3_mint() public {
        _flagOnK(true, 3, 2);
    }

    function test_p2_flagOnSwap3of3_mint_allIdentical() public {
        _flagOnK(true, 3, 3);
    }

    function test_p2_flagOnSwap1of3_burn() public {
        _flagOnK(false, 3, 1);
    }

    function test_p2_flagOnSwap2of3_burn() public {
        _flagOnK(false, 3, 2);
    }

    function test_p2_flagOnSwap3of3_burn_allIdentical() public {
        _flagOnK(false, 3, 3);
    }

    function test_p2_flagOnSwap1of2_mint() public {
        _flagOnK(true, 2, 1);
    }

    function test_p2_flagOnSwap2of2_mint_allIdentical() public {
        _flagOnK(true, 2, 2);
    }

    function test_p2_flagOnSwap1of2_burn() public {
        _flagOnK(false, 2, 1);
    }

    function test_p2_flagOnSwap2of2_burn_allIdentical() public {
        _flagOnK(false, 2, 2);
    }

    function test_p2_flagOnOnlySwap_mint() public {
        _flagOnK(true, 1, 1);
    }

    function test_p2_flagOnOnlySwap_burn() public {
        _flagOnK(false, 1, 1);
    }

    // ---------------------------------------------------------------- property 3: any hookData

    function _isOptIn(bytes memory hd) internal pure returns (bool) {
        if (hd.length < 32) return false;
        bytes32 w;
        assembly {
            w := mload(add(add(hd, 0x20), sub(mload(hd), 32)))
        }
        return w == RebalanceFlag.MAGIC;
    }

    function _shape(bytes memory prefix, uint8 mode, bytes32 word, bytes memory suffix)
        internal
        pure
        returns (bytes memory hd)
    {
        bytes32 m = RebalanceFlag.MAGIC;
        mode = mode % 8;
        if (mode == 0) {
            // 0-31 bytes
            uint256 len = prefix.length % 32;
            hd = new bytes(len);
            for (uint256 i; i < len; i++) {
                hd[i] = prefix[i];
            }
        } else if (mode == 1) {
            hd = abi.encodePacked(word); // 32 bytes, almost surely not the word
        } else if (mode == 2) {
            hd = abi.encodePacked(m); // exactly the word
        } else if (mode == 3) {
            hd = abi.encodePacked(prefix, m); // anything ++ word
        } else if (mode == 4) {
            hd = abi.encodePacked(m, suffix.length == 0 ? bytes(hex"00") : suffix); // word ++ extra
        } else if (mode == 5) {
            hd = abi.encodePacked(prefix, m, suffix); // word in the middle (opt-in only if suffix empty)
        } else if (mode == 6) {
            hd = abi.encodePacked(prefix, word); // 33+ bytes ending with a random word
        } else {
            // the word with one bit flipped, alone or after a prefix
            hd = abi.encodePacked(prefix, m ^ bytes32(uint256(1) << (uint8(word[0]) % 256)));
        }
    }

    /// For any hookData the trader's swap never reverts and is identical to the deployed hook; the module is
    /// called iff the last 32 bytes are MAGIC (and then it delivers profit), otherwise nothing at all changes.
    function testFuzz_p3_anyHookData(bytes memory prefix, uint8 mode, bytes32 word, bytes memory suffix, bool buy)
        public
    {
        vm.assume(prefix.length < 300 && suffix.length < 300);
        bytes memory hd = _shape(prefix, mode, word, suffix);
        bool expected = _isOptIn(hd);
        assertEq(expected, this.isSetExt(hd), "test model of RebalanceFlag.isSet");

        uint256 s0 = vm.snapshotState();
        _installOriginal();
        Out memory a = _tradeMain(kYes, buy, buy ? 50e6 : 80e18, hd);
        vm.revertToState(s0);

        _plugWith(address(module), REBALANCE_GAS);
        vm.expectCall(address(module), _onSwapSel(), expected ? 1 : 0);
        Out memory b = _tradeMain(kYes, buy, buy ? 50e6 : 80e18, hd);
        _assertTraderSame(a, b);
        if (expected) {
            _assertActed(a, b, MIN_PROFIT);
        } else {
            _assertIdle(a, b);
        }
    }

    function isSetExt(bytes calldata hd) external pure returns (bool) {
        return RebalanceFlag.isSet(hd);
    }

    /// Deterministic edge lengths: 0..31 bytes (including MAGIC's own 31-byte tail / head), 32, 33, 64, and the
    /// word followed by 1 / 32 extra bytes. Module acts only for the cases ending with the word.
    function test_p3_edgeLengths() public {
        bytes32 m = RebalanceFlag.MAGIC;
        bytes memory full = abi.encodePacked(m);
        bytes[] memory cases = new bytes[](40);
        bool[] memory want = new bool[](40);
        uint256 c;
        for (uint256 len; len < 32; len++) {
            bytes memory h = new bytes(len);
            for (uint256 i; i < len; i++) {
                h[i] = full[32 - len + i]; // the word's tail
            }
            cases[c++] = h;
        }
        cases[c] = abi.encodePacked(bytes31(m)); // head of the word, 31 bytes
        c++;
        cases[c] = full;
        want[c++] = true;
        cases[c] = abi.encodePacked(uint8(0), m); // 33 bytes, ends with the word
        want[c++] = true;
        cases[c] = abi.encodePacked(m, m); // 64
        want[c++] = true;
        cases[c] = abi.encodePacked(m, uint8(0)); // word + 1 byte
        c++;
        cases[c] = abi.encodePacked(m, bytes32(0)); // word + 32 bytes
        c++;
        cases[c] = abi.encodePacked(uint256(1), m); // abi-looking prefix ++ word
        want[c++] = true;
        cases[c] = abi.encode(m); // == full, encoded differently
        want[c++] = true;

        uint256 s0 = vm.snapshotState();
        for (uint256 i; i < c; i++) {
            vm.revertToState(s0);
            _installOriginal();
            Out memory a = _tradeMain(kYes, true, 50e6, cases[i]);
            vm.revertToState(s0);
            _plugWith(address(module), REBALANCE_GAS);
            Out memory b = _tradeMain(kYes, true, 50e6, cases[i]);
            _assertTraderSame(a, b);
            if (want[i]) _assertActed(a, b, MIN_PROFIT);
            else _assertIdle(a, b);
        }
    }

    // ---------------------------------------------------------------- property 4: no recursion

    function _oneTrade(bool buy, uint32 reserve) internal {
        hook.setRebalanceGasReserve(reserve);
        uint256 s0 = vm.snapshotState();
        _installOriginal();
        Out memory a = _tradeMain(kNo, buy, buy ? 50e6 : 80e18, _magic());
        vm.revertToState(s0);
        _plugWith(address(module), REBALANCE_GAS);
        vm.expectCall(address(module), _onSwapSel(), 1);
        _startRec();
        Out memory b = _tradeMain(kNo, buy, buy ? 50e6 : 80e18, _magic());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_rebalances(logs), 1, "exactly one rebalance");
        _assertTraderSame(a, b);
        _assertActed(a, b, MIN_PROFIT);
    }

    function test_p4_oneOptedInTrade_oneOnSwap_oneRebalance_mint() public {
        _oneTrade(true, 1_000_000);
    }

    function test_p4_oneOptedInTrade_oneOnSwap_oneRebalance_burn() public {
        _oneTrade(false, 1_000_000);
    }

    /// the lowest reserve (the setter's floor, final fix pass; was 0) gives a nested hook call the most room:
    /// still one onSwap
    function test_p4_noRecursion_reserveAtFloor() public {
        _oneTrade(true, hook.MIN_REBALANCE_GAS_RESERVE());
    }

    /// three flagged trader swaps in one unlock: exactly three onSwap calls (one per trader swap, none from the
    /// module's own swaps), at most three rebalances, the module ends empty
    function test_p4_threeFlaggedSwaps_threeOnSwaps() public {
        bytes[] memory hd = new bytes[](3);
        for (uint256 i; i < 3; i++) {
            hd[i] = _magic();
        }
        MultiSwapRouter.Leg[] memory legs = _route(true, 3, hd);
        uint256 r0 = tyd.balanceOf(recipient);
        _plugWith(address(module), REBALANCE_GAS);
        vm.expectCall(address(module), _onSwapSel(), 3);
        _startRec();
        msr.run(legs);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertLe(_rebalances(logs), 3);
        assertGt(tyd.balanceOf(recipient), r0);
        _assertModuleEmpty();
    }

    /// the rebalancer interface the hook calls takes only the key
    function test_p4_onSwap_onlyHook() public {
        vm.expectRevert(TrueoRebalancer.NotHook.selector);
        module.onSwap(kYes);
        vm.prank(trader);
        vm.expectRevert(TrueoRebalancer.NotHook.selector);
        module.onSwap(kNo);
    }
}
