#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# tg-bot-manage  (Arch, system-wide)
# ------------------------------------------------------------------------------
# Manage a Telegram Bot API "scheduled poster" with:
#   - systemd system service + timer
#   - /etc/tg-bot.env (token + targets path)
#   - /opt/tg-scheduler/targets.json (message + chat_ids + parse_mode)
#
# No venv. No pip. Uses Arch packages: python + python-requests.
#
# Usage:
#   sudo tg-bot-manage                 # interactive menu
#   sudo tg-bot-manage --help
#   sudo tg-bot-manage install
#   sudo tg-bot-manage listen-ids
#   sudo tg-bot-manage set-token '123:ABC...'
#   sudo tg-bot-manage set-interval 30min
#   sudo tg-bot-manage set-daily "08:00" "16:30"
#   sudo tg-bot-manage test
#   sudo tg-bot-manage status
#
# Mentioning users in messages:
#   - simplest (if user has a public username): @username
#   - robust (works without username): HTML mention:
#       <a href="tg://user?id=123456789">Name</a>
#     This script defaults targets.json parse_mode to "HTML".
# ==============================================================================

function die() { echo "ERROR: $*" >&2; exit 1; }
function need_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "run as root (sudo)."; }
function have() { command -v "$1" >/dev/null 2>&1; }

TG_DIR="/opt/tg-scheduler"
ENV_FILE="/etc/tg-bot.env"
TARGETS_JSON="${TG_DIR}/targets.json"
SEND_PY="${TG_DIR}/tg-send.py"
LISTEN_PY="${TG_DIR}/tg-listen-ids.py"
SVC="/etc/systemd/system/tg-send.service"
TMR="/etc/systemd/system/tg-send.timer"

function ensure_deps() {
  if ! have pacman; then
    die "This script targets Arch Linux (pacman not found)."
  fi
  pacman -Syu --needed --noconfirm python python-requests >/dev/null
}

function write_env_file() {
  local token="${1:-}"
  [[ -n "$token" ]] || die "token is empty."
  umask 077
  cat > "$ENV_FILE" <<EOF
TELEGRAM_BOT_TOKEN=${token}
TG_TARGETS=${TARGETS_JSON}
EOF
  chmod 0600 "$ENV_FILE"
}

function read_token_from_env() {
  [[ -f "$ENV_FILE" ]] || return 1
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]] || return 1
  printf '%s' "$TELEGRAM_BOT_TOKEN"
}

function ensure_targets_json() {
  mkdir -p "$TG_DIR"
  chmod 0755 "$TG_DIR"
  if [[ ! -f "$TARGETS_JSON" ]]; then
    cat > "$TARGETS_JSON" <<'EOF'
{
  "message": "Reminder: replace this message.",
  "chat_ids": [],
  "parse_mode": "HTML"
}
EOF
    chmod 0644 "$TARGETS_JSON"
  fi
}

function write_send_py() {
  cat > "$SEND_PY" <<'EOF'
#!/usr/bin/env python3
import json, os, sys, requests

TOKEN = os.environ["TELEGRAM_BOT_TOKEN"].strip()
TARGETS = os.environ.get("TG_TARGETS", "/opt/tg-scheduler/targets.json")
API = f"https://api.telegram.org/bot{TOKEN}"

def send(chat_id: int, text: str, parse_mode: str | None) -> None:
  data = {"chat_id": str(chat_id), "text": text}
  if parse_mode:
    data["parse_mode"] = parse_mode
  r = requests.post(f"{API}/sendMessage", data=data, timeout=30)
  r.raise_for_status()
  j = r.json()
  if not j.get("ok"):
    raise RuntimeError(j)

with open(TARGETS, "r", encoding="utf-8") as f:
  cfg = json.load(f)

msg = cfg.get("message", "")
parse_mode = cfg.get("parse_mode") or None
chat_ids = cfg.get("chat_ids", [])

if not isinstance(msg, str) or not msg.strip():
  raise SystemExit("targets.json: 'message' must be a non-empty string")
if not isinstance(chat_ids, list) or not chat_ids:
  raise SystemExit("targets.json: 'chat_ids' must be a non-empty list")

failed = 0
for cid in chat_ids:
  try:
    send(int(cid), msg, parse_mode)
  except Exception as e:
    failed += 1
    print(f"[ERR] chat_id={cid}: {e}", file=sys.stderr)

raise SystemExit(1 if failed else 0)
EOF
  chmod 0755 "$SEND_PY"
}

