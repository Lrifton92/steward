// FX Oracle — micro-service x402 : le taux EUR/USD se paie en nanopayments USDC (Circle Gateway).
// GET /rate sans paiement → 402 + PAYMENT-REQUIRED ; avec signature → verify + settle → taux.
// Lancer : node oracle/server.mjs → http://localhost:8791/rate
import { createServer } from "node:http";
import { readFileSync, appendFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { BatchFacilitatorClient } from "@circle-fin/x402-batching/server";

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const env = Object.fromEntries(
  readFileSync(path.join(root, ".env"), "utf8")
    .split(/\r?\n/)
    .filter((l) => l.includes("=") && !l.startsWith("#"))
    .map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1)])
);

const ARC_TESTNET_NETWORK = "eip155:5042002";
const ARC_TESTNET_GATEWAY_WALLET = "0x0077777d7EBA4688BDeF3E311b846F25870A19B9";
const PRICE = Number(env.ORACLE_PRICE_USDC || "0.0005");

// ⚠️ défaut SDK v3 = mainnet → forcer le facilitator TESTNET (sinon unsupported_network)
const facilitator = new BatchFacilitatorClient({ url: "https://gateway-api-testnet.circle.com" });

const requirements = {
  scheme: "exact",
  network: ARC_TESTNET_NETWORK,
  asset: env.USDC,
  amount: Math.round(PRICE * 1_000_000).toString(),
  payTo: env.ORACLE_ADDRESS,
  maxTimeoutSeconds: 345600,
  extra: { name: "GatewayWalletBatched", version: "1", verifyingContract: ARC_TESTNET_GATEWAY_WALLET },
};

async function rate() {
  const r = await fetch("https://api.frankfurter.app/latest?from=USD&to=EUR").then((x) => x.json());
  return { eurPerUsd: r.rates.EUR, source: "frankfurter", ts: new Date().toISOString() };
}

const server = createServer(async (req, res) => {
  const json = (code, obj, headers = {}) => {
    res.writeHead(code, { "content-type": "application/json", ...headers });
    res.end(JSON.stringify(obj));
  };
  if (!req.url.startsWith("/rate")) return json(404, { error: "not found" });

  const sig = req.headers["payment-signature"];
  if (!sig) {
    const paymentRequired = {
      x402Version: 2,
      resource: { url: env.ORACLE_URL, description: `FX rate EUR/USD (${PRICE} USDC)`, mimeType: "application/json" },
      accepts: [requirements],
    };
    return json(402, {}, { "PAYMENT-REQUIRED": Buffer.from(JSON.stringify(paymentRequired)).toString("base64") });
  }

  try {
    const payload = JSON.parse(Buffer.from(sig, "base64").toString("utf-8"));
    const verifyResult = await facilitator.verify(payload, requirements);
    if (!verifyResult.isValid) {
      console.error("[oracle] verify KO:", verifyResult.invalidReason, JSON.stringify(verifyResult).slice(0, 300));
      return json(402, { error: "verification failed", reason: verifyResult.invalidReason });
    }
    const settleResult = await facilitator.settle(payload, requirements);
    if (!settleResult.success) return json(402, { error: "settlement failed", reason: settleResult.errorReason });

    const payer = settleResult.payer ?? verifyResult.payer ?? "unknown";
    appendFileSync(path.join(root, "oracle", "payments.log"),
      JSON.stringify({ ts: new Date().toISOString(), payer, usdc: PRICE, tx: settleResult.transaction ?? null }) + "\n");
    console.log(`[oracle] paid ${PRICE} USDC by ${payer}`);

    const data = await rate();
    return json(200, data, {
      "PAYMENT-RESPONSE": Buffer.from(JSON.stringify({ success: true, transaction: settleResult.transaction, payer })).toString("base64"),
    });
  } catch (e) {
    return json(500, { error: e.message });
  }
});

server.listen(8791, () => console.log(`FX oracle (x402, ${PRICE} USDC/query): http://localhost:8791/rate`));
