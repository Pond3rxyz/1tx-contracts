# SwapDepositor - Technical Reference for Claude

## Core Concept

Uniswap V4 hook that enables deposits/withdrawals to lending protocols (Aave, Morpho, etc.) with **automatic token swapping**. User sends USDC, gets aUSDT (with internal USDC→USDT swap).

## Critical Architecture: Dual Pool Design

**THIS IS THE KEY INSIGHT:**

```
1. Hook Pool (USDC/INSTRUMENT) - ZERO liquidity
   - User interacts with this pool
   - Has SwapDepositor hook attached
   - Currency0: USDC, Currency1: InstrumentToken (deployed dynamically)
   - NO LIQUIDITY - pure routing

2. Swap Pool (USDC/USDT) - WITH liquidity
   - Standard Uniswap V4 pool
   - NO HOOK attached
   - Used internally by hook for swaps
   - Has 5,000 USDC + 5,000 USDT liquidity
```

**Why?**
- Hook pool = routing layer (zero liquidity, no IL risk)
- Swap pool = liquidity layer (reuses existing DEX liquidity)
- User only touches USDC, swaps are invisible

## Flow Overview

### Deposit: USDC → aUSDT

```
User → Hook Pool (USDC/Dummy) with zeroForOne=true
  ↓
Hook.beforeSwap() intercepts
  ↓
_handleDepositSwap():
  1. mint/burn ERC-6909 claims (AsyncSwap)
  2. take() USDC from PoolManager
  3. Auto-detect: USDC ≠ USDT (market currency)
  4. Internal swap: poolManager.swap(usdcUsdtPool)
  5. Deposit USDT to Aave
  6. User receives aUSDT
  7. Return (+amount, 0) delta - skip AMM
```

### Withdraw: aUSDT → USDC

```
User → Hook Pool with zeroForOne=false
  ↓
Hook.beforeSwap() intercepts
  ↓
_handleWithdrawSwap():
  1. Pull aUSDT from user
  2. Withdraw USDT from Aave
  3. Auto-detect: USDT ≠ USDC (output currency)
  4. Internal swap: poolManager.swap(usdtUsdcPool)
  5. settle() USDC to PoolManager
  6. Return (0, -amount) delta - user gets USDC
```

## Key Components

### 1. SwapDepositor Hook
- `beforeSwap()`: Intercepts all swaps with `BeforeSwapReturnDelta`
- Auto-detects if swap needed: `inputCurrency != marketCurrency`
- Executes internal swaps via `poolManager.swap()`
- Uses AsyncSwap pattern (mint/burn ERC-6909 claims)

### 2. SwapPoolRegistry
```solidity
mapping(bytes32 pairHash => PoolKey) public defaultSwapPools;

// MUST register bidirectionally!
registerDefaultSwapPool(USDC, USDT, pool);
registerDefaultSwapPool(USDT, USDC, pool);
```

### 3. InstrumentRegistry
```solidity
// NEW: Extractable chainId for cross-chain routing
// ID Structure: [chainId: 32 bits][hash(protocol, marketId): 224 bits]
instrumentId = (chainId << 224) | (keccak256(protocol, marketId) >> 32)

mapping(bytes32 => InstrumentInfo) instruments;

// Extract chainId for routing (no storage lookup needed!)
uint32 chainId = uint32(uint256(instrumentId) >> 224);
```

### 4. Adapters (e.g., AaveAdapter)
```solidity
marketId = keccak256(abi.encode(currency))
deposit(marketId, amount, recipient)
withdraw(marketId, amount, to)
```

## HookData Encoding

```solidity
bytes memory hookData = abi.encode(
    bytes32 instrumentId,       // Which lending market (includes extractable chainId)
    address recipient,          // Who receives yield tokens
    uint256 yieldTokenAmount,   // For withdraw: amount to burn (0 for deposit)
    address user,               // For withdraw: owner of yield tokens
    PoolKey customPool          // Custom swap pool (fee=0 uses default)
);
```

## Critical Implementation Details

### Swap Direction Logic

**IMPORTANT: Do NOT invert this logic!**

```solidity
if (params.zeroForOne) {
    // DEPOSIT: User sends currency0 (USDC)
    _handleDepositSwap(...)
} else {
    // WITHDRAW: User sends yield tokens, gets currency0 back
    _handleWithdrawSwap(...)
}
```

Currency ordering: `USDC (0xba50...) < Dummy (0xFFfF...)` so currency0 = USDC

### Currency Ordering

Uniswap V4 requires: `currency0 < currency1` (by address)

```solidity
// Always ensure proper ordering
if (Currency.unwrap(currency0) > Currency.unwrap(currency1)) {
    (currency0, currency1) = (currency1, currency0);
}
```

### Internal Swap Execution

```solidity
function _executeSwap(
    PoolKey memory swapPool,
    Currency inputCurrency,
    Currency outputCurrency,
    int256 amountSpecified,
    uint160 sqrtPriceLimitX96
) internal returns (uint256 amountOut) {
    // Determine direction based on pool's currency order
    bool zeroForOne = Currency.unwrap(swapPool.currency0) == Currency.unwrap(inputCurrency);

    // Use pool-specific price limits (NOT outer swap limits!)
    uint160 internalPriceLimit = zeroForOne
        ? TickMath.MIN_SQRT_PRICE + 1
        : TickMath.MAX_SQRT_PRICE - 1;

    // Execute swap
    BalanceDelta delta = poolManager.swap(swapPool, SwapParams(...), "");

    // settle() input, take() output
    _settle(inputCurrency, address(this), inputAmount);
    _take(outputCurrency, address(this), amountOut);
}
```

## Permit2 & Liquidity (IMPORTANT!)

**Direct ERC20 approvals to PositionManager DON'T WORK in Uniswap V4!**

```solidity
// Step 1: Approve Permit2
IERC20(token).approve(PERMIT2, type(uint256).max);

// Step 2: Permit2 approves PositionManager
IPermit2(PERMIT2).approve(token, POSITION_MANAGER, type(uint160).max, expiration);

// Step 3: Add liquidity using modifyLiquidities()
bytes memory actions = abi.encodePacked(
    uint8(Actions.MINT_POSITION),
    uint8(Actions.SETTLE_PAIR)
);
positionManager.modifyLiquidities(abi.encode(actions, params), deadline);
```

## Pool Configuration

```solidity
// Hook Pool (ZERO liquidity)
PoolKey({
    currency0: USDC,
    currency1: INSTRUMENT (deployed dynamically),
    fee: 500,
    tickSpacing: 60,
    hooks: IHooks(HOOK)
});

// Swap Pool (WITH liquidity: 50k USDC + 50k USDT)
// IMPORTANT: Higher liquidity = lower slippage!
// 5k liquidity: 1k swap = 16.67% slippage
// 50k liquidity: 1k swap = 1.96% slippage
PoolKey({
    currency0: USDT,  // Note: USDT < USDC by address
    currency1: USDC,
    fee: 500,
    tickSpacing: 10,
    hooks: IHooks(address(0))
});
```

## Architecture Diagram

```
User (USDC only)
    ↓
Hook Pool (USDC/Dummy, ZERO liquidity) → beforeSwap() intercepts
    ↓
SwapDepositor Hook
    ├─ Auto-detect: needs swap?
    ├─ YES → Internal swap on Swap Pool (USDC/USDT with liquidity)
    ├─ Deposit/withdraw from Aave
    └─ Return delta (skip AMM)
```
