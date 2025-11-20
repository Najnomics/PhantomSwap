PhantomSwap – Private DEX Aggregator
Track: Private DeFi & Trading ($3,000)
Hackathon: Zypherpunk – Zcash Privacy Hackathon
Stack: Fhenix CoFHE · Zcash shielded pools · Uniswap V4 hooks · React/TypeScript

At a Glance
Mission: Let anyone trade across Ethereum liquidity privately, with Zcash-grade settlement guarantees and zero MEV leakage.
Thesis: Encrypt every price-sensitive field, run routing logic with CoFHE, and settle through shielded pools so bots cannot front-run or infer strategy.
MVP Scope: Uniswap V4 + Curve aggregation, Zcash bridge, reference frontend, full CoFheTest coverage.
Table of Contents
Problem
Personas & Use-Cases
Solution Overview
End-to-End User Flow
Component Topology
Data Lifecycle & Privacy Controls
Core Contracts
Developer Environment
Testing Strategy
Roadmap
Contribution & Governance
Problem
Public mempools broadcast price-sensitive intent:

$1.2B+ MEV extracted from Ethereum users in 2024; sandwich attacks capture 40–80 bps per trade.
70% of >$100k swaps observed by MEV searchers; whales flee to invite-only private relays.
No tools for smaller traders to access private orderflow; strategies leak instantly to quantitatively advantaged bots.
Pain points:

Actor	Risk Today	Business Impact
Professional desks	Strategy reverse-engineered from public mempools	Lost alpha, market share erosion
Retail aggregators	Cannot promise front-running protection	Customer churn to centralized exchanges
Zcash ecosystem	Lack of privacy-preserving settlement on EVM DEXes	Locked-out liquidity + limited integrations
Personas & Use-Cases
Stealth Desk: Runs delta-neutral strategies and needs encrypted order submission.
Privacy Wallet: Wants to route user swaps via API without exposing size.
Zcash Market Maker: Prefers shielded settlement to keep book confidential.
Institutional Custodian: Must demonstrate front-running protection for compliance.
Each persona maps to a specific feature flag (e.g., delegated execution, API key auth, post-trade settlement reports).

Solution Overview
PhantomSwap encrypts orders end-to-end:

Client Encryption: User signs and encrypts amountIn, minAmountOut, and slippage using Fhenix JS SDK.
CoFHE Routing: PhantomSwap.sol compares quotes from multiple sources with FHE operators; no plaintext leakage.
Execution Hooks: Selected route executes via Uniswap V4 hooks or other adapters; only required values decrypted at the millisecond of swap.
Zcash Settlement: Output funds bridged to Zcash shielded pool using ZcashBridge.sol, keeping balances opaque.
End-to-End User Flow
sequenceDiagram
    participant Trader
    participant PhantomUI as Phantom UI
    participant PhantomSwap as PhantomSwap.sol
    participant Liquidity as Liquidity Sources
    participant Zcash as Zcash Bridge/Node

    Trader->>PhantomUI: Configure swap (tokenIn/out, amount, slippage)
    PhantomUI->>PhantomUI: Encrypt parameters via Fhenix SDK
    PhantomUI->>PhantomSwap: submitOrder(ciphertext payload)
    PhantomSwap->>PhantomSwap: Store encrypted order & enqueue
    PhantomSwap->>Liquidity: Request encrypted quotes (hooks)
    Liquidity-->>PhantomSwap: Return encrypted quote responses
    PhantomSwap->>PhantomSwap: CoFHE compares quotes & selects best route
    PhantomSwap->>Liquidity: Execute swap (minimal decryption)
    Liquidity-->>PhantomSwap: Return execution receipts
    PhantomSwap->>Zcash: Bridge output to shielded pool
    Zcash-->>PhantomSwap: Shielded tx confirmation
    PhantomSwap-->>Trader: Emit OrderExecuted + settlement proof
Component Topology
flowchart LR
    subgraph Client Layer
        UI[PhantomSwap Frontend]
        SDK[Fhenix JS SDK]
        Signer[Wallet / MPC]
    end

    subgraph Execution Layer
        PS[PhantomSwap.sol]
        Hook[PhantomHook.sol]
        Bridge[ZcashBridge.sol]
    end

    subgraph Liquidity Mesh
        U4(Uniswap V4 Pool)
        Curve(Curve Pool)
        Balancer(Balancer V2 Vault)
        CEX(CEX Relay - optional)
    end

    subgraph Settlement Layer
        Lightwalletd(Zcash lightwalletd)
        ShieldedPool[Zcash Shielded Pool]
    end

    UI --> SDK --> PS
    PS --> Hook
    Hook --> U4
    Hook --> Curve
    Hook --> Balancer
    Hook --> CEX
    PS --> Bridge --> Lightwalletd --> ShieldedPool
    ShieldedPool --> Bridge
    PS --> UI
