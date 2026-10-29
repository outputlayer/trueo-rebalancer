// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Blind3Base} from "./Blind3Base.sol";
import {TrueoRebalancer} from "../../src/TrueoRebalancer.sol";
import {ITrueoManager} from "../../src/interfaces/ITrueo.sol";
import {MockTruthMarket} from "../mocks/MockTruthMarket.sol";
import {MockOutcomeToken} from "../mocks/MockOutcomeToken.sol";

/// Test-plan items 1-9: module admin, configuration and registration.
contract Blind3AdminTest is Blind3Base {
    using PoolIdLibrary for PoolKey;

    event Registered(address indexed market);
    event ParamsSet(address profitRecipient, uint256 minProfit, uint256 maxSize, uint16 thresholdBps);
    event EnabledSet(bool enabled);
    event AdminSet(address admin);

    address internal constant YES2 = 0x2000000000000000000000000000000000000002;
    address internal constant NO2 = 0xA00000000000000000000000000000000000000A;

    function _deploy(IPoolManager pm, address h, address mg, bytes32 ch, address ad) internal returns (TrueoRebalancer) {
        return new TrueoRebalancer(pm, h, ITrueoManager(mg), ch, ad);
    }

    // ---------------------------------------------------------------- 1

    function test_a1_constructor_zeroAddresses() public {
        bytes32 ch = address(market).codehash;
        vm.expectRevert(TrueoRebalancer.ZeroAddress.selector);
        _deploy(IPoolManager(address(0)), HOOK, address(mgr), ch, admin);
        vm.expectRevert(TrueoRebalancer.ZeroAddress.selector);
        _deploy(poolManager, address(0), address(mgr), ch, admin);
        vm.expectRevert(TrueoRebalancer.ZeroAddress.selector);
        _deploy(poolManager, HOOK, address(0), ch, admin);
        vm.expectRevert(TrueoRebalancer.ZeroAddress.selector);
        _deploy(poolManager, HOOK, address(mgr), ch, address(0));

        TrueoRebalancer m = _deploy(poolManager, HOOK, address(mgr), bytes32(0), admin);
        assertEq(m.marketCodehash(), bytes32(0));
        assertEq(address(m.poolManager()), address(poolManager));
        assertEq(m.hook(), HOOK);
        assertEq(address(m.manager()), address(mgr));
        assertEq(m.admin(), admin);
        assertEq(m.profitRecipient(), address(0));
        assertFalse(m.enabled());
    }

    // ---------------------------------------------------------------- 2

    function test_a2_minProfitFloor() public {
        vm.startPrank(admin);
        module.setParams(recipient, 77, 1e6, 20);
        for (uint256 mp; mp < 5; mp++) {
            vm.expectRevert(TrueoRebalancer.BadParams.selector);
            module.setParams(recipient, mp, MAX_SIZE, THRESHOLD_BPS);
            assertEq(module.minProfit(), 77, "rejected minProfit stored");
        }
        module.setParams(recipient, 5, MAX_SIZE, THRESHOLD_BPS);
        vm.stopPrank();
        assertEq(module.minProfit(), 5);
    }

    // ---------------------------------------------------------------- 3

    function test_a3_thresholdBound() public {
        vm.startPrank(admin);
        vm.expectRevert(TrueoRebalancer.BadParams.selector);
        module.setParams(recipient, MIN_PROFIT, MAX_SIZE, 10_001);
        assertEq(module.thresholdBps(), THRESHOLD_BPS);
        vm.expectRevert(TrueoRebalancer.BadParams.selector);
        module.setParams(recipient, MIN_PROFIT, MAX_SIZE, type(uint16).max);
        module.setParams(recipient, MIN_PROFIT, MAX_SIZE, 10_000);
        vm.stopPrank();
        assertEq(module.thresholdBps(), 10_000);
    }

    // ---------------------------------------------------------------- 4

    function test_a4_setParams_storesEveryValue() public {
        address r = makeAddr("r4");
        vm.expectEmit(false, false, false, true, address(module));
        emit ParamsSet(r, 5, 6, 7);
        vm.prank(admin);
        module.setParams(r, 5, 6, 7);
        assertEq(module.profitRecipient(), r);
        assertEq(module.minProfit(), 5);
        assertEq(module.maxSize(), 6);
        assertEq(module.thresholdBps(), 7);

        // rejected calls leave every value in place
        address r2 = makeAddr("r4b");
        vm.startPrank(admin);
        vm.expectRevert(TrueoRebalancer.BadParams.selector);
        module.setParams(r2, 4, 1e9, 99);
        vm.expectRevert(TrueoRebalancer.BadParams.selector);
        module.setParams(r2, 50, 1e9, 10_001);
        vm.expectRevert(TrueoRebalancer.ZeroAddress.selector);
        module.setParams(address(0), 50, 1e9, 99);
        vm.expectRevert(TrueoRebalancer.BadParams.selector);
        module.setParams(address(module), 50, 1e9, 99);
        vm.expectRevert(TrueoRebalancer.BadParams.selector);
        module.setParams(address(poolManager), 50, 1e9, 99);
        vm.stopPrank();
        vm.prank(trader);
        vm.expectRevert(TrueoRebalancer.NotAdmin.selector);
        module.setParams(r2, 50, 1e9, 99);
        assertEq(module.profitRecipient(), r);
        assertEq(module.minProfit(), 5);
        assertEq(module.maxSize(), 6);
        assertEq(module.thresholdBps(), 7);
    }

    // ---------------------------------------------------------------- 5

    function test_a5_enablingNeedsRecipient() public {
        TrueoRebalancer m = _deploy(poolManager, HOOK, address(mgr), address(market).codehash, admin);
        assertEq(m.profitRecipient(), address(0));
        assertFalse(m.enabled());
        vm.prank(admin);
        vm.expectRevert(TrueoRebalancer.BadParams.selector);
        m.setEnabled(true);
        assertFalse(m.enabled());

        vm.prank(trader);
        vm.expectRevert(TrueoRebalancer.NotAdmin.selector);
        m.setEnabled(false);

        vm.expectEmit(false, false, false, true, address(m));
        emit EnabledSet(false);
        vm.prank(admin);
        m.setEnabled(false);
        assertFalse(m.enabled());

        // with a recipient it can be enabled, and disabled again
        vm.startPrank(admin);
        m.setParams(recipient, 5, 1e6, 10);
        vm.expectEmit(false, false, false, true, address(m));
        emit EnabledSet(true);
        m.setEnabled(true);
        assertTrue(m.enabled());
        m.setEnabled(false);
        assertFalse(m.enabled());
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- 6

    function test_a6_setAdmin() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(trader);
        vm.expectRevert(TrueoRebalancer.NotAdmin.selector);
        module.setAdmin(trader);
        assertEq(module.admin(), admin);

        vm.prank(admin);
        vm.expectRevert(TrueoRebalancer.ZeroAddress.selector);
        module.setAdmin(address(0));
        assertEq(module.admin(), admin);

        vm.expectEmit(false, false, false, true, address(module));
        emit AdminSet(newAdmin);
        vm.prank(admin);
        module.setAdmin(newAdmin);
        assertEq(module.admin(), newAdmin);

        vm.startPrank(admin);
        vm.expectRevert(TrueoRebalancer.NotAdmin.selector);
        module.setParams(recipient, 9, 9, 9);
        vm.expectRevert(TrueoRebalancer.NotAdmin.selector);
        module.setEnabled(false);
        vm.expectRevert(TrueoRebalancer.NotAdmin.selector);
        module.setMarketEnabled(address(market), false);
        vm.expectRevert(TrueoRebalancer.NotAdmin.selector);
        module.setAdmin(admin);
        vm.stopPrank();

        vm.prank(newAdmin);
        module.setParams(recipient, 9, 10, 11);
        assertEq(module.minProfit(), 9);
        assertEq(module.maxSize(), 10);
        assertEq(module.thresholdBps(), 11);
    }

    // ---------------------------------------------------------------- 7

    function _assertInfo(PoolId id, address m, address y, address n) internal view {
        TrueoRebalancer.MarketInfo memory i = module.marketOf(id);
        assertEq(i.market, m, "market");
        assertEq(i.gap, 12, "gap");
        assertEq(i.fee, 1, "fee");
        assertEq(i.tickSpacing, 60, "spacing");
        assertEq(i.tyd, TYD, "tyd");
        assertEq(i.yes, y, "yes");
        assertEq(i.no, n, "no");
    }

    function test_a7_registerStoresBothPools() public {
        _assertInfo(kYes.toId(), address(market), YES, NO);
        _assertInfo(kNo.toId(), address(market), YES, NO);
        assertEq(tyd.allowance(address(module), address(market)), type(uint256).max, "TYD allowance");
        assertEq(yes.allowance(address(module), address(market)), type(uint256).max, "YES allowance");
        assertEq(no.allowance(address(module), address(market)), type(uint256).max, "NO allowance");
        // unknown pool: all zero
        TrueoRebalancer.MarketInfo memory z = module.marketOf(PoolId.wrap(keccak256("unknown")));
        assertEq(z.market, address(0));
        assertEq(z.gap, 0);
        assertEq(z.fee, 0);
        assertEq(z.tickSpacing, 0);
        assertEq(z.tyd, address(0));
        assertEq(z.yes, address(0));
        assertEq(z.no, address(0));
    }

    // ---------------------------------------------------------------- 8

    function test_a8a_register_wrongCodehash() public {
        TrueoRebalancer m = _deploy(poolManager, HOOK, address(mgr), keccak256("other code"), admin);
        vm.expectRevert(TrueoRebalancer.NotTrueoMarket.selector);
        m.register(address(market));
        assertEq(m.marketOf(kYes.toId()).market, address(0));
    }

    function test_a8b_register_inactiveMarket() public {
        TrueoRebalancer m = _deploy(poolManager, HOOK, address(mgr), address(market).codehash, admin);
        mgr.setActive(address(market), false);
        vm.expectRevert(TrueoRebalancer.NotTrueoMarket.selector);
        m.register(address(market));
        assertEq(m.marketOf(kNo.toId()).market, address(0));
        // control: active again => accepted
        mgr.setActive(address(market), true);
        m.register(address(market));
        assertEq(m.marketOf(kNo.toId()).market, address(market));
    }

    function test_a8c_register_otherHook() public {
        MockTruthMarket m2 = new MockTruthMarket();
        m2.init(mgr, ERC20(TYD), yes, no, LP_FEE, SPACING, address(0xdead));
        mgr.setActive(address(m2), true);
        assertEq(address(m2).codehash, address(market).codehash, "same code");
        vm.expectRevert(TrueoRebalancer.NotTrueoMarket.selector);
        module.register(address(m2));
        // a market on this hook with the same code is accepted (control)
        (MockTruthMarket m3,,) = _newMarket(YES2, NO2, 0.6e18, 0.4e18, true, 0);
        module.register(address(m3));
    }

    function test_a8d_register_noCode() public {
        vm.expectRevert(TrueoRebalancer.NotTrueoMarket.selector);
        module.register(makeAddr("eoa"));
    }

    // ---------------------------------------------------------------- 9

    function test_a9_register_permissionless_idempotent() public {
        (MockTruthMarket m2, PoolKey memory ky, PoolKey memory kn) = _newMarket(YES2, NO2, 0.6e18, 0.4e18, true, 0);
        address anyone = makeAddr("anyone");
        vm.expectEmit(true, false, false, true, address(module));
        emit Registered(address(m2));
        vm.prank(anyone);
        module.register(address(m2));
        TrueoRebalancer.MarketInfo memory i1 = module.marketOf(ky.toId());
        assertEq(i1.market, address(m2));
        assertEq(i1.yes, YES2);
        assertEq(i1.no, NO2);
        assertEq(module.marketOf(kn.toId()).market, address(m2));

        vm.prank(trader);
        module.register(address(m2));
        module.register(address(market));
        TrueoRebalancer.MarketInfo memory i2 = module.marketOf(ky.toId());
        assertEq(abi.encode(i1), abi.encode(i2), "marketOf changed by a second register");
        assertEq(abi.encode(module.marketOf(kn.toId())), abi.encode(i1));
        _assertInfo(kYes.toId(), address(market), YES, NO);
        assertEq(MockOutcomeToken(YES2).allowance(address(module), address(m2)), type(uint256).max);
    }
}
