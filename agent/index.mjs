// Steward agent — observe le vault, décide selon la policy, et (mode EXECUTE=1) exécute
// le rebalance via le FxDesk en restant dans les garde-fous on-chain du PolicyVault.
// Chaque tick journalise la décision AVEC son pourquoi (journal.jsonl) — auditable.
import { createPublicClient, createWalletClient, http, formatUnits, parseAbi } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { readFileSync, appendFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const env = Object.fromEntries(
  readFileSync(path.join(root, ".env"), "utf8")
    .split(/\r?\n/)
    .filter((l) => l.includes("=") && !l.startsWith("#"))
    .map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1)])
);

const arc = {
  id: Number(env.CHAIN_ID),
  name: "Arc Testnet",
  nativeCurrency: { name: "USDC", symbol: "USDC", decimals: 18 },
  rpcUrls: { default: { http: [env.ARC_RPC] } },
};

const client = createPublicClient({ chain: arc, transport: http() });
const account = privateKeyToAccount(env.AGENT_PRIVATE_KEY);
const wallet = createWalletClient({ account, chain: arc, transport: http() });

const erc20 = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function decimals() view returns (uint8)",
]);
const vaultAbi = parseAbi([
  "function remainingToday(address) view returns (uint256)",
  "function approveTarget(address token, address target, uint256 amount)",
]);
const deskAbi = parseAbi([
  "function rateUsdcToEurc() view returns (uint256)",
  "function setRate(uint256 rate)",
  "function quote(address tokenIn, uint256 amountIn) view returns (uint256)",
  "function swapFor(address payer, address tokenIn, uint256 amountIn) returns (uint256)",
]);

const POLICY = {
  targetUsdcBps: 6000, // cible 60% USDC / 40% EURC (en valeur USD)
  rebalanceBandBps: 500, // ne rien faire sous 5 points de déviation
  maxSlippageBps: 150, // taux desk vs taux marché
};

async function marketRate() {
  // EUR par USD → EURC par USDC (6 déc.)
  const r = await fetch("https://api.frankfurter.app/latest?from=USD&to=EUR").then((x) => x.json());
  return { eurPerUsd: r.rates.EUR, rate6: BigInt(Math.round(r.rates.EUR * 1e6)) };
}

async function tokenBalance(token, holder) {
  const [bal, dec] = await Promise.all([
    client.readContract({ address: token, abi: erc20, functionName: "balanceOf", args: [holder] }),
    client.readContract({ address: token, abi: erc20, functionName: "decimals" }),
  ]);
  return Number(formatUnits(bal, dec));
}

function decide(usdc, eurcInUsd) {
  const total = usdc + eurcInUsd;
  if (total === 0) return { action: "none", reason: "vault empty" };
  const usdcBps = Math.round((usdc / total) * 10000);
  const dev = usdcBps - POLICY.targetUsdcBps;
  if (Math.abs(dev) < POLICY.rebalanceBandBps)
    return { action: "none", reason: `within band (usdc=${usdcBps}bps, target=${POLICY.targetUsdcBps})` };
  const from = dev > 0 ? "USDC" : "EURC";
  const amountUsd = (Math.abs(dev) / 10000) * total;
  return {
    action: "rebalance",
    from,
    to: from === "USDC" ? "EURC" : "USDC",
    amountUsd,
    reason: `usdc share ${usdcBps}bps vs target ${POLICY.targetUsdcBps}bps (band ${POLICY.rebalanceBandBps})`,
  };
}

async function executeRebalance(decision, mkt) {
  const vault = env.VAULT_ADDRESS;
  const desk = env.FXDESK_ADDRESS;
  const tokenIn = decision.from === "USDC" ? env.USDC : env.EURC;
  // montant en unités du token d'entrée (6 déc.) ; pour EURC on convertit la valeur USD
  const amountIn = decision.from === "USDC"
    ? BigInt(Math.round(decision.amountUsd * 1e6))
    : BigInt(Math.round(decision.amountUsd * mkt.eurPerUsd * 1e6));

  // 1. rafraîchir le taux du desk sur le marché (le burner est owner du desk testnet)
  const setRateTx = await wallet.writeContract({ address: desk, abi: deskAbi, functionName: "setRate", args: [mkt.rate6] });
  await client.waitForTransactionReceipt({ hash: setRateTx });

  // 2. garde-fou slippage : quote desk vs taux marché
  const quoted = await client.readContract({ address: desk, abi: deskAbi, functionName: "quote", args: [tokenIn, amountIn] });
  const expected = decision.from === "USDC"
    ? (amountIn * mkt.rate6) / 1_000_000n
    : (amountIn * 1_000_000n) / mkt.rate6;
  const slipBps = expected > 0n ? Number(((expected > quoted ? expected - quoted : 0n) * 10000n) / expected) : 0;
  if (slipBps > POLICY.maxSlippageBps) return { executed: false, reason: `slippage ${slipBps}bps > max` };

  // 3. approve depuis le vault (compte dans le cap journalier) puis settlement
  const approveTx = await wallet.writeContract({ address: vault, abi: vaultAbi, functionName: "approveTarget", args: [tokenIn, desk, amountIn] });
  await client.waitForTransactionReceipt({ hash: approveTx });
  const swapTx = await wallet.writeContract({ address: desk, abi: deskAbi, functionName: "swapFor", args: [vault, tokenIn, amountIn] });
  const rcpt = await client.waitForTransactionReceipt({ hash: swapTx });
  return { executed: true, amountIn: amountIn.toString(), quoted: quoted.toString(), approveTx, swapTx, block: Number(rcpt.blockNumber) };
}

async function tick() {
  const vault = env.VAULT_ADDRESS;
  const mkt = await marketRate();
  const [usdc, eurc] = await Promise.all([
    tokenBalance(env.USDC, vault),
    tokenBalance(env.EURC, vault),
  ]);
  const eurcInUsd = eurc / mkt.eurPerUsd;
  const decision = decide(usdc, eurcInUsd);

  let execution = null;
  if (decision.action === "rebalance" && process.env.EXECUTE === "1") {
    try {
      execution = await executeRebalance(decision, mkt);
    } catch (e) {
      execution = { executed: false, error: (e.shortMessage || e.message || "").slice(0, 200) };
    }
  }

  const entry = {
    ts: new Date().toISOString(),
    vault,
    balances: { USDC: usdc, EURC: eurc },
    market: { eurPerUsd: mkt.eurPerUsd },
    decision,
    execution,
    mode: process.env.EXECUTE === "1" ? "execute" : "dry-run",
  };
  console.log(JSON.stringify(entry, null, 2));
  appendFileSync(path.join(root, "agent", "journal.jsonl"), JSON.stringify(entry) + "\n");
}

tick().catch((e) => {
  console.error("tick failed:", e.message);
  process.exit(1);
});
