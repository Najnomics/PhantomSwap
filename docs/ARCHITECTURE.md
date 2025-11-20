## PhantomSwap Architecture Overview

PhantomSwap integrates homomorphic order handling, Uniswap v4 hook-based execution, and Zcash shielded settlement. The design follows requirements captured in `README.md` and guidance from:

- Fhenix FHEVM developer docs (`https://docs.fhenix.io/docs/`)
- CoFHE testing reference (`https://docs.fhenix.io/docs/cofhe/testing`)
- Zcash developer documentation (`https://zcash.readthedocs.io/en/latest/`, `https://zcash.github.io/rpc/`)
- Uniswap v4 hook template (`https://github.com/uniswapfoundation/v4-template`)

### Module Breakdown

1. `PhantomSwap.sol`
   - Owns encrypted order lifecycle (`submitOrder`, `executeOrder`, `cancelOrder`).
   - Stores ciphertext using Fhenix `inEuint*` types and `FHE.asEuint*` helpers.
   - Coordinates route evaluation via registered adapters.
   - Enforces permission pattern: only delegated executors (configured by admin) may call `executeOrder`.
   - Emits encrypted audit logs compatible with CoFheTest fixtures.

2. `hooks/PhantomHook.sol`
   - Extends Uniswap v4 Hook base.
   - Implements `beforeSwap` / `afterSwap` hooks to decrypt minimal data at execution time and reroute flows.
   - Guards entry by verifying `msg.sender` is `PhantomSwap`.
   - Streams execution receipts back to core for Zcash settlement.

3. `adapters/`
   - Interface and implementations for alternative liquidity sources (e.g., Curve, Balancer).
   - Each adapter returns encrypted quotes compatible with CoFHE comparison ops.

4. `bridge/ZcashBridge.sol`
   - Wraps commitment validation and note submission to a Zcash relayer.
   - Maintains retry queue/state for shielded transactions.
   - Uses events mirroring Zcash RPC responses (`z_sendmany`, `z_getoperationstatus`).

5. `libraries/FheOrderLib.sol`
   - Struct definitions and helpers for encrypted fields (`EncryptedOrder`, `EncryptedQuote`).
   - Abstractions for CoFHE compare/select operators to keep usage consistent.

6. `fhe/CoFheExecutors.sol`
   - Helper contracts to perform batched encrypted comparisons with gas-efficient patterns.

7. `test/`
   - CoFHE fixtures using `CoFheTest` harness.
   - Integration tests for hook execution using template's `BaseTest`.
   - Bridge simulation tests against mock Zcash relayer.

### Data Flow

1. User encrypts parameters (`amountIn`, `minAmountOut`, `slippageBps`) client-side via Fhenix JS SDK.
2. Encrypted payload submitted to `PhantomSwap.sol` alongside cleartext routing intent (tokens, deadlines).
3. Core contract queries adapters/hook pre-swap routine to gather encrypted quotes.
4. CoFHE module compares ciphertext values using `FHE.lessThan`/`FHE.select` patterns (per docs).
5. Winning route executed through `PhantomHook` which momentarily decrypts input for pool interaction.
6. Post-swap, output amount re-encrypted and passed to `ZcashBridge` for shielded transfer.
7. Bridge emits operation IDs; off-chain relayer finalizes `z_sendmany` and reports status back on-chain.

### Security & Permissions

- Admin-controlled registries for executors, adapters, and relayers.
- Nonces + deadlines to prevent replay.
- Reentrancy protection on swap execution and settlement paths.
- Extensive CoFHE tests to ensure encrypted invariants, as recommended in Fhenix docs.
- Zcash bridge includes failover states and requires multiple confirmations before marking complete.

### Next Steps

1. Define storage layouts and interfaces (`IPhantomAdapter`, `IZcashRelayer`).
2. Replace template `Counter` contract with `PhantomSwap`.
3. Implement hook contract and register with Foundry scripts.
4. Build mock relayer and CoFHE fixtures in tests.
5. Iterate with integration tests (`forge test`) and eventual deployment scripts (`script/*.s.sol`).
# PhantomSwap Architecture & Integration Plan

