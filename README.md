# Sovereign Flash-Loan RWA Arbitrage Engine

A two-chain execution implementation for Base (8453) and Arbitrum One (42161), with Aave V3 atomic loans, curated Uniswap V3/Camelot Algebra V1 routes, Chainlink-compatible NAV feeds, Supabase audit storage, and bounded online risk adaptation.

**Status:** local tests only; no mainnet deployment, live-provider integration, independent security audit, or profitability evidence. This repository cannot guarantee production safety or profitable trades. Flash loans supply trade principal; the signer still needs native gas, including for reverted transactions. NAV discounts do not establish redeemability, executable liquidity, or transfer permission for restricted RWA securities.

## Development

Requires Linux x86-64, Python 3.12+, uv, Node/npm, and HTTPS access to package registries and raw.githubusercontent.com. Each cloud task already has an isolated checkout: use it directly without creating another worktree.

```sh
uv sync --frozen
npm ci
uv run python tools/prepare_solc.py
uv run ruff check oracle tests
uv run ruff format --check oracle tests
uv run mypy oracle
uv run pytest -q
node_modules/.bin/forge fmt --check
node_modules/.bin/forge build --use .tools/solc-0.8.24 --sizes
node_modules/.bin/forge test --use .tools/solc-0.8.24 -vv
```

The compiler downloader verifies the release manifest SHA-256 and keeps TLS verification enabled. Standard Foundry installations can use `forge test` directly. No Rust service is needed for the requested Python/Solidity modules.

Apply `migrations/001_engine.sql` once with a Supabase database administrator using the SQL editor or a trusted PostgreSQL client. It uses the existing `anon`, `authenticated`, and `service_role` roles. RLS denies public application access. Only the backend receives the service-role key. `tests/learning.sql` checks learning samples, failure flags, and rolling-window behavior inside a rolled-back transaction. Indexes deliberately trade write throughput for the requested latency/slippage lookups; benchmark and set retention before high-volume operation.

## Runtime configuration

`ENGINE_CONFIG` is the path to a JSON document validated against [oracle/config.schema.json](oracle/config.schema.json). This schema is the complete field contract, rather than an example with invented token addresses. Supply exactly two chain objects with distinct chain IDs and nonempty routes. Verify every address against the relevant protocol's official deployment registry and on-chain bytecode. The engine checks chain ID, router bytecode, signer authority, pool identity, and token decimals at startup.

Each chain needs deployed `router`, Aave V3 `pool`, `native_usd_feed`, wei-denominated `tip_wei`, `max_tip_wei`, `max_fee_wei`, `max_tx_cost_wei`, and a positive `l1_fee_reserve_wei`. Wei amounts are integer strings. Set `max_premium_bps` to the owner-approved ceiling and `subscribe_pending` to false unless the private node explicitly supports that subscription. `confirmations` is the number of additional blocks required before auditing a receipt. This is a confirmation policy, not rollup L1 finality.

Each route needs a unique `id`, loan `asset`, raw-unit `amount`, integer `min_margin_bps`, `slippage_bps`, `min_nav_discount_bps`, `loan_decimals`, `rwa_decimals`, and `feed_max_age` seconds. `loan_usd_feed` and `rwa_nav_feed` must both return USD per whole token with Chainlink AggregatorV3-compatible rounds and timestamps. Choose staleness appropriate to each institutional NAV publication schedule. No NAV API or token-address discovery is guessed.

`legs` contains exactly two connected swaps from loan asset to RWA and back. Each leg specifies `router`, `quoter`, `token_in`, `token_out`, `fee`, and `kind`. Kind 1 supports the original Uniswap V3 SwapRouter and Quoter V1 signatures; kind 2 supports Camelot Algebra V1 router and quoter signatures (fee is unused). SwapRouter02, QuoterV2, Algebra Integral, fee-on-transfer and rebasing assets require separate reviewed adapters and are unsupported. Verify transfer allowlists and pool liquidity before adding an RWA token.

The router supports up to four legs, while the NAV-based oracle deliberately evaluates only two-leg round trips. All configured routers and tokens must be owner-allowlisted. `maxLoan` is in raw token units; curating multiple loan assets requires choosing a safe common raw-unit ceiling.

Set these securely in the execution environment, never in tracked files:

