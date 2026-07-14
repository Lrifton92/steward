# Steward — Autonomous Treasury Agent on Arc

> Encode × Arc "Programmable Money" Hackathon 2026 — Agentic Economy Track.

Steward is an autonomous treasury agent for multi-currency stablecoin treasuries on [Arc](https://arc.network).
A **policy vault** deployed on Arc holds USDC/EURC and encodes hard rules — token, payee and
target allowlists, per-token daily caps. A **24/7 agent** monitors balances and live FX,
rebalances USDC↔EURC through an on-chain FX desk when policy and market conditions align,
runs scheduled outbound payments, and **pays for its own FX data via x402 nanopayments**.
A **mission-control dashboard** shows every decision with its reasoning.

**The point: agents shouldn't just hold keys — they should operate inside on-chain guardrails
their owner defines.** The agent's key can only act through the vault; the owner can always
withdraw everything, no policy checks.

## What's live (Arc testnet)

- **PolicyVault v2** — `0x7523BfE340EF8c1662844B3F4D663e87C4560E32` (roles owner/agent, allowlists, 50 USDC & EURC daily caps)
- **FxDesk** — `0x7B82f3b3…caA9`, atomic USDC↔EURC settlement at a posted rate (pluggable: same interface as any escrow-based FX venue)
- **First autonomous rebalance** executed at the live rate (0.87535), converging to the 60/40 target band
- **Scheduled payments** — declared in `agent/payments.json`, refused until the owner allowlists the payee on-chain, then executed autonomously by the loop
- **Nanopayments** — the agent buys each FX quote from a local x402 oracle (0.0005 USDC/request via Circle Gateway, testnet), with a free fallback; the dashboard shows the paid source badge and cumulative oracle spend

## Track criteria coverage

1. **Clear decision logic tied to real signals** → decision journal: every tick logs balances, live EUR/USD, the decision and its why
2. **Autonomous spending / settlement flows** → policy-gated rebalances + scheduled payments, executed without human intervention
3. **Nanopayments between services** → agent pays its FX oracle per query (x402 / Circle Gateway)
4. **USDC-denominated operations with demonstrable autonomy** → all flows settle in USDC/EURC on Arc, gas in USDC

## Architecture

- `contracts/` — Foundry project (`base-forge`). `PolicyVault.sol` (roles, allowlists, daily caps
  with lazy day-window reset, owner escape hatch) + `FxDesk.sol` (atomic FX settlement). 22 tests.
- `agent/` — Node/viem loop (15 min): reads vault + desk + live FX (paid x402 oracle, free fallback),
  decides, executes when `EXECUTE=1`, journals to `journal.jsonl`, runs due scheduled payments.
- `oracle/` — x402-priced FX rate endpoint (`:8791`, 0.0005 USDC/req).
- `dashboard/` — zero-dependency local server (`:8788`): treasury state, caps, decision journal,
  oracle spend, and an owner console (allowlist payee / set caps / withdraw — signs with the owner wallet).
- `scripts/` — WSL helpers for base-forge (init/test/deploy) + `start-steward.cmd` (agent + dashboard + oracle).

## Arc testnet

Chain `5042002` · RPC `https://rpc.testnet.arc.network` · gas = USDC.
USDC `0x3600…0000` · EURC `0x89B5…D72a`.

## Run

```bash
cp .env.example .env   # fill AGENT_PRIVATE_KEY (burner!) and addresses
bash scripts/forge-test.sh        # contract tests (22)
bash scripts/forge-deploy-v2.sh   # deploy PolicyVault + FxDesk on Arc testnet
npm install
scripts/start-steward.cmd         # agent loop + dashboard (:8788) + x402 oracle (:8791)
```

## Roadmap (hackathon)

- **W1** ✅ vault v0 + tests, agent skeleton (dry-run), deployed on Arc testnet
- **W2** ✅ FxDesk settlement + execute mode — first autonomous rebalance at the live rate
- **W3** ✅ 24/7 loop, scheduled payments, mission-control dashboard, x402 nanopayments oracle
- **W4** polish, 3-min video, deck, final submission (Aug 9)
