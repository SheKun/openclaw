#!/bin/sh
# OpenClaw exec secret provider backed by KeePassXC.
# Usage: keepassxc-vault.sh <db-path> <password-file>

set -eu

DB_PATH="${1:-}"
PASS_FILE="${2:-}"

if [ -z "$DB_PATH" ] || [ -z "$PASS_FILE" ]; then
  echo '{"protocolVersion":1,"values":{},"errors":{"*":{"message":"usage: keepassxc-vault.sh <db-path> <password-file>"}}}'
  exit 0
fi

if [ ! -f "$DB_PATH" ]; then
  echo '{"protocolVersion":1,"values":{},"errors":{"*":{"message":"vault database not found"}}}'
  exit 0
fi

if [ ! -f "$PASS_FILE" ]; then
  echo '{"protocolVersion":1,"values":{},"errors":{"*":{"message":"vault password file not found"}}}'
  exit 0
fi

if ! command -v keepassxc-cli >/dev/null 2>&1; then
  echo '{"protocolVersion":1,"values":{},"errors":{"*":{"message":"keepassxc-cli not available"}}}'
  exit 0
fi

REQUEST_JSON="$(cat)"
PASS="$(cat "$PASS_FILE")"
VALUES_FILE="$(mktemp)"
ERRORS_FILE="$(mktemp)"
trap 'rm -f "$VALUES_FILE" "$ERRORS_FILE"' EXIT

# Parse requested ids from the exec-provider request payload.
node - "$REQUEST_JSON" <<'NODE' | while IFS= read -r secret_id; do
const req = JSON.parse(process.argv[2] ?? "{}");
const ids = Array.isArray(req.ids) ? req.ids : [];
for (const id of ids) {
  if (typeof id === "string") {
    process.stdout.write(`${id}\n`);
  }
}
NODE
  if [ -z "$secret_id" ]; then
    continue
  fi

  if secret_value=$(printf '%s\n' "$PASS" | keepassxc-cli show -q -a Password "$DB_PATH" "$secret_id" 2>&1 | grep -v 'QObject::killTimer'); then
    printf '%s\t%s\n' "$secret_id" "$secret_value" >> "$VALUES_FILE"
  else
    printf '%s\tvault entry not found\n' "$secret_id" >> "$ERRORS_FILE"
  fi
done

node - "$VALUES_FILE" "$ERRORS_FILE" <<'NODE'
const fs = require('node:fs');

const valuesPath = process.argv[2];
const errorsPath = process.argv[3];
const values = {};
const errors = {};

for (const line of fs.readFileSync(valuesPath, 'utf8').split('\n')) {
  if (!line) continue;
  const tabIndex = line.indexOf('\t');
  if (tabIndex < 0) continue;
  const id = line.slice(0, tabIndex);
  const value = line.slice(tabIndex + 1);
  values[id] = value;
}

for (const line of fs.readFileSync(errorsPath, 'utf8').split('\n')) {
  if (!line) continue;
  const tabIndex = line.indexOf('\t');
  if (tabIndex < 0) continue;
  const id = line.slice(0, tabIndex);
  const message = line.slice(tabIndex + 1);
  errors[id] = { message };
}

const response = {
  protocolVersion: 1,
  values,
};
if (Object.keys(errors).length > 0) {
  response.errors = errors;
}
process.stdout.write(JSON.stringify(response));
NODE
