# 1tx Architecture

This document explains the product architecture in two layers:

- first, a high-level explanation for non-technical readers,
- then the lower-level contract and execution details.

## In plain English

1tx turns lending positions into swapable products.

Instead of asking users to learn each lending protocol, bridge tokens manually, swap into the right asset, and then deposit, 1tx packages that work into a swap experience that can be distributed through Uniswap V4.

There are two product shapes:

- `SwapDepositRouter`: buy or sell one lending position in one transaction.
- `PortfolioHook` + `PortfolioVault`: buy or sell a diversified lending portfolio through a Uniswap pool.

At a business level, the idea is simple:

- users come with a stablecoin,
- 1tx handles any internal swaps and protocol interactions,
- users leave with either a single yield position or a portfolio share.

![Shared architecture](diagrams/shared-architecture.drawio.png)

## What each product does

### 1. Router product

The router is the simple, direct product.

A user says, in effect: "Take my stablecoin and put me into this specific lending market." The router handles the operational steps in the middle.

That means the router can:

- accept one stable input token,
- swap into the right market asset if needed,
- deposit into the selected lending protocol,
- return the protocol's yield token to the user,
- unwind the position back to stable on sell.

This is the fastest path for users who want one position, not a basket.

![SwapDepositRouter flow](diagrams/router-flow.drawio.png)

### 2. Hook product

The hook product is the portfolio version.

Instead of buying one lending market, the user buys exposure to a managed basket of markets. The basket can be split across protocols like Aave, Morpho, Euler, Compound, or Fluid, based on target weights set by the vault.

To the user, it looks like a swap into a portfolio token. Behind the scenes, the system deploys capital across the underlying lending positions and maintains portfolio accounting.

This is the product aimed at turning lending strategies into something that feels like a tradable on-chain fund.

![PortfolioHook flow](diagrams/portfolio-hook-flow.drawio.png)

## Why Uniswap V4 matters

Uniswap is not just used for price execution here. It is also the distribution surface.

That matters because it means:

- users can access yield products from familiar swap interfaces,
- frontends do not need custom lending integrations for each protocol,
- the same execution engine can power both single-market products and portfolio products.

In short: 1tx uses swap infrastructure as the entrypoint for yield products.

## Technical overview

The two products solve different UX problems, but they share the same execution building blocks:

- `InstrumentRegistry` resolves an `instrumentId` into `(adapter, marketId)`.
- `SwapPoolRegistry` resolves a directional token pair into the Uniswap V4 `PoolKey` used for internal swaps.
- `SwapExecutor` performs `poolManager.swap()` plus the required `sync`, `settle`, and `take` steps.
- `LendingExecutor` handles adapter approvals, deposits, and withdrawals.

### Shared design constraint

Both products treat Uniswap V4 as the settlement layer for token movement and lending protocols as the yield layer.

The important technical difference is PoolManager execution context:

- `SwapDepositRouter` starts from a normal external call, so it must enter PoolManager context with `poolManager.unlock()` and finish swap work in `unlockCallback()`.
- `PortfolioHook` is already inside PoolManager execution during `beforeSwap()`, so it can call the same swap and lending libraries directly without nesting `unlock()`.

That is why both products can share the same libraries even though they enter the system differently.

### Core contracts

- `src/SwapDepositRouter.sol`: user-facing router for single-instrument buy and sell flows.
- `src/hooks/PortfolioHook.sol`: hook that intercepts swaps in a zero-liquidity Uniswap V4 pool and settles them at NAV.
- `src/hooks/PortfolioVault.sol`: ERC20 share token and portfolio accounting layer used by the hook.
- `src/registries/InstrumentRegistry.sol`: registry of globally unique instrument IDs.
- `src/registries/SwapPoolRegistry.sol`: registry of internal swap pools for directional token pairs.
- `src/libraries/SwapExecutor.sol`: reusable V4 swap settlement logic.
- `src/libraries/LendingExecutor.sol`: reusable adapter interaction logic.

## SwapDepositRouter details

`SwapDepositRouter` is the single-instrument path: the user chooses one instrument, pays in the configured stable token, and receives the protocol-specific yield token.

### Buy flow

1. The user calls `buy(instrumentId, amount, minDepositedAmount, ...)`.
2. The router resolves the instrument through `InstrumentRegistry`.
3. If the target market uses a different underlying token, the router gets the matching `PoolKey` from `SwapPoolRegistry`.
4. The router pulls stable tokens from the payer.
5. The router calls `poolManager.unlock(...)` and executes the swap inside `unlockCallback()` through `SwapExecutor`.
6. The router deposits the resulting market currency into the lending adapter through `LendingExecutor`.
7. The recipient receives the yield-bearing token directly.

