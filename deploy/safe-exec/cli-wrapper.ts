const { execFileSync, spawn } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const USAGE = `
Usage: ALLOWED_CLIS=<paths> TOKEN_SLOT_PATH=<slot> KEEPASSXC_DB=<db> KEEPASSXC_KEY=<key> node cli-wrapper.ts <cli-command> [args...]

Positional argument:
  cli-command      Absolute path of the CLI to execute (first positional argument)

Required environment variables:
  ALLOWED_CLIS     Comma-separated list of allowed CLI absolute paths
  TOKEN_SLOT_PATH  KeePassXC entry path for the token (keystore slot)
  KEEPASSXC_DB     Path to the KeePassXC database file
  KEEPASSXC_KEY    KeePassXC master key

Optional:
  TOKEN_ENV_VARS   Comma-separated env var names to inject the token into
                    (default: TOKEN,API_KEY)
`.trim();

function usageExit(msg: string): never {
  console.error(`Error: ${msg}`);
  console.error(USAGE);
  process.exit(1);
}

if (process.argv.length < 3) {
  usageExit("No CLI command provided.");
}

// --- Validate all required inputs first, before any processing ---
const cliCommand = process.argv[2];
const rawAllowedClisStr = process.env.ALLOWED_CLIS || "";
const keePassDb = process.env.KEEPASSXC_DB;
const keePassKey = process.env.KEEPASSXC_KEY;
const tokenSlotPath = process.env.TOKEN_SLOT_PATH;

if (!rawAllowedClisStr) {
  usageExit("ALLOWED_CLIS environment variable is not set or empty.");
}

if (!tokenSlotPath) {
  usageExit("TOKEN_SLOT_PATH environment variable is not set.");
}

if (!keePassDb || !keePassKey) {
  usageExit("KEEPASSXC_DB and KEEPASSXC_KEY environment variables must be set.");
}

if (!path.isAbsolute(cliCommand)) {
  usageExit("CLI_COMMAND must be an absolute path.");
}

// --- Now safe to parse and process ---

// #11: Configurable token env var names via TOKEN_ENV_VARS (comma-separated).
// Defaults to TOKEN,API_KEY for backward compatibility.
const tokenEnvVarNames = (process.env.TOKEN_ENV_VARS || "TOKEN,API_KEY")
  .split(",")
  .map((v: string) => v.trim())
  .filter(Boolean);

// #3: Canonicalize allowed paths at startup so realpath comparisons are consistent.
const allowedClis: string[] = rawAllowedClisStr
  .split(",")
  .map((p: string) => p.trim())
  .filter(Boolean)
  .map((p: string) => {
    try {
      return fs.realpathSync(p);
    } catch {
      return p; // path may not exist yet; keep as-is for error reporting
    }
  });

// #3: Canonicalize to resolve symlinks and close the TOCTOU window.
let resolvedCliPath = "";
try {
  resolvedCliPath = fs.realpathSync(cliCommand);
} catch {
  usageExit("Command path does not exist or cannot be resolved.");
}

// #5: Generic rejection — do not leak resolved paths in stderr.
if (!allowedClis.includes(resolvedCliPath)) {
  usageExit("Command is not in the allowed list.");
}

// Retrieve the token from KeePassXC using TOKEN_SLOT_PATH as the entry key
let token = "";
// #9: Allocate a dedicated Buffer for the master key so we can zero it after use.
const keyBuf = Buffer.from(keePassKey + "\n");
try {
  token = execFileSync("keepassxc-cli", ["show", "-a", "Password", keePassDb, tokenSlotPath], {
    encoding: "utf8",
    input: keyBuf, // Provide master key via stdin to avoid interactive prompt
  }).trim();
} catch (err: unknown) {
  // #5: Generic error — no path leakage.
  console.error("Error: Failed to retrieve token from KeePassXC.");
  const errMsg = err instanceof Error && err.stderr ? err.stderr.toString() : String(err);
  console.error(errMsg);
  keyBuf.fill(0);
  process.exit(1);
}
// #9: Zero the master key buffer immediately after use.
keyBuf.fill(0);

// #6: Build a minimal env — only carry forward PATH, HOME, LANG, TERM, USER
// plus the token vars. Do NOT spread the full parent env.
const safeEnvKeys = ["PATH", "HOME", "LANG", "TERM", "USER"];
const childEnv: Record<string, string> = {};
for (const key of safeEnvKeys) {
  if (process.env[key] !== undefined) {
    childEnv[key] = process.env[key] as string;
  }
}
// #11: Inject token into only the configured env var names.
for (const varName of tokenEnvVarNames) {
  childEnv[varName] = token;
}

// Execute the CLI with the token injected into the environment.
// process.argv[2] is the CLI_COMMAND; process.argv[3+] are args for the target CLI.
const child = spawn(resolvedCliPath, process.argv.slice(3), {
  stdio: "inherit",
  env: childEnv,
});

child.on("exit", (code: number | null) => {
  process.exit(code ?? 1);
});
