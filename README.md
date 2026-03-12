# Lave a telegram-bot

## System-dækkende Arch-guide: Telegram-bot der poster til gruppe(r) efter en tidsplan

## Antagelser

- Den gamle laptop kører **Arch Linux**, har internet og er tændt/online.

- Du vil have en **bot** (ikke en bruger-klient), der poster til én eller flere **grupper**.

- Alt er **system-dækkende**: `/opt`, `/etc`, `systemd`-timer.

---


## 1) Installation af programmer som det hele afhænger af

```bash
sudo pacman -Syu
```

## 2) Ven (Telegram) opretter bot + tilføjer den til grupper

### 2.1 Opret bot (BotFather)

* Telegram → @BotFather → /newbot → få BOT_TOKEN.

## 2.2 Tilføj bot til hver målgruppe

* Gruppe → “Tilføj medlem” → @YourBot

* Hvis gruppen er “kun admins må poste”: **gør botten til admin** med _rettighed til at poste beskeder_.

## 3) Placér scripts + konfiguration i systemstier

```bash
sudo mkdir -p /opt/tg-scheduler
sudo chmod 0755 /opt/tg-scheduler
```

## 4) Gem bot-token i en system env-fil (ingen manuel sourcing nødvendig)

```bash
sudo tee /etc/tg-bot.env >/dev/null <<'EOF'
TELEGRAM_BOT_TOKEN=PASTE_TOKEN_HERE
TG_TARGETS=/opt/tg-scheduler/targets.json
EOF
sudo chmod 0600 /etc/tg-bot.env
```

Bemærk: Filen **behøver ikke** at blive `source` manuelt, fordi **systemd læser den via `EnvironmentFil**e=`....

```bash
sudo tee /opt/tg-scheduler/targets.json >/dev/null <<'EOF'
{
  "message": "Reminder: do the thing.",
  "chat_ids": []
}
EOF
sudo chmod 0644 /opt/tg-scheduler/targets.json
```

## 6) Engangsstep: find gruppers `chat_id-værdier`

### 6.1 Opret “listener”-script

```bash
sudo tee /opt/tg-scheduler/tg-listen-ids.py >/dev/null <<'EOF'
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
               allowed_updates='[\"message\"]')
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
sudo chmod 0755 /opt/tg-scheduler/tg-listen-ids.py
```

### 6.2 Kør listener (midlertidigt)


```bash
sudo bash -lc 'set -a; source /etc/tg-bot.env; set +a; /usr/bin/python /opt/tg-scheduler/tg-listen-ids.py'
```

### 6.3 Ven-handling (i hver gruppe)

* Send i gruppen:
* * `/id@YourBotUsername` (mere sikkert end `/id`, hvis privacy mode er slået til)
* Kopiér de printede `CHAT_ID=...-tal`.
* Stop listener med `Ctrl+C`.

### 6.4 Indsæt chat-IDs i JSON

```bash
sudoedit /opt/tg-scheduler/targets.json
```

Eksempel:

```json
{
  "message": "Sten sælges for lav pris: 1 pose (1g) 600.",
  "chat_ids": [-1001234567890, -1002222222222]
}
```

## 7) Opret sender-script (det er dette, systemd kører)

```bash
sudo tee /opt/tg-scheduler/tg-send.py >/dev/null <<'EOF'
#!/usr/bin/env python3
import json, os, sys, requests

TOKEN = os.environ["TELEGRAM_BOT_TOKEN"].strip()
TARGETS = os.environ.get("TG_TARGETS", "/opt/tg-scheduler/targets.json")
API = f"https://api.telegram.org/bot{TOKEN}"

def send(chat_id: int, text: str) -> None:
  r = requests.post(f"{API}/sendMessage",
                    data={"chat_id": str(chat_id), "text": text},
                    timeout=30)
  r.raise_for_status()
  j = r.json()
  if not j.get("ok"):
    raise RuntimeError(j)

with open(TARGETS, "r", encoding="utf-8") as f:
  cfg = json.load(f)

msg = cfg["message"]
chat_ids = cfg["chat_ids"]

failed = 0
for cid in chat_ids:
  try:
    send(int(cid), msg)
  except Exception as e:
    failed += 1
    print(f"[ERR] chat_id={cid}: {e}", file=sys.stderr)

raise SystemExit(1 if failed else 0)
EOF
sudo chmod 0755 /opt/tg-scheduler/tg-send.py
```

## 8) Opret systemd service + timer (styrer hvor ofte botten poster)

### 8.1 Service: `/etc/systemd/system/tg-send.service

```bash
sudo tee /etc/systemd/system/tg-send.service >/dev/null <<'EOF'
[Unit]
Description=Telegram scheduled sender
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/tg-bot.env
WorkingDirectory=/opt/tg-scheduler
ExecStart=/usr/bin/python /opt/tg-scheduler/tg-send.py
EOF
```

### 8.2 Timer: vælg én tidsplan

**A) Hver 30. minut**

```bash
sudo tee /etc/systemd/system/tg-send.timer >/dev/null <<'EOF'
[Unit]
Description=Run Telegram sender every 30 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF
```

**B) Dagligt kl. 08:00**

```bash
sudo tee /etc/systemd/system/tg-send.timer >/dev/null <<'EOF'
[Unit]
Description=Run Telegram sender daily 08:00

[Timer]
OnCalendar=*-*-* 08:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
```

**Aktivér:**

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now tg-send.timer
```

## 9) Test + overvåg

Kør én gang med det samme:


```bash
sudo systemctl start tg-send.service
```

Logs:

```bash
sudo journalctl -u tg-send.service -n 100 --no-pager
```

Timer-plan:

```bash
systemctl list-timers --all | rg tg-send
```

## 10) Ændr besked / grupper / frekvens senere

* **Besked eller grupper**: redigér kun json

```bash
sudoedit /opt/tg-scheduler/targets.json
```

* **Frekvens**: redigér timeren:

```bash
sudoedit /etc/systemd/system/tg-send.timer
sudo systemctl daemon-reload
sudo systemctl restart tg-send.timer
```

## 11) Token-rotation (overdragelseshygiejne)

* Vennen roterer token i `@BotFather`
* Opdatér `/etc/tg-bot.env`
* Test én gang

```bash
sudo systemctl start tg-send.service
```

Dette er den minimale, reboot-sikre og “venne-sikre” system-dækkende deployment.
