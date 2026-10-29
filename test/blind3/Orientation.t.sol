// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console} from "forge-std/console.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Blind3Base} from "./Blind3Base.sol";
import {MockTruthMarket} from "../mocks/MockTruthMarket.sol";

/// Test-plan items 25, 30 and 33-36 spot-checked on the other orientation (YES currency1 of its pool, NO currency0).
contract Blind3OrientationTest is Blind3Base {
    address internal constant YESF = 0xC00000000000000000000000000000000000000C; // > TYD: currency1
    address internal constant NOF = 0x4000000000000000000000000000000000000004; // < TYD: currency0

    Mkt internal F;

    function setUp() public override {
        super.setUp();
        (MockTruthMarket m, PoolKey memory ky, PoolKey memory kn) = _newMarket(YESF, NOF, 0.6e18, 0.4e18, true, 0);
        module.register(address(m));
        F = _mkt(address(m), ky, kn);
        assertEq(Currency.unwrap(ky.currency1), YESF, "YES must be currency1");
        assertEq(Currency.unwrap(kn.currency0), NOF, "NO must be currency0");
    }

    function _pairF(bool buy, int256 amt) internal returns (Run memory a, Run memory b) {
        return _pairT(F, T(true, buy, amt, 0));
    }

    function test_o25_sumLands_mint() public {
        (Run memory a, Run memory b) = _pairF(true, -50e6);
        _assertActedR(F, a, b);
        assertGt(a.sum, 1.0095e18);
        assertGe(b.sum, 1e18);
        assertLe(b.sum, 1.0095e18);
    }

    function test_o25_sumLands_burn() public {
        (Run memory a, Run memory b) = _pairF(false, -50e18);
        _assertActedR(F, a, b);
        assertLt(a.sum, 0.9905e18);
        assertLe(b.sum, 1e18);
        assertGe(b.sum, 0.9905e18);
    }

    function test_o30_decideBeforeSideEffects() public {
        uint256 s0 = vm.snapshotState();
        (Run memory a0, Run memory b0) = _pairF(true, -200e6);
        uint256 p = _assertActedR(F, a0, b0);
        vm.revertToState(s0);
        _setParams(p + 1, MAX_SIZE, THRESHOLD_BPS);
        (Run memory a, Run memory b) = _pairF(true, -200e6);
        _assertIdleR(F, a, b);
        assertEq(b.modSwaps, 0);
        assertEq(b.modTransfers, 0);
        assertLt(_gasAdded(a, b), 300_000);
    }

    function test_o33_pmShortOfYes_burn() public {
        uint256 s0 = vm.snapshotState();
        (Run memory a0, Run memory b0) = _pairF(false, -200e18);
        _assertActedR(F, a0, b0);
        uint256 S = b0.evAmount;
        vm.revertToState(s0);
        deal(YESF, address(poolManager), (S / 2) * 1e12);
        (Run memory a, Run memory b) = _pairF(false, -200e18);
        _assertActedR(F, a, b);
        assertLe(b.evAmount, S / 2);
    }

    function test_o34_pmHoldsNoYes_idle() public {
        uint256 s0 = vm.snapshotState();
        (Run memory c, Run memory d) = _pairF(false, -200e18); // control
        _assertActedR(F, c, d);
        vm.revertToState(s0);
        deal(YESF, address(poolManager), 0);
        (Run memory a, Run memory b) = _pairF(false, -200e18);
        _assertIdleR(F, a, b);
        assertLe(_gasAdded(a, b), 60_000);
    }

    function test_o35_pmShortOfTyd_mint() public {
        uint256 s0 = vm.snapshotState();
        (Run memory a0, Run memory b0) = _pairF(true, -50e6);
        _assertActedR(F, a0, b0);
        uint256 S = b0.evAmount;
        vm.revertToState(s0);
        deal(TYD, address(poolManager), S);
        (Run memory a, Run memory b) = _pairF(true, -50e6);
        _assertActedR(F, a, b);
        assertLe(b.evAmount, S / 2);
    }

    function test_o36_capBlocksMintOnly() public {
        MockTruthMarket(F.m).setCap(ERC20(YESF).totalSupply());
        uint256 s0 = vm.snapshotState();
        (Run memory a, Run memory b) = _pairF(true, -50e6);
        _assertIdleR(F, a, b);
        assertLe(_gasAdded(a, b), 80_000);
        vm.revertToState(s0);
        (Run memory c, Run memory d) = _pairF(false, -200e18);
        _assertActedR(F, c, d);
    }
}
