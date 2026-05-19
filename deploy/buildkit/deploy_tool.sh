#!/bin/bash
# Shared deployment utility functions for OpenClaw deployment scripts

step() {
  local idx="$1"
  local text="$2"
  echo ""
  echo "[${idx}/6] ${text}"
}

substep() {
  echo "  -> $1"
}

fail() {
  echo "错误: $1" >&2
  exit 1
}

load_env_file_if_exists() {
  local env_file="$1"
  if [ -f "${env_file}" ]; then
    substep "加载环境变量: ${env_file}"
    set -a
    source <(sed 's/\r//' "${env_file}")
    set +a
  fi
}

require_file() {
  local file_path="$1"
  [ -f "${file_path}" ] || fail "未找到文件 (${file_path})"
}

require_cmd() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || fail "缺少命令 ${cmd}"
}

# General function to insert/update a secret in a KeePassXC database
# Usage: upsert_keepass_secret <db_path> <db_password> <entry_path> <secret_value>
upsert_keepass_secret() {
  local db_path="$1"
  local db_password="$2"
  local entry_path="$3"
  local secret_value="$4"
  local group_path="${entry_path%/*}"

  if [ "${group_path}" != "${entry_path}" ]; then
    echo "${db_password}" |
      keepassxc-cli mkdir -q "${db_path}" "${group_path}" >/dev/null 2>&1 || true
  fi

  printf '%s\n%s\n%s\n' "${db_password}" "${secret_value}" "${secret_value}" |
    keepassxc-cli add -q -u "openclaw" -p "${db_path}" "${entry_path}" >/dev/null 2>&1
}
