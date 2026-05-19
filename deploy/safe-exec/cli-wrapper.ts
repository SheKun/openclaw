import { spawn, SpawnOptions } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const USAGE = `
Usage: node cli-wrapper.ts <cli-command> [args...]

Positional argument:
  cli-command      Absolute path of the CLI to execute (first positional argument)
`.trim();

function usageExit(msg: string): never {
  console.error(`Error: ${msg}`);
  console.error(USAGE);
  process.exit(1);
}

if (process.argv.length < 3) {
  usageExit("No CLI command provided.");
}

const cliCommand = process.argv[2];

if (!path.isAbsolute(cliCommand)) {
  usageExit("CLI_COMMAND must be an absolute path.");
}

// Canonicalize to resolve symlinks and close the TOCTOU window.
let resolvedCliPath = "";
try {
  resolvedCliPath = fs.realpathSync(cliCommand);
} catch {
  usageExit("Command path does not exist or cannot be resolved.");
}

const ALLOWLIST_PATH = "/root/.vault/allowlist.json";
if (!fs.existsSync(ALLOWLIST_PATH)) {
  usageExit("Allowlist file not found.");
}

let allowlist: Record<string, unknown> = {};
try {
  const content = fs.readFileSync(ALLOWLIST_PATH, "utf8");
  allowlist = JSON.parse(content) as Record<string, unknown>;
} catch {
  usageExit("Failed to parse allowlist.");
}

function findAllowlistRecord(resolvedPath: string, list: Record<string, unknown>) {
  if (list[resolvedPath] !== undefined) {
    return list[resolvedPath];
  }

  for (const [key, value] of Object.entries(list)) {
    if (key === "*") {
      continue;
    }
    try {
      if (path.isAbsolute(key) && fs.realpathSync(key) === resolvedPath) {
        return value;
      }
    } catch {
      if (key === resolvedPath) {
        return value;
      }
    }
  }

  if (list["*"] !== undefined) {
    return list["*"];
  }

  return undefined;
}

const record = findAllowlistRecord(resolvedCliPath, allowlist);

if (record === undefined) {
  usageExit("Command is not in the allowed list.");
}

const config = record && typeof record === "object" ? (record as Record<string, unknown>) : {};
const envVal = config.env;
const slotVal = config.slot;

const hasEnvAndSlot =
  typeof envVal === "string" &&
  envVal.trim() !== "" &&
  typeof slotVal === "string" &&
  slotVal.trim() !== "";

let runAsRoot = false;
if (hasEnvAndSlot) {
  runAsRoot = true;
}

// Build a minimal env — only carry forward PATH, HOME, LANG, TERM, USER
const safeEnvKeys = ["PATH", "HOME", "LANG", "TERM", "USER"];
const childEnv: Record<string, string> = {};
for (const key of safeEnvKeys) {
  if (process.env[key] !== undefined) {
    childEnv[key] = process.env[key] as string;
  }
}

// Add the specific environment variables from `env` if both env and slot are valid
if (hasEnvAndSlot && typeof envVal === "string") {
  const envVars = envVal
    .split(",")
    .map((v: string) => v.trim())
    .filter(Boolean);
  for (const envVar of envVars) {
    childEnv[envVar] = process.env[envVar] || "";
  }
}

const spawnOptions: SpawnOptions = {
  stdio: "inherit",
  env: childEnv,
};

if (!runAsRoot) {
  const sudoUid = process.env.SUDO_UID;
  const sudoGid = process.env.SUDO_GID;
  const sudoUser = process.env.SUDO_USER;

  if (sudoUid) {
    spawnOptions.uid = Number.parseInt(sudoUid, 10);
  }
  if (sudoGid) {
    spawnOptions.gid = Number.parseInt(sudoGid, 10);
  }
  if (sudoUser) {
    childEnv.USER = sudoUser;
    childEnv.HOME = `/home/${sudoUser}`;
  }
}

const child = spawn(resolvedCliPath, process.argv.slice(3), spawnOptions);

child.on("exit", (code: number | null) => {
  process.exit(code ?? 1);
});