Data Lifecycle & Privacy Controls
Stage	Data Type	Encryption State	Notes
Client entry	amountIn, minOut, slippage	Encrypted (Fhenix SDK)	Never sent as plaintext
Order book	Ciphertext blobs	Stored encrypted	Indexed by hash; no balances exposed
Route selection	Quote comparisons	Homomorphic operations	FHE gt, select used across routes
Swap execution	amountIn	Decrypted momentarily	Happens inside hook call; re-encrypted post swap
Settlement proof	Zcash tx hash, note commitment	Public hash, private amounts	Hash stored on-chain, amounts hidden in shielded pool
Additional safeguards:

Time-based cloaking: Orders batched with randomized delays to minimize timing oracle hints.
Noise injection: Optional volume padding for VIP orderflow.
Audit hooks: Encrypted logs exported via CoFheTest for compliance teams.
Core Contracts
// Submit encrypted order
function submitOrder(
    address tokenIn,
    address tokenOut,
    inEuint256 calldata encryptedAmount,
    inEuint256 calldata encryptedMinOut,
    inEuint8 calldata encryptedSlippage,
    uint256 deadline
) external returns (bytes32 orderHash);

// Execute optimal route computed with CoFHE
function executeOrder(bytes32 orderHash) external;

// Internal bridge logic to settle into Zcash shielded pool
function _settleToZcash(
    bytes32 orderHash,
    euint256 encryptedOutput
) internal;
FHE execution steps:

submitOrder uses FHE.asEuint* helpers from CoFHE to persist ciphertexts.
_findOptimalRoute loops through registered liquidity adapters, comparing encrypted quotes (gt, select).
Control flow decrypts boolean guards only; numeric values stay encrypted.
_settleToZcash decrypts output amount once, triggers bridge transfer, and emits OrderSettled.
Developer Environment
# Install dependencies
node >= 20
npm install
npm install @fhevm/solidity fhenixjs ethers@6

# Foundry toolchain
foundryup
forge install
forge build
forge test

# Launch local anvil fork + UI
anvil --fork-url $FHENIX_RPC_URL --chain-id $FHENIX_CHAIN_ID &
npm run dev:stack
.env template:

FHENIX_RPC_URL=https://api.testnet.fhenix.zone:7747
FHENIX_CHAIN_ID=8008135
PHANTOMSWAP_ADDRESS=
PHANTOM_HOOK_ADDRESS=
ZCASH_BRIDGE_ADDRESS=
FHENIX_PRIVATE_KEY=
ZCASH_RPC_URL=
ZCASH_RPC_USER=
ZCASH_RPC_PASSWORD=
Testing Strategy
CoFheTest unit harness: Generates deterministic encrypted fixtures and validates order submission, FHE comparisons, and permissioned execution paths.
Integration stage: Foundry Anvil fork with Uniswap V4 sandbox, verifying gas, slippage, and DeFi adapter compatibility.
Settlement stage: Lightwalletd docker harness to simulate shielded transfers, including failure cases (timeouts, insufficient confirmations).
Performance profiling: Bench route selection with 3/5/10 sources to keep block execution under 4M gas.
Roadmap
Phase	Highlights
Hackathon MVP	Single-route aggregation, manual settlement trigger, proof-of-concept frontend
Q1 2026	Multi-venue support (Curve, Balancer), partner wallet SDK, streaming API
Q2 2026	Security audit, MEV insurance pool, delegated access control
Beyond	Mobile app, institutional dashboard, cross-chain settlement adapters
KPIs: average slippage reduction vs public swaps, time-to-settlement, VIP order volume.

Contribution & Governance
Fork and branch feature/<name>.
Implement feature with CoFheTest coverage (test/PhantomSwap.test.ts).
Submit PR including threat model updates + gas report.
Governance: roadmap proposals discussed in #phantom-gov Discord channel; on-chain votes verified via encrypted participation credentials.
Goal: Eliminate MEV exposure for Zcash-connected traders by encrypting every step from quote discovery to settlement.***
