# TrueoRebalancer: design

This document describes the current, one-shot version of the module and of the hook change it needs.

## 1. Goal

Trueo prediction markets on Base trade YES and NO outcome tokens against a payment token (TYD) in two Uniswap v4
pools that share one hook (`TruthMarketHook`). A pair of YES + NO can always be minted from, or burned for, one
payment token through the market contract, so after a trade the sum of the two pool prices drifts away from 1 and
arbitrageurs close the gap.

TrueoRebalancer closes that gap inside the trader's own transaction, when the trader asks for it:

- YES + NO > 1: mint pairs and sell YES and NO into both pools;
- YES + NO < 1: buy YES and NO from both pools and burn the pairs;

and sends the captured spread to a configurable recipient. The module's swaps are ordinary pool swaps, so they pay
Trueo's hook fee and LP fees, run the swap validator and fill OrderManager orders like any other swap.

The main requirement is that it harms nobody: the trader's result, Trueo's fees, validator and orders behave
exactly as without the module (section 4).

## 2. Trueo contracts (Base)

| Component | Address | Role for the module |
|---|---|---|
| PoolManager (Uniswap v4) | `0x4985...2b2b` | holds pool balances; the module trades inside the trader's unlock |
| TruthMarketHook | `0x3E83...e0C4` | beforeSwap (pause, records the tick), afterSwap (validator, `movePoolTick`, 0.8% hook fee) |
| OrderManager | `0x1cdB...9a1A` | limit orders as range positions, filled from the hook's afterSwap |
| TruthMarketSwapValidator | `0x55e2...Dd38` | keeps the post-swap tick inside per-pool bounds |
| FeeCollector | `0x8C6c...134F` | receives the hook fee as ERC-6909 claims |
| TruthMarketManager | `0x61A9...95d7` | creates markets, `isActiveMarket`, global pause |
| Market (EIP-1167 clone of TruthMarketV2) | one per market | `mint`/`burn` of YES + NO pairs, pause, status, token cap |

## 3. Architecture

### 3.1 Hook change (`src/trueo/hook/TruthMarketHookDemo.sol`, `patches/TruthMarketHookDemo.patch`)

The demo hook is Trueo's verified `TruthMarketHook` source with a small patch (61 added code lines; the original
logic is unchanged):

- The original `_afterSwap` body moves unchanged into `_afterSwapTrueo`. The new `_afterSwap` runs it first and only
  then, as the last step, may call the rebalancer.
- New storage after the original layout: `rebalancer`, `rebalanceGas`, `rebalanceGasReserve` (default 1,000,000),
  `rebalanceGasMin` (default 750,000). Slots 0-6 are identical to the deployed hook.
- Admin setters (`DEFAULT_ADMIN_ROLE`): `setRebalancer` (a contract or zero), `setRebalanceGas`,
  `setRebalanceGasReserve` (at least `MIN_REBALANCE_GAS_RESERVE` = 150,000), `setRebalanceGasMin`.

Gate, evaluated after the original afterSwap work:

1. `rebalancer != 0` and the swap's `hookData` ends with the 32-byte opt-in word
   `keccak256("TrueoRebalancer.optIn.v1")` (`RebalanceFlag`). Otherwise nothing else happens: an unflagged swap is
   byte-identical to the original hook (same state, same logs).
2. `g = min(rebalanceGas, gasleft() - rebalanceGasReserve)` (0 if negative). The call is made only if `g != 0` and
   `g >= rebalanceGasMin`.
3. `onSwap(key)` is sent by a low-level `call` with gas `g`; success, failure and return data are ignored. Any
   failure of the module, out of gas included, reverts only the module's call frame.

The reserve is what the hook keeps for everything after the call: the rest of afterSwap, the PoolManager, the
router's settlement and any later swap of the same transaction. The floor of 150,000 is twice the largest need
measured for a single swap on a Base fork (56,640 gas with all accounts cold), rounded up. A later hop of a route
that fills orders can need more (342,773 measured), which is why the opt-in belongs on the last Trueo hop only and
the default reserve is 1,000,000.

### 3.2 Module (`src/TrueoRebalancer.sol`, `src/libraries/RebalanceMath.sol`)

`onSwap(PoolKey key)` may only be called by the hook. A transient lock makes a nested call return at once (the
module's own swaps go through the hook, but carry no opt-in, so the shipped hook never re-enters; the lock is a
second guard). `_rebalance` then:

1. **Cheap exits, no side effects:** module disabled; a currency is synced in the PoolManager (a caller between
   `sync` and `settle`); pool not registered or switched off for that market; manager or market paused; market
   finalized; either pool paused on the hook; a pool without a price.
2. **Direction:** from both `slot0` prices, mint if YES + NO > 1 + threshold, burn if YES + NO < 1 - threshold,
   otherwise return.
3. **Fee pre-check:** `RebalanceMath.gainful` tests whether the first unit pays after both pools' swap fees (LP fee
   combined with the protocol fee of the direction the module trades) and the hook fee.
