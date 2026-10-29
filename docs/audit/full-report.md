# 🔐 Security Review — trueo-rebalancer

> Final AI-assisted audit run (3 passes) on the one-shot module, before the fixes listed in
> [FIXES.md](FIXES.md). Line references and code snippets refer to that earlier revision. The "Known from earlier
> scans" table also lists records from scans of an earlier, chunked development version (`-chunk`, `-firstchunk`,
> `-tradermove`, `-previoustick` entries); those code paths no longer exist.


---

## Scope

|  |  |
| --- | --- |
| **Mode** | filename |
| **Files reviewed** | `src/TrueoRebalancer.sol` · `src/libraries/RebalanceMath.sol` · `src/libraries/RebalanceFlag.sol`<br>`src/trueo/hook/TruthMarketHookDemo.sol` |
| **Confidence threshold (1-100)** | 75 |
| **Passes** | 3 |
| **Memory** | 48 records before this scan · 55 after |

---

## Findings

[75] **1. Tiny positions on 128 ticks cap every rebalance**

`RebalanceMath.build` · Confidence: 75 · seen in 2/3 runs · KNOWN (2 scans)

**Description**
An attacker who opens about 64 tiny positions next to the price uses up the 128 walk steps, so every rebalance stops inside that small range.

**Fix**

```diff
-        for (uint256 w; w < MAX_WALK; ++w) {
+        // only segment-opening ticks use MAX_WALK; dust ticks and word ends use a larger MAX_MERGED (size mergedAt to it)
+        for (uint256 w; c.count < MAX_WALK && w < MAX_MERGED; ++w) {
```

---

[75] **2. The burn model rounds the LP fee once, so the burn reverts after both purchases**

`RebalanceMath.estimateProfit` · Confidence: 75 · seen in 3/3 runs · KNOWN (3 scans)

**Description**
Pool.swap rounds the LP fee up at every step, but the burn model rounds it once per pool, so an LP who adds non-dust ticks makes each burn revert after both purchases at the trader's gas cost.

**Fix**

```diff
-        uint256 slack = k * ROUND_PER_STEP;
+        // a purchase also rounds the LP fee up once at every segment edge it crosses
+        uint256 slack = (k + (c.mint ? 0 : i)) * ROUND_PER_STEP;
```

---

[75] **3. Cheap initialized ticks make each opted-in rebalance run out of gas**

`TrueoRebalancer._rebalance` · Confidence: 75 · seen in 2/3 runs · KNOWN (3 scans)

**Description**
An attacker places small non-dust positions on many ticks, so each opted-in rebalance reads up to 256 boundaries and runs out of gas, and the trader pays the forwarded gas.

**Fix**

```diff
         uint256 hi = _hi(m, mint, scale);
         if (hi == 0) return;
+        // stop before the walk when the forwarded gas cannot pay for a full walk and both swaps
+        if (gasleft() < MIN_REBALANCE_GAS) return;
```

---

Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [75] | Tiny positions on 128 ticks cap every rebalance |
| 2 | [75] | The burn model rounds the LP fee once, so the burn reverts after both purchases |
| 3 | [75] | Cheap initialized ticks make each opted-in rebalance run out of gas |

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