function write_listen_py() {
  cat > "$LISTEN_PY" <<'EOF'
#!/usr/bin/env python3
import os, time, requests

TOKEN = os.environ["TELEGRAM_BOT_TOKEN"].strip()
API = f"https://api.telegram.org/bot{TOKEN}"

def tg(method, http="GET", **params):
  if http == "GET":
    r = requests.get(f"{API}/{method}", params=params, timeout=70)
  else:
    r = requests.post(f"{API}/{method}", data=params, timeout=30)
  r.raise_for_status()
  j = r.json()
  if not j.get("ok"):
    raise RuntimeError(j)
  return j["result"]

offset = None
seen = set()

print("In each target group, send: /id@YourBotUsername")
while True:
  updates = tg("getUpdates", timeout=30, offset=offset,
               allowed_updates='["message"]')
  for u in updates:
    offset = u["update_id"] + 1
    m = u.get("message") or {}
    text = (m.get("text") or "").strip()
    chat = m.get("chat") or {}
    chat_id = chat.get("id")
    title = chat.get("title") or chat.get("username") or ""
    msg_id = m.get("message_id")
    if not isinstance(chat_id, int):
      continue
    if text.startswith("/id"):
      key = (chat_id, title)
      if key not in seen:
        seen.add(key)
        print(f"CHAT_ID={chat_id}  TITLE={title!r}")
      tg("sendMessage", http="POST",
         chat_id=str(chat_id),
         text=f"chat_id = {chat_id}",
         reply_to_message_id=str(msg_id) if isinstance(msg_id, int) else None)
  time.sleep(0.2)
EOF
  chmod 0755 "$LISTEN_PY"
}

function write_systemd_service() {
  cat > "$SVC" <<EOF
[Unit]
Description=Telegram scheduled sender
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=${ENV_FILE}
WorkingDirectory=${TG_DIR}
ExecStart=/usr/bin/python ${SEND_PY}
EOF
}

function write_timer_interval() {
  local interval="$1"
  [[ -n "$interval" ]] || die "interval empty (e.g. 30min, 1h)."
  cat > "$TMR" <<EOF
[Unit]
Description=Run Telegram sender every ${interval}

[Timer]
OnBootSec=2min
OnUnitActiveSec=${interval}
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

function write_timer_daily() {
  shift 0 || true
  local times=("$@")
  [[ "${#times[@]}" -ge 1 ]] || die "need at least one time like 08:00"
  {
    echo "[Unit]"
    echo "Description=Run Telegram sender daily at ${times[*]}"
    echo
    echo "[Timer]"
    for t in "${times[@]}"; do
      [[ "$t" =~ ^[0-2][0-9]:[0-5][0-9]$ ]] || die "bad time: $t"
      echo "OnCalendar=*-*-* ${t}:00"
    done
    echo "Persistent=true"
    echo
    echo "[Install]"
    echo "WantedBy=timers.target"
  } > "$TMR"
}

function systemd_reload_enable() {
  systemctl daemon-reload
  systemctl enable --now tg-send.timer
}

function editor_edit() {
  local path="$1"
  local ed="${SUDO_EDITOR:-${EDITOR:-}}"
  if [[ -z "$ed" ]]; then
    if have nano; then ed="nano"
    elif have vim; then ed="vim"
    elif have vi; then ed="vi"
    else die "No editor set and none of nano/vim/vi found."
    fi
  fi
  "$ed" "$path"
}

function json_set_message_prompt() {
  echo "Enter message (single line). For HTML mention:"
  echo "  <a href=\"tg://user?id=123456789\">Name</a>"
  echo "Or @username if they have one."
  printf "> "
  IFS= read -r msg || true
  [[ -n "$msg" ]] || die "message empty."
  python - "$TARGETS_JSON" "$msg" <<'PY'
import json, sys
p, msg = sys.argv[1], sys.argv[2]
with open(p,"r",encoding="utf-8") as f: cfg=json.load(f)
cfg["message"]=msg
cfg.setdefault("parse_mode","HTML")
with open(p,"w",encoding="utf-8") as f: json.dump(cfg,f,indent=2)
print("Updated message.")
PY
}

function json_set_chat_ids_prompt() {
  echo "Paste chat_ids as comma-separated integers."
  echo "Example: -1001234567890, -1007778889990"
  printf "> "
  IFS= read -r line || true
  [[ -n "$line" ]] || die "empty input."
  python - "$TARGETS_JSON" "$line" <<'PY'
import json, sys, re
p, line = sys.argv[1], sys.argv[2]
ids=[]
for part in line.split(","):
  s=part.strip()
  if not s: continue
  if not re.fullmatch(r"-?\d+", s):
    raise SystemExit(f"Bad chat_id: {s!r}")
  ids.append(int(s))
if not ids:
  raise SystemExit("No valid chat_ids provided.")
with open(p,"r",encoding="utf-8") as f: cfg=json.load(f)
cfg["chat_ids"]=ids
with open(p,"w",encoding="utf-8") as f: json.dump(cfg,f,indent=2)
print("Updated chat_ids:", ids)
PY
}

function run_listen_ids() {
  [[ -f "$ENV_FILE" ]] || die "Missing $ENV_FILE (set token first)."
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]] || die "token missing in env file."
  /usr/bin/python "$LISTEN_PY"
}

