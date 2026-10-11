#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends python3 python3-venv python3-pip python3-dev build-essential git curl ca-certificates libsndfile1 ffmpeg libgomp1 openssl nano
id kitten >/dev/null 2>&1 || useradd --system --home /var/lib/kittentts --shell /usr/sbin/nologin kitten
install -d -m 0755 -o kitten -g kitten /var/lib/kittentts /var/lib/kittentts/cache
chown -R root:root /opt/kittentts-home
python3 -m venv /opt/kittentts-home/.venv
/opt/kittentts-home/.venv/bin/python -m pip install --upgrade pip
/opt/kittentts-home/.venv/bin/pip install -r /opt/kittentts-home/requirements.txt
if [[ ! -f /etc/kittentts.env ]]; then
 key="$(openssl rand -hex 24)"
 printf 'MODEL_ID=KittenML/kitten-tts-2\nMODEL_WEIGHTS=emb4\nOMP_NUM_THREADS=4\nMAX_TEXT_CHARS=2000\nHF_HOME=/var/lib/kittentts/cache\nAPI_KEY=%s\n' "$key" > /etc/kittentts.env
 chmod 0600 /etc/kittentts.env
fi
cat > /etc/systemd/system/kittentts.service <<'UNIT'
[Unit]
Description=KittenTTS Home API
After=network-online.target
Wants=network-online.target
[Service]
User=kitten
Group=kitten
WorkingDirectory=/opt/kittentts-home
EnvironmentFile=/etc/kittentts.env
ExecStart=/opt/kittentts-home/.venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8787 --workers 1
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/var/lib/kittentts
[Install]
WantedBy=multi-user.target
UNIT
cat > /usr/local/bin/kittentts-ctl <<'CTL'
#!/usr/bin/env bash
[[ "$EUID" == 0 ]] || { echo "Root required"; exit 1; }
while :; do
 echo "1) Status 2) Logs 3) Restart 4) Edit settings 5) Update dependencies 6) API key 7) Exit"
 read -r -p "> " choice
 case "$choice" in
 1) systemctl status kittentts --no-pager || :;;
 2) journalctl -u kittentts -f;;
 3) systemctl restart kittentts;;
 4) nano /etc/kittentts.env; systemctl restart kittentts;;
 5) /opt/kittentts-home/.venv/bin/pip install -U -r /opt/kittentts-home/requirements.txt; systemctl restart kittentts;;
 6) grep '^API_KEY=' /etc/kittentts.env;;
 7) exit;;
 *) echo "Invalid option";;
 esac
done
CTL
chmod 0755 /usr/local/bin/kittentts-ctl
systemctl daemon-reload
systemctl enable --now kittentts
echo "KittenTTS service installed. First synthesis downloads the model."