- **The NO curve is built before the YES swap runs** — `RebalanceMath.build` · seen in 1/3 runs · NEW — Code smells: `build` reads the bitmap and tick liquidity once, the YES sale runs `movePoolTick`, which can change NO pool liquidity before the NO sale — A NO pool with less liquidity than the model ends at `c.limit` and reverts PartialFill. We did not verify that the OrderManager changes liquidity on another pool.
- **The burn capacity rounds each merged segment once** — `RebalanceMath.capacity` · seen in 1/3 runs · NEW — Code smells: `capacity` returns `cumOut[count]`, a merged segment rounds its output once, Pool.swap rounds down at every merged step — When capacity binds, `_buyExactOut` can ask for more than the pool gives before the limit and revert PartialFill. At scale 1e12 this almost never happens, and we did not confirm a gap-zero market.
- **The sale model leaves out the fee rounding at segment edges** — `RebalanceMath.payFor` · seen in 3/3 runs · KNOWN (2 scans) — Code smells: `walk` takes the fee once as `n * (PIPS - fee) / PIPS`, v4 rounds the fee up at each step, the slack covers only `mergedAt` boundaries — The real sale can return less than the model, and on a decimals gap of zero the mint path reverts. We did not measure the gap on a live pool ladder.
- **The burn path buys YES and NO before it pays TYD in** — `TrueoRebalancer._buyAndBurn` · seen in 3/3 runs · NEW — Code smells: `_mintAndSell` pays its input in before the sales but `_buyAndBurn` pays TYD after take and burn, `_hi` reads YES and NO balances before the purchases — The OrderManager can defer TYD payouts to order owners, or fills can lower the YES or NO balance below n. We did not prove this differs from a normal swap.
- **The burn path pays the profit from the burn proceeds** — `TrueoRebalancer._buyAndBurn` · seen in 1/3 runs · KNOWN (2 scans) — Code smells: the burn path pays the profit with `_transfer` from the module balance, the module assumes `burn(n)` pays exactly `n / scale` TYD and never reads the ratio from the market — A market that pays less than x, or charges a burn fee, makes each burn rebalance revert. We did not confirm the real market's burn arithmetic.
- **An order that pays the rebalancer makes each crossing rebalance revert** — `TrueoRebalancer._checkClean` · seen in 1/3 runs · KNOWN (2 scans) — Code smells: `_checkClean` reverts `BalanceChanged` on any balance change, an order with the rebalancer as recipient pays it inside `movePoolTick` — Each rebalance that crosses that tick reverts after its swaps. We did not see whether the OrderManager accepts the rebalancer as a recipient.
- **The mint cap uses the physical TYD balance of the PoolManager** — `TrueoRebalancer._hi` · seen in 2/3 runs · NEW — Code smells: `balanceOf(poolManager) / 2` includes TYD that other open deltas depend on, order payouts in the sale afterSwap draw on it, the /2 cap assumes outcome prices of 1 TYD or less and `_limit` allows any price when `poolBoundaries` is unset — Earlier takes in the unlock shrink the rebalance, and a pool without bounds can make the final take revert. We did not confirm a live pool without bounds.
- **An attacker can mint pairs up to the cap and take the mint arbitrage** — `TrueoRebalancer._hi` · seen in 1/3 runs · KNOWN (2 scans) — Code smells: `_hi` returns 0 in mint once `max(totalSupply) >= yesNoTokenCap`, pairs burn back 1:1 — The attacker turns off the module's mint path and sells held pairs into each gap. We did not verify real cap sizes.
- **The real sale can return one or two units less than the model** — `TrueoRebalancer._mintAndSell` · seen in 1/3 runs · NEW — Code smells: each non-final exact-in step rounds the fee up on the outcome input, `walk` uses one net input for the whole sale, no slack for segment edges — The floored TYD output of the final step can be lower by up to one unit per leg. We did not run a case where this alone makes `out < x + minProfit`.
- **The module takes the scale from token decimals, the market a fixed 1e12** — `TrueoRebalancer._mintAndSell` · seen in 2/3 runs · KNOWN (2 scans) — Code smells: `scale = 10 ** (outDec - payDec)`, the market mints and burns at a fixed `1e12` — If the gap is not 12, the module pays outcome tokens that the market did not mint. We did not find a live Trueo market whose decimals gap is not 12.
- **Order payouts during the sales can leave too little TYD for the profit take** — `TrueoRebalancer._mintAndSell` · seen in 3/3 runs · NEW — Code smells: `_hi` caps x at half of the PoolManager TYD before any swap, the final take needs x + profit physical TYD, OrderManager fills pay owners from the PoolManager balance — The final profit take can revert. We did not measure how much TYD order fills take in one rebalance.
- **The rebalancer moves the next pool of a trader route** — `TrueoRebalancer._rebalance` · seen in 1/3 runs · KNOWN (2 scans) — Code smells: the rebalance moves both pools toward parity, a YES buy with the opt-in makes the module sell NO — A later NO sale in the same route gets a lower price. We did not measure the loss.
- **A sync before the swap turns the rebalancer off** — `TrueoRebalancer._rebalance` · seen in 2/3 runs · KNOWN (3 scans) — Code smells: `getSyncedCurrency() != address(0)` returns early, a native-ETH sync reads as address(0) and is harmless — A router that syncs a currency before its swap turns off every rebalance. We did not check which production routers do this.
- **A callback between the legs can move the second pool** — `TrueoRebalancer._rebalance` · seen in 1/3 runs · KNOWN (2 scans) — Code smells: `cY` and `cN` are built once before any swap, the YES swap's `afterSwap` calls `movePoolTick` before the NO swap, the PoolManager does not restrict who swaps while unlocked — An OrderManager callback that changes the NO pool makes the second leg revert. The OrderManager source is not in the repo, so we did not confirm this.
- **The module keeps the old markets after a Trueo migration** — `TrueoRebalancer._tradable` · seen in 1/3 runs · NEW — Code smells: `marketCodehash` and `manager` are immutable, `_tradable` and `register` trust only them — After a manager or implementation change, old markets stay registered and new markets cannot register. We did not confirm that Trueo migrates markets.
- **The rebalancer trades in every market status except finalized** — `TrueoRebalancer._tradable` · seen in 2/3 runs · KNOWN (3 scans) — Code smells: `_tradable` blocks only `STATUS_FINALIZED` (7), the real TruthMarketV2 status gates are not in the repository — A revert path after the swaps is unproven. We did not confirm which statuses the real market blocks for mint or burn.
- **The rebalancer trades a market after the manager deactivates it** — `TrueoRebalancer._tradable` · seen in 2/3 runs · KNOWN (3 scans) — Code smells: only `register` calls `manager.isActiveMarket`, `_tradable` does not check it again — The module keeps its mint and burn trades on a deactivated market. We did not confirm that a deactivated market still accepts mint and burn.
- **Register builds the NO pool key from the YES fee and spacing** — `TrueoRebalancer.register` · seen in 2/3 runs · KNOWN (2 scans) — Code smells: `MarketInfo` stores only `kYes.fee` and `kYes.tickSpacing`, `_keys` builds the NO key from them — A market whose NO pool has other parameters cannot register. No loss of funds follows.
- **The codehash check accepts any clone of the market implementation** — `TrueoRebalancer.register` · seen in 3/3 runs · KNOWN (3 scans) — Code smells: `marketCodehash` pins an EIP-1167 clone, anyone can deploy a clone with that codehash, `isActiveMarket` is checked only once — Only the one-time `isActiveMarket` check keeps a fake market out. We did not find a path from a deactivated market to a token loss.
- **The admin can set a minProfit that covers only two rounding steps** — `TrueoRebalancer.setParams` · seen in 2/3 runs · KNOWN (2 scans) — Code smells: the floor is `2 * ROUND_PER_STEP` (4 units), each swap can take up to MAX_WALK steps, minProfit and maxSize are global in payment-token units — A module that crosses many ticks starts rebalances that revert. We did not find a market that uses a second payment token.
- **A tight gas limit makes the rebalancer run out of gas** — `TruthMarketHookDemo._afterSwap` · seen in 2/3 runs · KNOWN (2 scans) — Code smells: `g = min(rebalanceGas, gasleft() - reserve)` and a call when `g >= rebalanceGasMin`, the hook ignores the revert — A trader who sets a gas limit just above reserve + rebalanceGasMin starts a call that does nothing. We did not measure the gas limits.
- **A router that adds the opt-in word makes its users pay the rebalancer gas** — `TruthMarketHookDemo._afterSwap` · seen in 3/3 runs · KNOWN (3 scans) — Code smells: `RebalanceFlag.isSet(hookData)` is the only gate, the call gets up to `rebalanceGas`, `profitRecipient` is a fixed admin address — The trader pays up to rebalanceGas for each swap and gets nothing back. We did not check which live routers add the word.