## 1. Goals & References

- Deliver a privacy-preserving DEX aggregator that matches the product scope defined in `README.md`.
- Conform to Fhenix CoFHE smart-contract guidance, especially encrypted type handling, permissioning, and CoFheTest workflows.[^fhenix-docs]
- Integrate with Zcash shielded pools using the canonical node RPC interface and lightwalletd bridge patterns.[^zcash-rpc][^zcash-bridge]

[^fhenix-docs]: Fhenix FHEVM Developer Docs – “Encrypted Types & Permissions” and “Testing with CoFheTest”, https://docs.fhenix.io/developers/fhevm/
[^zcash-rpc]: Zcash Developer Documentation – RPC Interface, https://zcash.readthedocs.io/en/latest/rpc/
[^zcash-bridge]: Zcash Lightwalletd Integration Guide, https://zcash.readthedocs.io/en/latest/lightwalletd/

---

## 2. Contract Topology

| Module | Responsibility | Key Interfaces |
|--------|----------------|----------------|
| `PhantomSwap` (`src/core/PhantomSwap.sol`) | Stores encrypted orders, orchestrates route selection, enforces permissions, coordinates settlement | `submitOrder`, `executeOrder`, `registerAdapter` |
| `FheOrderBook` (`src/fhe/FheOrderBook.sol`) | Library for ciphertext storage, nonce management, and replay protection | `storeOrder`, `getOrder` |
| `RouteSelector` (`src/fhe/RouteSelector.sol`) | Performs CoFHE comparisons across adapter quotes (`inEuint256` comparisons via `FHE.gt`, `FHE.select`) | `chooseBestQuote` |
| `IPhantomAdapter` (`src/interfaces/IPhantomAdapter.sol`) | Common interface for liquidity sources (Uniswap V4 hook adapter, Curve, etc.) | `quoteEncrypted`, `executeEncrypted` |
| `PhantomHook` (`src/hooks/PhantomHook.sol`) | Uniswap v4 hook implementation built atop template’s `BaseHook`; handles encrypted swap metadata, decryption at execution boundary | Overrides `beforeSwap`, `afterSwap` |
| `ZcashBridge` (`src/bridge/ZcashBridge.sol`) | Encodes Zcash shielded transactions, drives RPC relay, verifies commitments | `requestShieldedTransfer`, `ackSettlement` |
| `AccessController` (`src/libraries/AccessController.sol`) | Permission gates for executors and adapter registration following Fhenix “permission patterns” | `requireExecutor`, `requireAdapterAdmin` |

All contracts target Solidity `0.8.30` per template configuration and rely on remappings in `remappings.txt`.

---

## 3. Data Lifecycle

1. **Order Submission**  
   - Client encrypts `amountIn`, `minAmountOut`, `slippageBps` with Fhenix SDK (`fhevm-js`).  
   - `PhantomSwap.submitOrder` accepts `inEuint256`/`inEuint8` values, validates deadlines, persists ciphertext via `FheOrderBook.storeOrder`, and assigns `orderHash`.
   - Emits `OrderSubmitted` with executor-usable metadata (token addresses, `orderHash`).

2. **Quote Collection**  
   - Executors call `PhantomSwap.collectQuotes(orderHash)` (view) which iterates registered adapters.  
   - Each adapter returns encrypted quote using Fhenix `euint256` structures; selection occurs under CoFHE without decrypting absolute values.

3. **Route Selection & Execution**  
   - `RouteSelector.chooseBestQuote` leverages `FHE.gt`/`FHE.select` to pick best output while keeping values encrypted.  
   - Winning adapter receives `executeEncrypted` call; Uniswap route handled by `PhantomHook` (attached to pool at init).  
   - Hook decrypts only the minimum necessary values inside `beforeSwap` using executor-provided access keys, respecting Fhenix decrypt-permission models.

