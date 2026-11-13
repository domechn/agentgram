#!/usr/bin/env bash
# Installs hermes-bridge as a system-level systemd service (Restart=always) on the Hermes host.
#
#   sudo ./install.sh                install or update; asks for the bot token and your Telegram id
#   sudo ./install.sh --enable-api   turn on the Hermes API server on 127.0.0.1 (restarts the gateway)
#   sudo ./install.sh --rotate-key   new shared key (paste it into AgentGram again)
#   sudo ./install.sh --show-key     print the shared key again
#   sudo ./install.sh --uninstall
#
# Non-interactive: AG_BOT_TOKEN=… AG_USER_ID=… sudo -E ./install.sh
set -euo pipefail

# The AG_* path overrides exist so the script can be exercised without root.
ETC=${AG_ETC:-/etc}
UNIT_DIR=${AG_UNIT_DIR:-/etc/systemd/system}
DEST=${AG_DEST:-/opt/agentgram-bridge}
SYSTEMCTL=${AG_SYSTEMCTL:-systemctl}
RUN_USER=${AG_RUN_USER:-${SUDO_USER:-$(id -un)}}
RUN_HOME=$(getent passwd "$RUN_USER" | cut -d: -f6)
HERMES_HOME=${HERMES_HOME:-$RUN_HOME/.hermes}
ENV_FILE=$ETC/agentgram-bridge.env
UNIT=$UNIT_DIR/agentgram-bridge.service
HERE=$(cd "$(dirname "$0")" && pwd)

as_user() { if [ "$(id -un)" = "$RUN_USER" ]; then "$@"; else sudo -u "$RUN_USER" -H "$@"; fi; }
new_key() { python3 -c 'import base64,os;print(base64.b64encode(os.urandom(32)).decode())'; }
get() { [ ! -f "$ENV_FILE" ] || sed -n "s/^$1=//p" "$ENV_FILE" | head -1; }
show_key() {
  echo
  echo "Shared key (paste into AgentGram → Settings → Connect to Hermes, then keep it secret):"
  echo "  $(get AG_KEY)"
}

case "${1:-}" in
  --uninstall)
    $SYSTEMCTL disable --now agentgram-bridge.service || true
    rm -f "$UNIT" "$ENV_FILE"; rm -rf "$DEST"
    $SYSTEMCTL daemon-reload
    echo "Removed. Bridge state (groups, audit log) is kept in $HERMES_HOME/agentgram-bridge."
    exit 0 ;;
  --show-key)
    show_key; exit 0 ;;
  --rotate-key)
    [ -f "$ENV_FILE" ] || { echo "not installed" >&2; exit 1; }
    key=$(new_key)
    sed -i "s|^AG_KEY=.*|AG_KEY=$key|" "$ENV_FILE"
    $SYSTEMCTL restart agentgram-bridge.service
    show_key; exit 0 ;;
  --enable-api)
    env=$HERMES_HOME/.env
    if grep -q '^API_SERVER_KEY=..*' "$env" 2>/dev/null; then
      echo "API_SERVER_KEY already set in $env."
    else
      as_user sh -c "umask 077; printf 'API_SERVER_ENABLED=true\nAPI_SERVER_HOST=127.0.0.1\nAPI_SERVER_KEY=%s\n' \"\$(python3 -c 'import secrets;print(secrets.token_hex(32))')\" >> '$env'"
      echo "Wrote API_SERVER_ENABLED / API_SERVER_HOST / API_SERVER_KEY to $env."
    fi
    as_user env HERMES_HOME="$HERMES_HOME" "$(as_user sh -lc 'command -v hermes')" config set platforms.api_server.enabled true
    echo "The gateway must restart to start the API server. This interrupts every running agent turn."
    read -r -p "Restart hermes-gateway now? [y/N] " answer
    if [ "$answer" = y ] || [ "$answer" = Y ]; then
      $SYSTEMCTL restart hermes-gateway.service
      sleep 8
      if curl -fsS http://127.0.0.1:8642/health >/dev/null; then echo "API server is up on 127.0.0.1:8642."
      else echo "API server did not answer yet; check: journalctl -u hermes-gateway -n 50" >&2; fi
    else
      echo "Skipped. Run: sudo systemctl restart hermes-gateway"
    fi
    exit 0 ;;
  "") ;;
  *) sed -n '2,10p' "$0"; exit 1 ;;
esac

python3 -c 'import cryptography' 2>/dev/null || {
  echo "Installing python3-cryptography…"; apt-get install -y python3-cryptography; }
hermes_bin=$(as_user sh -lc 'command -v hermes') || { echo "hermes not found for user $RUN_USER" >&2; exit 1; }

token=${AG_BOT_TOKEN:-$(get AG_BOT_TOKEN)}
user_id=${AG_USER_ID:-$(get AG_USER_ID)}
[ -n "$token" ] || { read -r -s -p "Bridge bot token (from @BotFather): " token; echo; }
[ -n "$user_id" ] || read -r -p "Your numeric Telegram user id (ask @userinfobot): " user_id
case "$user_id" in ''|*[!0-9]*) echo "user id must be a number" >&2; exit 1 ;; esac
key=$(get AG_KEY); [ -n "$key" ] || key=$(new_key)

# Run from a git checkout, the bridge can update itself when the app asks (bridge.update:
# git pull --ff-only there, then replace its own file), so its user owns the installed copy.
# That user already runs the bridge and holds its key. Any other install stays root-owned
# and is updated by running this script again.
source_dir=$(as_user git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || true)
owner=$(id -un); [ -z "$source_dir" ] || owner=$RUN_USER
install -d -m 755 -o "$owner" "$DEST"
install -m 755 -o "$owner" "$HERE/bridge.py" "$DEST/bridge.py"
( umask 077; cat > "$ENV_FILE" <<EOF
AG_BOT_TOKEN=$token
AG_USER_ID=$user_id
AG_KEY=$key
HERMES_HOME=$HERMES_HOME
HERMES_BIN=$hermes_bin
AG_SOURCE=$source_dir
EOF
)
cat > "$UNIT" <<EOF
[Unit]
Description=AgentGram bridge bot for Hermes (outbound long polling only)
After=network-online.target hermes-gateway.service
Wants=network-online.target

[Service]
Type=simple
User=$RUN_USER
EnvironmentFile=$ENV_FILE
Environment=PATH=$(dirname "$hermes_bin"):/usr/local/bin:/usr/bin:/bin
ExecStart=/usr/bin/python3 $DEST/bridge.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
$SYSTEMCTL daemon-reload
$SYSTEMCTL enable agentgram-bridge.service
$SYSTEMCTL restart agentgram-bridge.service
echo "hermes-bridge is installed and running (journalctl -u agentgram-bridge -f)."
curl -fsS http://127.0.0.1:8642/health >/dev/null 2>&1 ||
  echo "Note: the Hermes API server is not answering on 127.0.0.1:8642; chat needs: sudo $0 --enable-api"
show_key
