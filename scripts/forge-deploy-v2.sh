#!/bin/bash
set -e
ROOT="/mnt/c/Users/soufj/Desktop/Programme Créer/arc-treasury-agent"
set -a; source "$ROOT/.env"; set +a
cd "$ROOT/contracts"
~/.foundry/bin/base-forge script script/DeployV2.s.sol \
  --rpc-url "$ARC_RPC" \
  --private-key "$AGENT_PRIVATE_KEY" \
  --broadcast
