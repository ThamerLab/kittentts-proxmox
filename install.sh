#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "Installation failed. Inspect the newly created CT before retrying." >&2' ERR
[[ "$EUID" == 0 ]] || { echo "Root required"; exit 1; }
for c in pct pveam pvesm pvesh; do command -v "$c" >/dev/null || exit 1; done
[[ "$(uname -m)" == "x86_64" ]] || { echo "x86-64 required"; exit 1; }
base="$(cd "$(dirname "$0")" && pwd)"
for f in setup-inside.sh requirements.txt app/main.py app/index.html; do [[ -f "$base/$f" ]] || { echo "Missing $f"; exit 1; }; done
ctid="$(pvesh get /cluster/nextid)"; hostname=kittentts; cores=4; memory=8192; disk=20; bridge=vmbr0
mapfile -t roots < <(pvesm status --content rootdir | awk 'NR>1 && $3=="active"{print $1}')
mapfile -t tpls < <(pvesm status --content vztmpl | awk 'NR>1 && $3=="active"{print $1}')
[[ -n "$roots" && -n "$tpls" ]] || { echo "Active rootdir and vztmpl storage required"; exit 1; }
root_storage="$roots"; tpl_storage="$tpls"
echo "KittenTTS Proxmox LXC installer (community beta)"
read -r -p "Advanced settings? [y/N] " advanced
if [[ "$advanced" == y || "$advanced" == Y ]]; then
 for field in ctid hostname cores memory disk root_storage tpl_storage bridge; do
  current="${!field}"
  read -r -p "$field [$current]: " value
  if [[ -n "$value" ]]; then printf -v "$field" '%s' "$value"; fi
 done
fi
[[ "$ctid" =~ ^[0-9]+$ && "$cores" =~ ^[0-9]+$ && "$memory" =~ ^[0-9]+$ && "$disk" =~ ^[0-9]+$ ]] || exit 1
((ctid>=100 && cores>=1 && memory>=4096 && disk>=12)) || { echo "Invalid resource allocation"; exit 1; }
[[ "$hostname" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ && "$bridge" =~ ^[a-zA-Z0-9_.-]+$ ]] || exit 1
[[ " ${roots[*]} " == *" $root_storage "* && " ${tpls[*]} " == *" $tpl_storage "* ]] || exit 1
[[ -d "/sys/class/net/$bridge/bridge" ]] || { echo "Missing network bridge"; exit 1; }
if pct status "$ctid" >/dev/null 2>&1; then echo "CT exists; aborting"; exit 1; fi
pveam update
mapfile -t templates < <(pveam available --section system | awk '$2 ~ /^debian-12-standard_.*amd64[.]tar/ {print $2}' | sort -V)
[[ -n "$templates" ]] || { echo "Debian 12 template unavailable"; exit 1; }
template="$(printf '%s\n' "${templates[@]}" | tail -1)"
pveam list "$tpl_storage" | grep -Fq "vztmpl/$template" || pveam download "$tpl_storage" "$template"
pct create "$ctid" "$tpl_storage:vztmpl/$template" --hostname "$hostname" --ostype debian --unprivileged 1 --cores "$cores" --memory "$memory" --swap 1024 --rootfs "$root_storage:$disk" --net0 "name=eth0,bridge=$bridge,ip=dhcp" --onboot 1
pct start "$ctid"
ok=0
for i in $(seq 1 60); do
 if pct exec "$ctid" -- getent hosts deb.debian.org >/dev/null 2>&1; then ok=1; break; fi
 sleep 3
done
((ok)) || { echo "CT has no working DNS"; exit 1; }
archive="$(mktemp --suffix=.tar.gz)"
trap 'rm -f "$archive"' EXIT
tar -C "$base" -czf "$archive" app requirements.txt setup-inside.sh
pct push "$ctid" "$archive" /root/kitten.tar.gz
pct exec "$ctid" -- bash -c 'mkdir -p /opt/kittentts-home; tar -xzf /root/kitten.tar.gz -C /opt/kittentts-home; bash /opt/kittentts-home/setup-inside.sh; rm -f /root/kitten.tar.gz'
ip="$(pct exec "$ctid" -- hostname -I | awk '{print $1}')"
echo "Installed CT $ctid -> http://$ip:8787"
echo "Manage: pct enter $ctid; kittentts-ctl"
echo "Do not directly expose port 8787 to the internet."