---

## Known from earlier scans

_Recorded by earlier scans of this repo, not raised again by this one. Not re-checked — a record here may be fixed, or may still be live and missed._

| Scans | Kind | Location | Title |
|---|---|---|---|
| 1 | LEAD | `TrueoRebalancer._buyAndBurn` | A blocked recipient makes every burn rebalance revert |
| 1 | LEAD | `TrueoRebalancer._checkClean` | Tokens sent to the rebalancer by mistake stay there |
| 1 | LEAD | `TrueoRebalancer.-chunk` | Orders on eight ticks of the other pool can stop each first chunk |
| 1 | LEAD | `TrueoRebalancer.-firstchunk` | The unmeasured first chunk has no gas bound |
| 1 | LEAD | `TrueoRebalancer.-firstchunk` | A nested swap can change the start tick that the rebalancer reads |
| 1 | LEAD | `TrueoRebalancer._limit` | A start tick outside the bounds makes every rebalance revert |
| 1 | LEAD | `TrueoRebalancer._limit` | A lower bound below MIN_TICK makes the rebalancer revert |
| 1 | LEAD | `TrueoRebalancer._mintAndSell` | The mint path mints before it knows that the first chunk pays |
| 1 | LEAD | `TrueoRebalancer._mintAndSell` | A blocked recipient makes every mint rebalance revert |
| 1 | FINDING | `TrueoRebalancer.-next` | A near boundary in the trader pool stops the whole rebalance |
| 1 | LEAD | `TrueoRebalancer.-next` | Gas alone sizes the later chunks |
| 1 | LEAD | `TrueoRebalancer._rebalance` | The module limits the trader move but not its own move |
| 1 | LEAD | `TrueoRebalancer._rebalance` | Order fills run inside the capped rebalancer gas |
| 1 | LEAD | `TrueoRebalancer._rebalance` | The model can size a trade that the pool cannot fill |
| 1 | LEAD | `TrueoRebalancer._rebalance` | The rebalancer can use the order budget of the transaction |
| 1 | LEAD | `TrueoRebalancer._rebalance` | The first profit check leaves out the protocol fee |
| 1 | LEAD | `TrueoRebalancer._rebalance` | A decimals gap of 59 or more overflows the scale |
| 1 | FINDING | `TrueoRebalancer._rebalance` | Dust liquidity on eight ticks caps every rebalance |
| 1 | LEAD | `TrueoRebalancer.-settleburn` | The burn settlement uses the decimals gap, the market a fixed ratio |
| 1 | LEAD | `TrueoRebalancer.-tradermove` | A split swap passes the maxTraderMoveTicks check |
| 1 | LEAD | `TrueoRebalancer.constructor` | The constructor accepts a zero market codehash |
| 1 | LEAD | `TrueoRebalancer.register` | Register takes the scale from token decimals |
| 1 | LEAD | `TrueoRebalancer.register` | Only register checks that the market is active |
| 1 | LEAD | `TrueoRebalancer.register` | A second register can revert on a token that rejects a new approval |
| 1 | LEAD | `TrueoRebalancer.setParams` | The admin can set the rebalancer or the PoolManager as recipient |
| 1 | LEAD | `TruthMarketHookDemo._afterSwap` | The rebalancer moves the price back over deferred order ticks |
| 2 | LEAD | `TruthMarketHookDemo._afterSwap` | A nested swap in the order manager changes the tick the rebalancer reads |
| 1 | FINDING | `TruthMarketHookDemo._afterSwap` | A fixed gas reserve lets the rebalancer make a trader route run out of gas |
| 1 | LEAD | `TruthMarketHookDemo._afterSwap` | The rebalancer moves the pool before the trader reads it again |
| 1 | LEAD | `TruthMarketHookDemo.previoustick` | The hook keeps one previous-tick slot for every pool |

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
