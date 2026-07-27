// Steward dashboard — serveur local : état trésorerie + journal + encodage des ops owner.
// Zéro dépendance hors viem. Lancer : node dashboard/server.mjs → http://localhost:8788
import { createServer } from "node:http";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createPublicClient, http as viemHttp, formatUnits, parseAbi, encodeFunctionData } from "viem";

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
const client = createPublicClient({ chain: arc, transport: viemHttp() });

const erc20 = parseAbi(["function balanceOf(address) view returns (uint256)"]);
const vaultAbi = parseAbi([
  "function remainingToday(address) view returns (uint256)",
  "function dailyCap(address) view returns (uint256)",
  "function owner() view returns (address)",
  "function agent() view returns (address)",
  "function allowedPayee(address) view returns (bool)",
  "function setPayee(address payee, bool allowed)",
  "function setDailyCap(address token, uint256 cap)",
  "function ownerWithdraw(address token, address to, uint256 amount)",
]);
const deskAbi = parseAbi(["function rateUsdcToEurc() view returns (uint256)"]);

const bal6 = (v) => Number(formatUnits(v, 6));

// Le RPC public Arc plafonne à ~1 requête/seconde (mesuré : 0,2 s d'écart => 50 % de
// "request limit reached", 1 s => 100 % OK). On lit donc en série à ~1 req/s, avec retry,
// et on met l'état en cache : sinon un refresh (11 lectures) casse, et l'agent qui lit en
// parallèle sur la même IP consomme le même quota.
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function read(call, label) {
  for (let i = 0; ; i++) {
    try { const v = await client.readContract(call); await sleep(900); return v; }
    catch (e) {
      if (i === 3) throw new Error(`${label}: ${e.shortMessage || e.message}`);
      await sleep(2000 * (i + 1));
    }
  }
}

const STATE_TTL_MS = 15000;
let stateCache = { at: 0, value: null, inflight: null };
async function cachedState() {
  if (stateCache.value && Date.now() - stateCache.at < STATE_TTL_MS) return stateCache.value;
  if (!stateCache.inflight) {
    stateCache.inflight = state()
      .then((v) => { stateCache = { at: Date.now(), value: v, inflight: null }; return v; })
      .catch((e) => { stateCache.inflight = null; throw e; });
  }
  return stateCache.inflight;
}

async function state() {
  const V = env.VAULT_ADDRESS, D = env.FXDESK_ADDRESS;
  const vUsdc = await read({ address: env.USDC, abi: erc20, functionName: "balanceOf", args: [V] }, "vault USDC");
  const vEurc = await read({ address: env.EURC, abi: erc20, functionName: "balanceOf", args: [V] }, "vault EURC");
  const dUsdc = await read({ address: env.USDC, abi: erc20, functionName: "balanceOf", args: [D] }, "desk USDC");
  const dEurc = await read({ address: env.EURC, abi: erc20, functionName: "balanceOf", args: [D] }, "desk EURC");
  const rate = await read({ address: D, abi: deskAbi, functionName: "rateUsdcToEurc" }, "desk rate");
  const capU = await read({ address: V, abi: vaultAbi, functionName: "dailyCap", args: [env.USDC] }, "cap USDC");
  const capE = await read({ address: V, abi: vaultAbi, functionName: "dailyCap", args: [env.EURC] }, "cap EURC");
  const remU = await read({ address: V, abi: vaultAbi, functionName: "remainingToday", args: [env.USDC] }, "remaining USDC");
  const remE = await read({ address: V, abi: vaultAbi, functionName: "remainingToday", args: [env.EURC] }, "remaining EURC");
  const owner = await read({ address: V, abi: vaultAbi, functionName: "owner" }, "owner");
  const agent = await read({ address: V, abi: vaultAbi, functionName: "agent" }, "agent");
  let market = null;
  try {
    const r = await fetch("https://api.frankfurter.app/latest?from=USD&to=EUR").then((x) => x.json());
    market = r.rates.EUR;
  } catch {}
  let payments = [];
  try { payments = JSON.parse(readFileSync(path.join(root, "agent", "payments.json"), "utf8")); } catch {}
  // Stats oracle nanopayments, dérivées du journal : dernière source FX + cumul payé en x402.
  let oracle = { lastSource: null, lastPaidUsdc: null, totalPaidUsdc: 0, paidCount: 0 };
  try {
    const lines = readFileSync(path.join(root, "agent", "journal.jsonl"), "utf8").trim().split(/\r?\n/);
    for (const l of lines) {
      let e; try { e = JSON.parse(l); } catch { continue; }
      const m = e.market || {};
      if (m.source) { oracle.lastSource = m.source; oracle.lastPaidUsdc = m.paidUsdc ?? null; }
      if (m.paidUsdc) { oracle.totalPaidUsdc += Number(m.paidUsdc); oracle.paidCount++; }
    }
    oracle.totalPaidUsdc = Number(oracle.totalPaidUsdc.toFixed(6));
  } catch {}
  return {
    addresses: { vault: V, desk: D, usdc: env.USDC, eurc: env.EURC, owner, agent },
    vault: { USDC: bal6(vUsdc), EURC: bal6(vEurc) },
    desk: { USDC: bal6(dUsdc), EURC: bal6(dEurc), rateUsdcToEurc: Number(rate) / 1e6 },
    caps: { USDC: { cap: bal6(capU), remaining: bal6(remU) }, EURC: { cap: bal6(capE), remaining: bal6(remE) } },
    market: { eurPerUsd: market },
    oracle,
    payments,
  };
}

function journal(limit = 60) {
  try {
    const lines = readFileSync(path.join(root, "agent", "journal.jsonl"), "utf8").trim().split(/\r?\n/);
    return lines.slice(-limit).reverse().map((l) => JSON.parse(l));
  } catch { return []; }
}

function encodeOp(q) {
  const fn = q.get("fn");
  if (fn === "setPayee")
    return encodeFunctionData({ abi: vaultAbi, functionName: "setPayee", args: [q.get("payee"), q.get("allowed") === "true"] });
  if (fn === "setDailyCap")
    return encodeFunctionData({ abi: vaultAbi, functionName: "setDailyCap", args: [q.get("token") === "EURC" ? env.EURC : env.USDC, BigInt(Math.round(Number(q.get("cap")) * 1e6))] });
  if (fn === "ownerWithdraw")
    return encodeFunctionData({ abi: vaultAbi, functionName: "ownerWithdraw", args: [q.get("token") === "EURC" ? env.EURC : env.USDC, q.get("to"), BigInt(Math.round(Number(q.get("amount")) * 1e6))] });
  throw new Error("unknown fn");
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url, "http://localhost");
  const json = (code, obj) => { res.writeHead(code, { "content-type": "application/json" }); res.end(JSON.stringify(obj)); };
  try {
    if (url.pathname === "/api/state") return json(200, await cachedState());
    if (url.pathname === "/api/journal") return json(200, journal());
    if (url.pathname === "/api/encode") return json(200, { to: env.VAULT_ADDRESS, data: encodeOp(url.searchParams), chainId: Number(env.CHAIN_ID) });
    const html = readFileSync(path.join(root, "dashboard", "index.html"));
    res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    res.end(html);
  } catch (e) {
    json(500, { error: e.message });
  }
});

server.listen(8788, () => console.log("Steward dashboard: http://localhost:8788"));
