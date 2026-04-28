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

PARSED_ARGS=$(getopt -o h --long help,server-user:,public-key:,auth-options: -n create_ssh_user.sh -- "$@") \
    || die "参数解析失败"
eval set -- "$PARSED_ARGS"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            usage
            exit 0
            ;;
        --server-user|--public-key|--auth-options)
            set_option "$1" "$2"
            shift 2
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

NOLOGIN_SHELL="/usr/sbin/nologin"
if [[ ! -x "$NOLOGIN_SHELL" ]]; then
    NOLOGIN_SHELL="/sbin/nologin"
fi
if [[ ! -x "$NOLOGIN_SHELL" ]]; then
    NOLOGIN_SHELL="/usr/bin/false"
fi

ensure_user() {
    local current_user
    current_user=$(id -un)

    if id "$SERVER_USER" >/dev/null 2>&1; then
        if [[ "$current_user" != "root" ]]; then
            echo "错误: 当前执行用户(${current_user})不是 root，无法修改用户 ${SERVER_USER}"
            exit 1
        fi
        usermod -s "$NOLOGIN_SHELL" "$SERVER_USER"
        passwd -l "$SERVER_USER" >/dev/null || true
        return
    fi

    if [[ "$current_user" != "root" ]]; then
        echo "错误: 当前执行用户(${current_user})不是 root，无法创建用户 ${SERVER_USER}"
        exit 1
    fi

    useradd -m -s "$NOLOGIN_SHELL" "$SERVER_USER"
    passwd -l "$SERVER_USER" >/dev/null || true
}

ensure_user

SERVER_HOME=$(getent passwd "$SERVER_USER" | cut -d: -f6)
if [[ -z "$SERVER_HOME" ]]; then
    echo "错误: 无法解析用户 ${SERVER_USER} 的 home 目录"
    exit 1
fi

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

SERVER_GROUP=$(id -gn "$SERVER_USER")
chown -R "$SERVER_USER:$SERVER_GROUP" "$SERVER_SSH_DIR"

echo "=================================================="
echo "✅ SSH 授权配置完成"
echo "server_user: ${SERVER_USER}"
echo "server_ssh_dir: ${SERVER_SSH_DIR}"
echo "nologin_shell: ${NOLOGIN_SHELL}"
echo "=================================================="
