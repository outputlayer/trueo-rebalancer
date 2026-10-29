# Changes after the final audit run

The final AI-assisted run ([full-report.md](full-report.md)) reported three findings and a list of leads. This file
records what changed in the code afterwards and which items are accepted as documented limitations. Every fix is
covered by blind-written tests (`test/blind3/AuditGuards.t.sol`, `test/blind3/fork/ForkBurnPayout.t.sol`) and by
mutants #21 and #22 in [`reports/mutation_matrix.md`](../../reports/mutation_matrix.md).

## Fixed

| Item | Change |
|---|---|
| Finding 2: the model rounds the LP fee once per pool, `Pool.swap` at every step | `RebalanceMath.payFor` now adds `ROUND_PER_STEP` (2 units) of slack for every segment edge the trade crosses, in addition to every merged boundary: `slack = (k + i) * ROUND_PER_STEP`. Applied to both sides (a sale gets less, a purchase costs more), which also covers the leads "the sale model leaves out the fee rounding at segment edges" and "the real sale can return one or two units less than the model". |
| Lead: the burn path buys YES and NO before it pays TYD in | `_buyAndBurn` now burns the pairs and pays all the TYD into the PoolManager **before** the two exact-out purchases, mirroring the mint path's pay-before-sell. The OrderManager pays the owners of sell orders filled by those purchases from the PoolManager's balance, so their TYD is already there and no payout is deferred. |
| Finding 3: cheap initialized ticks can make a rebalance run out of gas | Mitigated at the hook: the default `rebalanceGasMin` is 750,000 (above the largest module gas measured over the hook's history, 715k), so the module is never started with too little gas to finish a normal rebalance. The remaining griefing case is accepted below. |

## Accepted limitations

| Item | Why it is accepted |
|---|---|
| Finding 1: dust positions use up the 128-boundary walk | Dust ticks are merged and do not open segments, but every boundary still counts toward the walk cap. An attacker must pay for the positions and only reduces what one rebalance captures; nothing is lost. |
| Finding 3 (residual): griefing beyond `rebalanceGas` | A griefer who places enough initialized ticks or orders on the module's path can make it need more than `rebalanceGas`. The call then reverts, nothing is captured and the opted-in trader pays up to `rebalanceGas` of extra gas. The trader's swap result is unaffected. |
| OrderManager LP-fee payouts in outcome tokens on near-total buy-backs | When the module buys back almost all of the PoolManager's outcome tokens, small LP-fee payouts of the OrderManager in that token may be deferred; they remain claimable. Principal payouts of filled orders are not affected. |
| A router that adds the opt-in word makes its users pay module gas | The opt-in is the trader's (or frontend's) explicit consent; without it the hook is unchanged. |
| A sync before the swap turns the module off | Intentional: a module `sync` between a caller's `sync` and `settle` would take that caller's payment, so the module stays out. |
| A tight gas limit starts a call that does nothing | The hook only calls the module with at least `rebalanceGasMin`; below a full rebalance's need the module reverts and only its call is lost. |
| Mint cap uses half the PoolManager's TYD balance | Relies on outcome prices <= 1 TYD (the validator's bounds); otherwise only the module's final take can revert, never the trader's swap. |
| Codehash pin accepts any clone; `isActiveMarket` checked only at registration; immutable manager and codehash | A clone must also be an active market of the manager to register. The module can never lose funds on a market (every call ends with its balances unchanged), and a Trueo migration would need a new module deployment. |
| Decimals-based scale | The market's mint/burn rule is decimals-based as well; `register` rejects markets whose outcome decimals are below the payment token's. |
| NO-pool curve built before the YES swap; a callback between the legs | If the second pool moved, the second leg ends at its limit and the module call reverts (`PartialFill`); the trader is unaffected. |
| The module moves the next pool of a route | Integration rule: the opt-in goes on the last Trueo hop only. |
