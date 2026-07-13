// One-time : dépose 1 USDC du burner agent dans Circle Gateway (pour payer l'oracle en nanopayments).
import { GatewayClient } from "@circle-fin/x402-batching/client";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const env = Object.fromEntries(
  readFileSync(path.join(root, ".env"), "utf8").split(/\r?\n/)
    .filter((l) => l.includes("=") && !l.startsWith("#"))
    .map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1)])
);

const gateway = new GatewayClient({ chain: "arcTestnet", privateKey: env.AGENT_PRIVATE_KEY });
const before = await gateway.getBalances();
console.log("Gateway avant:", before.gateway.formattedAvailable, "| wallet USDC:", before.wallet ? before.wallet.balance : "?");
const result = await gateway.deposit("1");
console.log("Deposit tx:", result.depositTxHash);
const after = await gateway.getBalances();
console.log("Gateway après:", after.gateway.formattedAvailable);
