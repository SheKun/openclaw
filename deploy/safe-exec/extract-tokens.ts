import { execFileSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";

const VAULT_DIR = "/root/.vault";
const ALLOWLIST_PATH = path.join(VAULT_DIR, "allowlist.json");
const KDBX_PATH = path.join(VAULT_DIR, "vault.kdbx");
const KEY_PATH = path.join(VAULT_DIR, "key.pass");
const ENV_PATH = path.join(VAULT_DIR, "env");

function main() {
  console.log("🔑 Extracting tokens from KeePassXC vault...");

  if (!fs.existsSync(ALLOWLIST_PATH)) {
    console.warn(`⚠️ Allowlist file not found at ${ALLOWLIST_PATH}`);
    return;
  }

  let allowlist: Record<string, unknown> = {};
  try {
    const content = fs.readFileSync(ALLOWLIST_PATH, "utf8");
    allowlist = JSON.parse(content);
  } catch (err) {
    console.error(`❌ Failed to parse allowlist.json:`, err);
    process.exit(1);
  }

  if (!fs.existsSync(KDBX_PATH) || !fs.existsSync(KEY_PATH)) {
    console.warn(
      `⚠️ KeePassXC vault.kdbx or key.pass not found under ${VAULT_DIR}. Skipping token extraction.`,
    );
    return;
  }

  let masterKey = "";
  try {
    masterKey = fs.readFileSync(KEY_PATH, "utf8").trim();
  } catch (err) {
    console.error(`❌ Failed to read master key from ${KEY_PATH}:`, err);
    process.exit(1);
  }

  const envLines: string[] = [];
  const keyBuf = Buffer.from(masterKey + "\n");

  for (const [cmd, config] of Object.entries(allowlist)) {
    if (!config || typeof config !== "object") {
      continue;
    }
    const { env, slot } = config as Record<string, unknown>;
    if (typeof env === "string" && env.trim() && typeof slot === "string" && slot.trim()) {
      console.log(`Extracting token for command "${cmd}" from slot "${slot}"...`);
      try {
        const token = execFileSync(
          "keepassxc-cli",
          ["show", "-a", "Password", KDBX_PATH, slot.trim()],
          {
            encoding: "utf8",
            input: keyBuf,
          },
        ).trim();

        const envVars = env
          .split(",")
          .map((v: string) => v.trim())
          .filter(Boolean);
        for (const envVar of envVars) {
          const escaped = token.replace(/'/g, "'\\''");
          envLines.push(`export ${envVar}='${escaped}'`);
          process.env[envVar] = token;
        }
      } catch (err: unknown) {
        const errMsg =
          err && typeof err === "object" && "stderr" in err && err.stderr
            ? String(err.stderr)
            : String(err);
        console.error(`❌ Failed to retrieve token for slot "${slot}":`, errMsg);
      }
    }
  }

  // Zero the buffer for security
  keyBuf.fill(0);

  // Write to /root/.vault/env
  try {
    fs.writeFileSync(ENV_PATH, envLines.join("\n") + "\n", { mode: 0o600 });
    console.log(`✅ Tokens successfully written to ${ENV_PATH}`);
  } catch (err) {
    console.error(`❌ Failed to write environment file to ${ENV_PATH}:`, err);
    process.exit(1);
  }
}

main();
