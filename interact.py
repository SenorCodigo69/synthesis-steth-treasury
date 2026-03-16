#!/usr/bin/env python3
"""
Interact with a deployed AgentTreasury contract.

Usage:
    python interact.py deploy          # Deploy to Holesky
    python interact.py deposit 0.1     # Deposit 0.1 ETH
    python interact.py yield           # Check available yield
    python interact.py withdraw 0.001  # Agent withdraws yield
    python interact.py status          # Full treasury status
    python interact.py exit            # Owner withdraws everything
"""

import json
import os
import sys
from pathlib import Path

from dotenv import load_dotenv
from web3 import Web3

load_dotenv()

# --- Config ---
HOLESKY_RPC = os.getenv("RPC_URL", "https://ethereum-holesky-rpc.publicnode.com")
PRIVATE_KEY = os.getenv("PRIVATE_KEY", "")
TREASURY_ADDRESS = os.getenv("TREASURY_ADDRESS", "")

# Holesky addresses
STETH_HOLESKY = "0x3F1c547b21f65e10480dE3ad8E19fAAC46C95034"
WSTETH_HOLESKY = "0x8d09a4502Cc8Cf1547aD300E066060D043f6982D"

# Load ABI from Foundry output
ABI_PATH = Path(__file__).parent / "out" / "AgentTreasury.sol" / "AgentTreasury.json"


def get_web3():
    w3 = Web3(Web3.HTTPProvider(HOLESKY_RPC))
    if not w3.is_connected():
        print("ERROR: Cannot connect to RPC")
        sys.exit(1)
    return w3


def get_account(w3):
    if not PRIVATE_KEY:
        print("ERROR: Set PRIVATE_KEY in .env")
        sys.exit(1)
    return w3.eth.account.from_key(PRIVATE_KEY)


def get_treasury(w3):
    if not TREASURY_ADDRESS:
        print("ERROR: Set TREASURY_ADDRESS in .env")
        sys.exit(1)
    with open(ABI_PATH) as f:
        artifact = json.load(f)
    return w3.eth.contract(
        address=Web3.to_checksum_address(TREASURY_ADDRESS),
        abi=artifact["abi"],
    )


def send_tx(w3, account, tx_func, value=0):
    """Build, sign, send a transaction."""
    tx = tx_func.build_transaction({
        "from": account.address,
        "value": value,
        "nonce": w3.eth.get_transaction_count(account.address),
        "gas": 500_000,
        "gasPrice": w3.eth.gas_price,
        "chainId": w3.eth.chain_id,
    })
    signed = account.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    print(f"  tx: {tx_hash.hex()}")
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
    print(f"  status: {'SUCCESS' if receipt['status'] == 1 else 'FAILED'}")
    return receipt


def cmd_status():
    w3 = get_web3()
    treasury = get_treasury(w3)

    principal = treasury.functions.principalStETH().call()
    current = treasury.functions.currentValueStETH().call()
    available = treasury.functions.availableYield().call()
    withdrawn = treasury.functions.totalYieldWithdrawn().call()
    agent = treasury.functions.agent().call()
    owner = treasury.functions.owner().call()
    cap = treasury.functions.perTxCap().call()
    window = treasury.functions.timeWindow().call()
    wst_bal = treasury.functions.wstETHBalance().call()

    print("\n=== AgentTreasury Status ===")
    print(f"  Contract:     {TREASURY_ADDRESS}")
    print(f"  Owner:        {owner}")
    print(f"  Agent:        {agent}")
    print(f"  Principal:    {Web3.from_wei(principal, 'ether')} stETH")
    print(f"  Current val:  {Web3.from_wei(current, 'ether')} stETH")
    print(f"  Yield avail:  {Web3.from_wei(available, 'ether')} stETH")
    print(f"  Yield spent:  {Web3.from_wei(withdrawn, 'ether')} stETH")
    print(f"  wstETH held:  {Web3.from_wei(wst_bal, 'ether')}")
    print(f"  Per-tx cap:   {Web3.from_wei(cap, 'ether')} stETH")
    print(f"  Cooldown:     {window}s ({window // 3600}h)")


def cmd_deposit(amount_eth):
    w3 = get_web3()
    account = get_account(w3)
    treasury = get_treasury(w3)
    value = Web3.to_wei(amount_eth, "ether")

    print(f"\nDepositing {amount_eth} ETH into treasury...")
    send_tx(w3, account, treasury.functions.deposit(), value=value)
    print("Done!")


def cmd_yield():
    w3 = get_web3()
    treasury = get_treasury(w3)
    available = treasury.functions.availableYield().call()
    print(f"\nAvailable yield: {Web3.from_wei(available, 'ether')} stETH")


def cmd_withdraw(amount_eth):
    w3 = get_web3()
    account = get_account(w3)
    treasury = get_treasury(w3)
    amount = Web3.to_wei(amount_eth, "ether")

    print(f"\nAgent withdrawing {amount_eth} stETH yield...")
    send_tx(w3, account, treasury.functions.agentWithdraw(account.address, amount))
    print("Done!")


def cmd_exit():
    w3 = get_web3()
    account = get_account(w3)
    treasury = get_treasury(w3)

    print("\nOwner withdrawing all funds...")
    send_tx(w3, account, treasury.functions.ownerWithdraw())
    print("Done!")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(0)

    cmd = sys.argv[1]

    if cmd == "status":
        cmd_status()
    elif cmd == "deposit":
        if len(sys.argv) < 3:
            print("Usage: python interact.py deposit <amount_eth>")
            sys.exit(1)
        cmd_deposit(float(sys.argv[2]))
    elif cmd == "yield":
        cmd_yield()
    elif cmd == "withdraw":
        if len(sys.argv) < 3:
            print("Usage: python interact.py withdraw <amount_steth>")
            sys.exit(1)
        cmd_withdraw(float(sys.argv[2]))
    elif cmd == "exit":
        cmd_exit()
    else:
        print(f"Unknown command: {cmd}")
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    main()
