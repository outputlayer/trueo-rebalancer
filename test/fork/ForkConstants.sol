// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @notice Trueo on Base (verified sources: Sourcify exact match; roles checked by hasRole on 2026-10-27).
abstract contract ForkConstants {
    IPoolManager internal constant PM = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);
    address internal constant REAL_HOOK = 0x3E83479B2276EcFb7C7181F67b5d092d3511e0C4; // TruthMarketHook
    address internal constant OM = 0x1cdB1C43eB64e99780EA9d3C7162C23432C59a1A; // OrderManager
    address internal constant FC = 0x8C6c622A7DE8cEbD1A43e2Fb8363ebbE9120134F; // FeeCollector
    address internal constant VALIDATOR = 0x55e26CF92B924C069db4d8Da7B0b36154374Dd38; // TruthMarketSwapValidator
    address internal constant MANAGER = 0x61A98Bef11867c69489B91f340fE545eEfc695d7; // TruthMarketManager proxy
    address internal constant TYD = 0xb13CF163d916917d9cD6E836905cA5f12a1dEF4B; // 6 decimals
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    /// DEFAULT_ADMIN_ROLE on hook, OrderManager, FeeCollector and validator
    address internal constant DEPLOYER = 0xa9d19Dd30540fB39C8e058E81DaA21FfCcfB4a57;
    /// manager owner(); DEFAULT_ADMIN_ROLE, MARKET_CREATOR_ROLE and PAUSER_ROLE on the manager
    address internal constant SAFE = 0x303A5c7f55cD8477CAB1A84519638f68344cEA79;
    address internal constant AERO = 0xb1cF4F31B29579045143de99Fec3789d3941173C; // YES token0, NO token1
    address internal constant PUMP = 0xAD5374e6CC185D64e02b2C9E4B8bd14820781553; // YES token0, NO token0
    /// runtime codehash of every EIP-1167 clone of TruthMarketV2 0x2CA8...3409
    bytes32 internal constant CLONE_CODEHASH = 0x4d693f3f0016b792f66593f94d7b8ffa24c594673ffef056cd4b78c148927b32;
    uint256 internal constant HOOK_FEE = 80;
    uint256 internal constant FORK_BLOCK = 53172900;
}