If the market currency already matches the configured stable token, the swap step is skipped.

### Sell flow

1. The user calls `sell(instrumentId, yieldTokenAmount, minOutputAmount)`.
2. The router resolves the adapter and yield token for the instrument.
3. `LendingExecutor` pulls yield tokens from the user into the adapter and withdraws underlying assets back to the router.
4. If the withdrawn asset is not the configured stable token, the router swaps back through Uniswap V4.
5. The router transfers stable tokens to the user.

### Cross-chain buy path

For an `instrumentId` that belongs to another chain, `buy()` does not deposit locally:

1. The router extracts the chain ID from the instrument ID.
2. It transfers stable tokens to the configured CCTP bridge adapter.
3. The bridge carries `instrumentId`, recipient, and minimum output constraints in hook data.
4. On the destination chain, `CCTPReceiver` can call `buyFor(...)` so the local router finishes the normal buy flow for the intended recipient.

Current code supports cross-chain buys, but not cross-chain sells.

## PortfolioHook and PortfolioVault details

The portfolio product turns a Uniswap V4 pool into a distribution interface for a managed lending portfolio.

### Pool model

- The pool is a `stable / vault-share` pair.
- The hook requires the pool to use zero fee and effectively zero AMM liquidity.
- The hook settles swaps with `beforeSwapReturnDelta`, so pricing comes from vault NAV rather than a liquidity curve.
- The vault share token is the `PortfolioVault` ERC20 itself.

### Buy flow through the hook

1. A trader submits a stable-to-share swap through any Uniswap V4-compatible frontend or router.
2. `PortfolioHook.beforeSwap()` identifies the trade as a buy.
3. The hook pulls stable tokens from PoolManager with `take()`.
4. The hook forwards stable to `PortfolioVault`.
5. `PortfolioVault.deployCapital()` splits capital by configured allocation weights.
6. For each allocation, the vault optionally swaps stable into the market currency, then deposits through the adapter.
7. The vault mints portfolio shares back to the hook.
8. The hook settles those shares to PoolManager and returns deltas that bypass normal AMM execution.

The result is that the trader receives portfolio shares while the vault immediately deploys capital into underlying lending markets.

### Sell flow through the hook

1. A trader submits a share-to-stable swap.
2. `PortfolioHook.beforeSwap()` identifies the trade as a sell.
3. The hook asks `PortfolioVault.withdrawCapital(stableNeeded)` for the exact stable amount required for settlement.
4. The vault withdraws proportionally from each lending position.
5. If any position's market currency differs from stable, the vault swaps back through Uniswap V4.
6. The vault sends stable to the hook.
7. The hook settles stable to PoolManager and marks the incoming shares for burn.
8. In `afterSwap()`, any dead shares left in PoolManager from sell settlement are burned so NAV accounting stays correct.

### Rebalancing and accounting

`PortfolioVault` also owns portfolio maintenance:

- `totalAssets()` computes NAV as undeployed stable plus the stable-denominated value of all lending positions.
- `_convertToStable()` prices non-stable holdings from the registered Uniswap pool spot price.
- `rebalance()` enters PoolManager context via `unlock()` because it runs outside swap execution.
- In `unlockCallback()`, the vault first exits over-allocated positions, then redeploys into under-allocated ones.

This makes the hook path work as an on-chain portfolio engine rather than a single-market router.

## Registries and adapters

Both products depend on registry indirection so the user-facing API stays compact.

### InstrumentRegistry

- Stores `instrumentId -> {adapter, marketId}`.
- Encodes chain identity into the instrument ID so the router can detect local versus remote instruments.
- Lets products stay protocol-agnostic while adapters carry protocol-specific logic.

### SwapPoolRegistry

- Stores directional `currencyIn -> currencyOut -> PoolKey` mappings.
- Must be configured in both directions for reversible flows.
- Decouples product logic from concrete Uniswap pool addresses and fee tiers.

### Adapters

Every lending protocol is wrapped behind `ILendingAdapter`, which keeps the product layer consistent across Aave, Morpho, Euler, Compound, and Fluid.

## Why the split matters

The architecture intentionally separates:

- user entrypoints (`SwapDepositRouter`, `PortfolioHook`),
- routing metadata (`InstrumentRegistry`, `SwapPoolRegistry`),
- swap execution (`SwapExecutor`), and
- lending execution (`LendingExecutor`, adapters).

That keeps single-instrument and portfolio products aligned at the execution layer while allowing very different user experiences on top.
