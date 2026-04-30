#!/bin/bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
    create_ssh_user.sh [options]

Reusable SSH server-side authorized_keys setup script.

Options:
    --server-user <name>           SSH service-side user (required)
    --public-key <value>           SSH public key content (required)
    --auth-options <value>         Full authorized_keys options prefix (optional)
    --home <directory>             Set user home directory directly; skips mkdir (optional)
    --nologin                      Create/update user with nologin shell (optional)

    --help                         Show this help
EOF
}

die() {
    echo "错误: $1"
    usage
    exit 1
}

set_option() {
    case "$1" in
        --server-user) SERVER_USER="$2" ;;
        --public-key) PUBLIC_KEY="$2" ;;
        --auth-options) AUTH_OPTIONS="$2" ;;
        --home) HOME_DIR="$2" ;;
        *) die "未知参数: $1" ;;
    esac
}

require_value() {
    local value="$1"
    local option_name="$2"
    [[ -n "$value" ]] || die "必须提供 ${option_name}"
}

SERVER_USER=""
PUBLIC_KEY=""
AUTH_OPTIONS=""
HOME_DIR=""
NOLOGIN_MODE="false"

PARSED_ARGS=$(getopt -o h --long help,server-user:,public-key:,auth-options:,nologin,home: -n create_ssh_user.sh -- "$@") \
    || die "参数解析失败"
eval set -- "$PARSED_ARGS"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            usage
            exit 0
            ;;
        --server-user|--public-key|--auth-options|--home)
            set_option "$1" "$2"
            shift 2
            ;;
        --nologin)
            NOLOGIN_MODE="true"
            shift
            ;;
        --)
            shift
            break
            ;;
        *)
            die "未知参数: $1"
            ;;
    esac
done

[[ $# -eq 0 ]] || die "不支持的位置参数: \`$1\`，完整命令：\`$*\`"

require_value "$SERVER_USER" "--server-user"
require_value "$PUBLIC_KEY" "--public-key"

resolve_nologin_shell() {
    local shell="/usr/sbin/nologin"
    if [[ ! -x "$shell" ]]; then
        shell="/sbin/nologin"
    fi
    if [[ ! -x "$shell" ]]; then
        shell="/usr/bin/false"
    fi
    printf '%s\n' "$shell"
}

resolve_login_shell() {
    local shell="/bin/bash"
    if [[ ! -x "$shell" ]]; then
        shell="/bin/sh"
    fi
    printf '%s\n' "$shell"
}

if [[ "$NOLOGIN_MODE" == "true" ]]; then
    TARGET_SHELL="$(resolve_nologin_shell)"
else
    TARGET_SHELL="$(resolve_login_shell)"
fi

echo "=> 创建用户 ..."
ensure_user() {
    local current_user
    current_user=$(id -un)
    if [[ "$current_user" != "root" ]]; then
        echo "错误: 当前执行用户(${current_user})不是 root，无法创建用户 ${SERVER_USER}"
        exit 1
    fi

    if id "$SERVER_USER" >/dev/null 2>&1; then
        if [[ -n "$HOME_DIR" ]]; then
            usermod -s "$TARGET_SHELL" -d "$HOME_DIR" "$SERVER_USER" >/dev/null || true
        else
            usermod -s "$TARGET_SHELL" "$SERVER_USER" >/dev/null || true
        fi
    else
        if [[ -n "$HOME_DIR" ]]; then
            # -M: do not create/populate home dir (provided by volume mount), -d: register home path
            useradd -M -d "$HOME_DIR" -s "$TARGET_SHELL" "$SERVER_USER"
        else
            useradd -m -s "$TARGET_SHELL" "$SERVER_USER"
        fi
    fi
    passwd -l "$SERVER_USER" >/dev/null || true
}

ensure_user
if [[ -n "$HOME_DIR" ]]; then
    SERVER_HOME="$HOME_DIR"
else
    SERVER_HOME=$(getent passwd "$SERVER_USER" | cut -d: -f6)
    if [[ -z "$SERVER_HOME" ]]; then
        echo "错误: 无法解析用户 ${SERVER_USER} 的 home 目录"
        exit 1
    fi
fi

echo "=> 配置 SSH 公钥授权 ..."
SERVER_SSH_DIR="${SERVER_HOME}/.ssh"
AUTH_KEYS="${SERVER_SSH_DIR}/authorized_keys"

mkdir -p "$SERVER_SSH_DIR"
chmod 700 "$SERVER_SSH_DIR"

if [[ -n "$AUTH_OPTIONS" ]]; then
    AUTH_LINE="${AUTH_OPTIONS} ${PUBLIC_KEY}"
else
    AUTH_LINE="$PUBLIC_KEY"
fi

touch "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"
if ! grep -qxF "$AUTH_LINE" "$AUTH_KEYS"; then
    printf '%s\n' "$AUTH_LINE" >> "$AUTH_KEYS"
fi

echo "=> 设置 ${SERVER_USER} 的 home 目录权限 ..."
SERVER_GROUP=$(id -gn "$SERVER_USER")
mkdir -p "$SERVER_HOME"
chown -R "$SERVER_USER:$SERVER_GROUP" "$SERVER_HOME"

echo "=================================================="
echo "✅ SSH 用户 ${SERVER_USER} 配置完成！"
echo "server_user: ${SERVER_USER}"
echo "server_ssh_dir: ${SERVER_SSH_DIR}"
echo "home_dir: ${SERVER_HOME}"
echo "login_shell: ${TARGET_SHELL}"
echo "nologin_mode: ${NOLOGIN_MODE}"
echo "=================================================="