function run_test_send() {
  systemctl start tg-send.service
  journalctl -u tg-send.service -n 80 --no-pager
}

function show_status() {
  systemctl status tg-send.timer --no-pager || true
  systemctl status tg-send.service --no-pager || true
  systemctl list-timers --all | sed -n '1,3p'
  systemctl list-timers --all | grep -F "tg-send" || true
}

function do_install() {
  ensure_deps
  ensure_targets_json
  write_send_py
  write_listen_py
  write_systemd_service
  if [[ ! -f "$TMR" ]]; then
    write_timer_interval "30min"
  fi
  systemd_reload_enable
}

function print_help() {
  cat <<'EOF'
tg-bot-manage (Arch, system-wide)

Friend (phone):
  1) @BotFather -> /newbot -> get BOT_TOKEN
  2) Add bot to groups; if needed, make bot admin to post.

You (Arch laptop):
  sudo tg-bot-manage install
  sudo tg-bot-manage set-token '123:ABC...'
  sudo tg-bot-manage listen-ids   # then in each group send /id@YourBotUsername
  sudo tg-bot-manage set-chat-ids # paste ids into prompt
  sudo tg-bot-manage set-message  # set message (HTML mentions supported)
  sudo tg-bot-manage set-interval 30min | 10min | 1h
  sudo tg-bot-manage set-daily 08:00 16:30
  sudo tg-bot-manage test
  sudo tg-bot-manage status

Notes:
  - No Telegram Desktop needed on the laptop.
  - Message mentions:
      @username
    or (HTML, robust):
      <a href="tg://user?id=123456789">Name</a>
EOF
}

function menu() {
  echo
  echo "tg-bot-manage (system-wide)"
  echo " 1) install (deps + scripts + service/timer)"
  echo " 2) set token"
  echo " 3) listen for group chat_ids (/id@BotUsername)"
  echo " 4) set chat_ids (paste comma-separated)"
  echo " 5) set message"
  echo " 6) set schedule: interval"
  echo " 7) set schedule: daily times"
  echo " 8) apply/reload + enable timer"
  echo " 9) test send now"
  echo "10) status/logs"
  echo " 0) exit"
  echo
  printf "Select> "
  local choice
  IFS= read -r choice || true
  case "${choice:-}" in
    1) do_install ;;
    2)
      printf "Paste BOT_TOKEN> "
      local tok; IFS= read -r tok || true
      write_env_file "$tok"
      echo "Wrote $ENV_FILE"
      ;;
    3) run_listen_ids ;;
    4) json_set_chat_ids_prompt ;;
    5) json_set_message_prompt ;;
    6)
      printf "Interval (e.g. 30min, 10min, 1h)> "
      local itv; IFS= read -r itv || true
      write_timer_interval "$itv"
      echo "Wrote $TMR"
      ;;
    7)
      echo "Enter daily times separated by spaces (HH:MM), e.g.: 08:00 16:30"
      printf "> "
      local line; IFS= read -r line || true
      # shellcheck disable=SC2206
      local arr=($line)
      write_timer_daily "${arr[@]}"
      echo "Wrote $TMR"
      ;;
    8) systemd_reload_enable ;;
    9) run_test_send ;;
    10) show_status ;;
    0) exit 0 ;;
    *) echo "Invalid choice." ;;
  esac
}

function main() {
  need_root
  local cmd="${1:-}"
  case "$cmd" in
    "" ) while true; do menu; done ;;
    -h|--help ) print_help ;;
    install ) do_install ;;
    set-token )
      shift; write_env_file "${1:-}"; echo "Wrote $ENV_FILE" ;;
    listen-ids ) run_listen_ids ;;
    edit-targets ) editor_edit "$TARGETS_JSON" ;;
    set-message ) json_set_message_prompt ;;
    set-chat-ids ) json_set_chat_ids_prompt ;;
    set-interval )
      shift; write_timer_interval "${1:-}"; systemd_reload_enable ;;
    set-daily )
      shift; write_timer_daily "$@"; systemd_reload_enable ;;
    apply ) systemd_reload_enable ;;
    test ) run_test_send ;;
    status ) show_status ;;
    * ) die "unknown command: $cmd (use --help)" ;;
  esac
}

main "$@"
