# Steward — Autonomous Treasury Agent on Arc

> Encode × Arc "Programmable Money" Hackathon 2026 — Agentic Economy Track.

Steward is an autonomous treasury agent for multi-currency stablecoin treasuries on [Arc](https://arc.network).
A **policy vault** deployed on Arc holds USDC/EURC and encodes hard rules — token, payee and
target allowlists, per-token daily caps. A **24/7 agent** monitors balances and FX conditions,
executes USDC↔EURC conversions through StableFX when policy and market conditions align, and
runs scheduled outbound payments. A **dashboard** shows every agent decision with its reasoning.

**The point: agents shouldn't just hold keys — they should operate inside on-chain guardrails
their owner defines.** The agent's key can only act through the vault; the owner can always
withdraw everything, no policy checks.

## Architecture

- `contracts/` — Foundry project. `PolicyVault.sol`: roles (owner/agent), allowlists
  (tokens, payees, approval targets), per-token daily caps with lazy day-window reset,
  owner escape hatch. 14 tests.
- `agent/` — Node/viem agent loop. v0: observes vault balances, computes deviation from the
  target currency ratio, journals every decision (`journal.jsonl`) in dry-run mode.
- `scripts/` — WSL helpers for base-forge (init/test/deploy).

## Arc testnet

Chain `5042002` · RPC `https://rpc.testnet.arc.network` · gas = USDC.
USDC `0x3600…0000` · EURC `0x89B5…D72a` · StableFX FxEscrow `0x8676…a9f8`.

## Run

```bash
cp .env.example .env   # fill AGENT_PRIVATE_KEY (burner!) and addresses
bash scripts/forge-test.sh     # contract tests
bash scripts/forge-deploy.sh   # deploy PolicyVault on Arc testnet
npm install && npm run agent   # one dry-run agent tick
```

## Roadmap (hackathon)

- **W1** ✅ vault v0 + tests, agent skeleton (dry-run), deployed on Arc testnet
- **W2** StableFX end-to-end rebalancing, policies live
- **W3** dashboard + decision journal UI, scheduled payments
- **W4** polish, 3-min video, deck, final submission (Aug 9)
