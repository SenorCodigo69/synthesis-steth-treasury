# stETH Agent Treasury

Autonomous AI agent operating budget backed by Lido staked ETH. The agent can only spend accrued staking yield — principal is structurally inaccessible.

Built for the [EF Synthesis Hackathon](https://www.synthesis.build/) — **"Agents that pay"** track + **Lido stETH Agent Treasury** bounty.

## How It Works

```
Owner deposits ETH
       ↓
  Lido staking (ETH → stETH)
       ↓
  Wrap to wstETH (non-rebasing, clean accounting)
       ↓
  Yield accrues via Lido staking rewards (~3.5% APR)
       ↓
  Agent withdraws ONLY yield to whitelisted recipients
       ↓
  Principal remains untouched (enforced at contract level)
```

### Safety Rails

| Control | Description |
|---|---|
| **Principal protection** | Agent can never touch deposited principal — enforced by on-chain invariant check |
| **Recipient whitelist** | Agent can only send to owner-approved addresses |
| **Per-transaction cap** | Maximum stETH per withdrawal (configurable by owner) |
| **Cooldown timer** | Minimum time between agent withdrawals |
| **Owner exit** | Owner can withdraw everything (principal + remaining yield) at any time |

## Architecture

```
┌─────────────────────────────────────────────┐
│              AgentTreasury.sol               │
│                                             │
│  Owner ──deposit()──→ Lido ──→ wstETH       │
│                                             │
│  Agent ──agentWithdraw()──→ yield only      │
│         (whitelist + cap + cooldown)         │
│                                             │
│  Owner ──ownerWithdraw()──→ everything      │
│                                             │
│  Views: currentValueStETH(), availableYield()│
└─────────────────────────────────────────────┘
```

- **wstETH internally** — non-rebasing wrapper for clean accounting. No share math surprises.
- **Yield = currentValue - principal** — simple, auditable, no off-chain oracles needed.

## Deployed Contracts

| Network | Contract | Address |
|---|---|---|
| Ethereum Mainnet | AgentTreasury | *deploying...* |

## Quick Start

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Python 3.10+ (for `interact.py`)

### Build & Test

```bash
git clone https://github.com/SenorCodigo69/synthesis-steth-treasury.git
cd synthesis-steth-treasury
forge install
forge build
forge test -vvv
```

### Deploy

```bash
cp .env.example .env
# Edit .env with your PRIVATE_KEY and AGENT_ADDRESS

# Ethereum Mainnet
forge script script/Deploy.s.sol --rpc-url https://eth.llamarpc.com --broadcast --verify

# Holesky Testnet
forge script script/Deploy.s.sol --rpc-url https://ethereum-holesky-rpc.publicnode.com --broadcast
```

### Interact (Python)

```bash
pip install web3 python-dotenv
python interact.py status           # Full treasury status
python interact.py deposit 0.01     # Deposit 0.01 ETH
python interact.py yield            # Check available yield
python interact.py withdraw 0.001   # Agent withdraws yield
python interact.py exit             # Owner withdraws everything
```

## Bounty Requirements

### Lido: stETH Agent Treasury ($3K)

| Requirement | Status |
|---|---|
| Smart contract that holds stETH and earns yield | Done — AgentTreasury.sol |
| Agent can only access yield, not principal | Done — on-chain invariant |
| Spending permissions (whitelist, caps, cooldown) | Done |
| Owner can withdraw at any time | Done — ownerWithdraw() |
| Deployed on Ethereum | Done |
| Tests | Done — 27 Foundry tests |

### "Agents that pay" track

| Requirement | Status |
|---|---|
| Agent capability manifest | Done — agent.json |
| Autonomous decision-making | Done — yield-based spending |
| On-chain execution | Done — Ethereum mainnet |
| Safety rails | Done — whitelist, caps, cooldown, principal protection |

## Agent Capability Manifest

See [`agent.json`](agent.json) for the machine-readable capability declaration following the EF Synthesis schema.

## Security

- **No upgradability** — immutable contract, no proxy patterns
- **No external dependencies** — only Lido stETH/wstETH interfaces
- **No oracles** — yield calculated from on-chain wstETH exchange rate
- **Fail-safe** — if yield is 0, agent simply cannot withdraw
- **Principal invariant** — `assert(currentValueStETH() >= principalStETH)` checked after every agent withdrawal

## License

MIT