4. **Settlement to Zcash**  
   - Post execution, `PhantomSwap` forms encrypted output `euint256`.  
   - `_settleToZcash` in `ZcashBridge` decrypts once under executor signature, constructs Zcash raw transaction (using `z_sendmany` / `z_sendmanywithnote`).  
   - Lightwalletd relay broadcasts, returning txid; commitments stored to ensure replay protection.

5. **Post-Trade Reporting**  
   - `OrderSettled` event includes `orderHash`, Zcash txid (plaintext), and encrypted audit blob (for compliance teams).  
   - Optional CoFHE export leverages CoFheTest logging helpers.

---

## 4. Permission & Security Model

- **Role Separation**  
  - `ORDER_SUBMITTER_ROLE`: default open, but can be restricted for institutional deployments.  
  - `EXECUTOR_ROLE`: required for `executeOrder`; aligned with Fhenix “executor permissions” concept where decrypt rights reside with whitelisted operators.  
  - `ADAPTER_ADMIN_ROLE`: manages adapters & hook parameters.

- **Decrypt Control**  
  - All decrypt operations flow through `IFHEKeyStore` (external Fhenix primitive). Contracts request temporary tokens; no raw plaintext stored on-chain.  
  - Hook uses `FHE.authDecrypt` to open values only during swap, re-encrypts outputs immediately.

- **Zcash Settlement Integrity**  
  - Verify viewing key presence before initiating transfer (requires integration with `z_importviewingkey`).  
  - Monitor Zcash confirmations via `gettransaction` RPC; settlement considered final after `>= 10` confirmations per docs recommendation.

- **Replay & MEV Mitigation**  
  - Orders include nonce tied to submitter + hashed ciphertext.  
  - Routing delays / jitter handled off-chain; on-chain we enforce deadlines and completion windows.

---

## 5. External Integrations

| Component | Integration Notes |
|-----------|-------------------|
| **Fhenix CoFHE** | Import `@fhevm/lib/CoFHE.sol` (to be added) for encrypted types, arithmetic, and permissioned decrypts. Follow doc guidance for `inEuint` calldata, `euint` storage, and `FHE.asEuint*` conversions. |
| **Uniswap v4** | Use template `PoolManager`, `Hooks` interfaces, `BaseHook`. Hook must declare flags consistent with `beforeSwap`/`afterSwap` usage; register at pool creation. |
| **Zcash** | Interact with lightwalletd or `zcashd` RPC: `z_getbalance`, `z_sendmany`, `z_getoperationstatus`. Manage async operations by polling per doc recommendations. |
| **Hookmate Utilities** | Reuse deployment helpers for environment setup (permit2, router, position manager). Extend as needed for encrypted order parameters. |

---

## 6. Testing & Tooling

- **Unit Tests (Foundry + CoFheTest)**  
  - Mirror template `test/utils/BaseTest.sol`.  
  - Introduce `test/phantom/PhantomSwap.t.sol` using `CoFheTest` harness for deterministic ciphertext fixtures.  
  - Validate: order submission, quote selection with multiple adapters, hook swap execution, Zcash settlement lifecycles (mock RPC).

- **Integration Tests**  
  - Deploy real v4 pool via scripts; run encrypted swap scenarios using hook.  
  - Simulate Zcash RPC using local `zcashd --testnet` container or mocked interface.

- **Static Analysis & Gas**  
  - Run `forge fmt`, `forge test`, `slither` (when available) per template pipeline.  
  - Track gas for submission & execution to ensure < 4M gas per README requirement.

---

## 7. Delivery Milestones

1. **Core Scaffolding** – Define interfaces, libraries, and migrate counter contract to PhantomSwap skeleton.  
2. **FHE Order Flow** – Implement encrypted storage, route selector, adapters with unit tests.  
3. **Hook Integration** – Flesh out `PhantomHook`, pool deployment scripts, and cross-contract wiring.  
4. **Zcash Bridge** – Implement settlement adapter with mock RPC client + integration tests.  
5. **Hardening** – Access control reviews, slither, fuzzing, finalize documentation.

Each milestone will reference the relevant sections of Fhenix and Zcash docs to validate compliance before moving forward.