4. **Upper bound (`_hi`):** `maxSize`, the PoolManager's balance (burn: YES and NO it can pay out; mint: half of
   its TYD, because the mint takes the size up front and the profit at the end), and in mint the room left under
   the market's token cap.
5. **Model:** `RebalanceMath.build` reads each pool from the current price toward the validator bound the way
   `Pool.swap` steps (initialized ticks and bitmap-word ends), for at most 128 boundaries, into a piecewise curve
   with constant liquidity per segment. Dust ticks (|liquidityNet| * 1e6 <= liquidity) are merged into the open
   segment, which keeps the lowest liquidity seen. The walk also stops where the stop rule says that a further
   unit cannot pay even at the other pool's current price.
6. **Size:** bisection for the largest size at which one more unit is still gainful, to 1/256 of the bracket.
7. **Decide before acting:** `estimateProfit` at that size, made conservative by 2 units of rounding per step
   boundary and segment edge each swap crosses. If it is below `minProfit` the module returns with no side effect.
8. **Execute in one shot:**
   - mint: take x TYD from the PoolManager, mint x pairs, pay the YES and NO into the PoolManager, then sell them
     exact-in on both pools, require `out >= x + minProfit`, take the profit to the recipient;
   - burn: take n YES and n NO from the PoolManager, burn them for TYD, pay all the TYD in, then buy n YES and n NO
     exact-out on both pools, require `got >= cost + minProfit`, take the profit to the recipient.

   Paying in before the swaps matters: the OrderManager pays the owners of filled orders from the PoolManager's
   balance during the module's swaps and would defer a payout if that balance were short.
9. **Clean exit:** every PoolManager delta of the module is zero and its token balances equal those before the
   call; otherwise it reverts. The module holds no funds between calls.

Partial fills (`PartialFill`), a real profit below `minProfit` (`NotProfitable`) or any other failure revert the
whole module call; the trader's swap continues unaffected.

### 3.3 Parameters

Module admin: `profitRecipient` (not zero, the module or the PoolManager), `minProfit` (> 4 units, i.e. at least
5), `maxSize`, `thresholdBps` (<= 10,000), `enabled` (needs a recipient), per-market `setMarketEnabled`,
`setAdmin`. `register(market)` is permissionless: the market must have the pinned clone codehash, be active in the
manager, use the module's hook for both pools, and have outcome decimals >= payment decimals.

Hook admin: `rebalancer`, `rebalanceGas` (recommended 1,500,000), `rebalanceGasMin` (default 750,000, above the
largest module gas measured over the hook's swap history), `rebalanceGasReserve` (default 1,000,000, floor 150,000).

## 4. Invariants

| # | Rule |
|---|---|
| I1 | The trader's swap always completes, whatever the module does (revert, out of gas, missing liquidity). |
| I2 | The trader's result is identical to the original hook, to the wei. Swaps without the opt-in are fully identical; in a multi-swap transaction every swap up to and including the opted-in one is identical. |
| I3 | Trueo's fees never decrease: the trader's swap pays as before and the module's swaps pay in addition. |
| I4 | Limit orders fill correctly on both pools; order owners are paid in the same transaction as by an ordinary swap. |
| I5 | The validator's bounds hold: the module never moves a price past them. |
| I6 | Paused manager, market or pool, finalized market or exhausted token cap: the module does nothing. |
| I7 | No capital at risk: after a call the module's balances equal those before; the profit goes to the recipient. |
| I8 | No recursion. |
| I9 | Module gas is bounded by `rebalanceGas`; if gas is short the module reverts and the trade passes. |
| I10 | With `rebalancer = 0`, or without the opt-in, the hook behaves exactly like the original. |

## 5. Integration

- Opt-in: append the 32-byte word to the swap's `hookData` (a suffix keeps any future reader of hookData that
  decodes from byte 0 unaffected). On a route, put it on the last Trueo hop only: an opt-in on an earlier hop moves
  the next pool before the trader trades it.
- Gas: the module only runs when the transaction leaves `rebalanceGasMin` + reserve after the swap, so a frontend
  that sets the opt-in should add headroom of about `rebalanceGas` + reserve + ~0.5M (e.g. +3M at the recommended
  settings), or size the limit from an `eth_call` / `eth_simulateV1` dry run with a high gas limit. `eth_estimateGas`
  alone finds the lowest limit at which the swap succeeds, which is one where the hook skips the module.

## 6. Known limitations

- Dust positions placed near the price can use up the 128-boundary walk and reduce what one rebalance captures.
- A griefer who places many cheap initialized ticks or orders on the module's path can make the module exceed
  `rebalanceGas`: it then reverts and the opted-in trader pays up to `rebalanceGas` extra gas with nothing
  captured.
- On a near-total buy-back the OrderManager may defer small LP-fee payouts in outcome tokens (they remain claimable).
- The opted-in trader pays the module's gas; the profit goes to the recipient. The design assumes Base gas prices
  and is not suitable as-is for Ethereum mainnet.
- `marketCodehash` and `manager` are immutable: a Trueo migration to a new market implementation needs a new module.
