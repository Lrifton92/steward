#!/bin/bash
# Envoie 20 USDC (ERC-20) du burner vers le vault (testnet)
set -e
ROOT="/mnt/c/Users/soufj/Desktop/Programme Créer/arc-treasury-agent"
set -a; source "$ROOT/.env"; set +a
~/.foundry/bin/base-cast send "$USDC" "transfer(address,uint256)" "$VAULT_ADDRESS" 20000000 \
  --rpc-url "$ARC_RPC" --private-key "$AGENT_PRIVATE_KEY"
~/.foundry/bin/base-cast call "$USDC" "balanceOf(address)(uint256)" "$VAULT_ADDRESS" --rpc-url "$ARC_RPC"