| Variable | Meaning |
| --- | --- |
| `SUPABASE_URL` | HTTPS project URL |
| `SUPABASE_KEY` | Backend service-role credential |
| `PRIVATE_RPC_ENDPOINTS` | JSON object mapping `8453` and `42161` to private WSS URLs |
| `EXECUTION_WALLET_KEY` | Raw locally available signing key; cannot be a proxy-injected placeholder |
| `ENGINE_CONFIG` | Absolute configuration file path |
| `ENGINE_JOURNAL_DIR` | Persistent directory outside checkout for pending-transaction intent records |
| `LIVE_TRADING` | `true` permits broadcasts; all other values simulate |

```sh
uv run python -m oracle.engine
```

Both chain streams run concurrently with asyncio; signing runs in a worker thread. Pending notifications are optional because rollup sequencers do not guarantee a public mempool. The websocket adapter uses the proxy-aware websockets 15 transport and inherited TLS trust. Events coalesce into a bounded queue during receipt waits, avoiding an unbounded pending-event backlog. Each evaluation queries Supabase learning state. A database/RPC outage halts execution instead of silently using stale risk state. No opaque model automatically changes contract ownership, allowlists, loan caps, or deploys new code.

The SQL trigger serializes route-level updates and tracks exponentially weighted failure, slippage, and latency estimates. Three failed mined transactions in 60 seconds block a route for 60 seconds. The bounded policy raises required margins and adjusts tips without expanding slippage or fee caps. This is online statistical adaptation, not a trained reinforcement-learning policy or evidence of convergence. Reverted EVM calls roll back all state, including counters. The contract can persist counters only for successful calls or non-reverting parameter rejections; mined failures are tracked off-chain.

Profit checks preserve the router's existing loan-token balance and require principal, actual premium, and the encoded minimum profit. Per-hop approvals are exact and cleared. Only the allowlisted router receives approvals, and callback origin, initiator, state and payload commitment are checked. Gas estimates include a configured conservative L1 reserve, not an exact fee oracle; calibrate the reserve for each rollup. Outputs go to the immutable beneficiary, so gas-wallet replenishment needs a separate treasury policy.

## Deployment and operation

`.github/workflows/deploy_engine.yml` runs Python, Foundry and PostgreSQL checks on pushes and pull requests. Manual `deploy` runs both chains through the `production` GitHub environment; protect that environment and restrict allowed deployment branches. Manual `monitor` executes on a dedicated self-hosted runner labelled `sovereign-engine`, using secure repository/environment secrets. GitHub-hosted jobs are not a continuous service: this monitor session ends after six hours. For persistent operation, run the same command under your process supervisor on that runner. Use a single active monitor per execution key; do not share the key with unrelated nonce writers.

For deployment, supply `DEPLOYER_KEY` and `DEPLOY_RPC_ENDPOINTS` secrets. The latter maps `base` and `arbitrum` to HTTPS RPC endpoints. `DEPLOYMENT_CONFIG` is a nonsecret repository/environment variable mapping those chain names to objects containing `AAVE_POOL`, `EXECUTOR_ADDRESS`, `BENEFICIARY_ADDRESS`, `MAX_LOAN`, `MAX_PREMIUM_BPS`, and `policy`. Policy has address arrays `tokens`, `uniswap_v3_routers`, `camelot_v1_routers`. `Deploy.s.sol` deploys and allowlists in broadcast transactions; inspect receipts for partial failures before retrying. Deployment owner is the deployer; use the two-step ownership transfer to move it to an operational multisig.

Inspect deployment artifacts and configure `ENGINE_CONFIG_JSON` with the resulting router addresses for the monitor job. Set the nonsecret `ENGINE_JOURNAL_DIR` variable to an absolute persistent runner directory. Configure the four runtime secrets named above, and apply the migration before monitoring. The workflow does not automatically mutate a Supabase production schema or select assets, feeds, or routing policies on your behalf.

A journal record is fsynced before submission and removed only after confirmed receipt auditing. A send error, receipt timeout, reorg, or audit failure stops the process and retains the journal. Before restarting, query that transaction hash, reconcile final status and actual execution metrics in Supabase, ensure there is no unknown pending nonce, then archive/remove that one reconciled journal file. Never delete journals to bypass an unexplained pending transaction. Retain a durable audit backup. There is no automatic transaction replacement policy.

Before live use, run fork tests against the exact selected pools, assets, feeds and adapters, test transaction submission and failure recovery with the chosen private provider, calibrate L1 gas reserves, validate Supabase permissions and availability, and obtain an independent contract audit. Local mocks do not verify mainnet protocol availability or institutional-token transfer rules.
