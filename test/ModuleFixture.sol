// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LocalFixture} from "./LocalFixture.sol";
import {Vm} from "forge-std/Vm.sol";
import {TrueoRebalancer} from "../src/TrueoRebalancer.sol";
import {ITrueoManager} from "../src/interfaces/ITrueo.sol";

/// @notice LocalFixture + a registered, enabled TrueoRebalancer (not yet plugged into the hook).
abstract contract ModuleFixture is LocalFixture {
    uint256 internal constant MIN_PROFIT = 5; // 0.000005 TYD: the smallest valid (> 2 x ROUND_PER_STEP)
    uint256 internal constant MAX_SIZE = 10_000e6; // 10k TYD per rebalance
    uint16 internal constant THRESHOLD_BPS = 10;

    TrueoRebalancer internal module;
    address internal admin = makeAddr("admin");
    address internal recipient = makeAddr("recipient");

    function setUp() public virtual override {
        super.setUp();
        module = new TrueoRebalancer(poolManager, HOOK, ITrueoManager(address(mgr)), address(market).codehash, admin);
        vm.startPrank(admin);
        module.setParams(recipient, MIN_PROFIT, MAX_SIZE, THRESHOLD_BPS);
        module.setEnabled(true);
        vm.stopPrank();
        module.register(address(market));
    }

    function _plugIn() internal {
        hook.setRebalancer(address(module));
        hook.setRebalanceGas(REBALANCE_GAS);
        _optIn();
    }

    /// number of Rebalanced events in `logs`
    function _rebalances(Vm.Log[] memory logs) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == TrueoRebalancer.Rebalanced.selector) n++;
        }
    }

    function _assertModuleEmpty() internal view {
        assertEq(tyd.balanceOf(address(module)), 0);
        assertEq(yes.balanceOf(address(module)), 0);
        assertEq(no.balanceOf(address(module)), 0);
    }
}
