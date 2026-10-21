#!/bin/bash
# First-boot setup for the Minecraft server (runs once via cloud-init as root).
# Installs Java, the Fabric server, performance + QoL mods, a systemd service,
# daily backups, and opens port 25565 in the OS firewall.
exec > >(tee -a /var/log/mc-setup.log) 2>&1
set -euxo pipefail

MC_DIR=/opt/minecraft
HEAP=8G

# --- OS basics -------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl wget gpg python3 tar zstd iptables-persistent apt-transport-https

# Oracle's Ubuntu image ships an iptables REJECT rule; allow Minecraft before it.
iptables -I INPUT 6 -m state --state NEW -p tcp --dport 25565 -j ACCEPT
netfilter-persistent save

# 2 GB swap as a safety net
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

useradd -r -m -d "$MC_DIR" -s /bin/bash minecraft || true
mkdir -p "$MC_DIR/mods" "$MC_DIR/backups" "$MC_DIR/config"

# --- Pick versions + download server and mods --------------------------------
cat > "$MC_DIR/pick_versions.py" <<'PY'
import json, urllib.request, urllib.parse, sys, os

UA = {"User-Agent": "MendiFAX/oracle-minecraft (setup script)"}
def get(url):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)
def download(url, path):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=300) as r, open(path, "wb") as f:
        f.write(r.read())

REQUIRED = ["fabric-api", "lithium", "ferrite-core", "easyauth"]
OPTIONAL = ["scalablelux", "c2me-fabric", "krypton", "spark", "chunky", "skinrestorer"]

def mod_file(slug, game, stable_only=False):
    q = urllib.parse.urlencode({"loaders": json.dumps(["fabric"]),
                                "game_versions": json.dumps([game])})
    try:
        vers = get(f"https://api.modrinth.com/v2/project/{slug}/version?{q}")
    except Exception as e:
        print("lookup failed", slug, e); return None
    rel = [v for v in vers if v.get("version_type") == "release"]
    if not rel and not stable_only:
        rel = vers
    if not rel: return None
    files = rel[0]["files"]
    f = next((x for x in files if x.get("primary")), files[0])
    return f["url"], f["filename"]

games = [g["version"] for g in get("https://meta.fabricmc.net/v2/versions/game") if g["stable"]][:12]
chosen = None
for g in games:
    if all(mod_file(s, g) for s in REQUIRED):
        chosen = g; break
if not chosen:
    sys.exit("No Minecraft version found with all required mods")
print("Chosen Minecraft version:", chosen)

mods_dir = sys.argv[1] + "/mods"
for s in REQUIRED + OPTIONAL:
    mf = mod_file(s, chosen, stable_only=s in OPTIONAL)
    if mf:
        url, name = mf
        print("downloading", s, name)
        download(url, os.path.join(mods_dir, name))
    else:
        print("skipping (not available for this version):", s)

loader = next(l["version"] for l in get("https://meta.fabricmc.net/v2/versions/loader") if l["stable"])
installer = next(i["version"] for i in get("https://meta.fabricmc.net/v2/versions/installer") if i["stable"])
download(f"https://meta.fabricmc.net/v2/versions/loader/{chosen}/{loader}/{installer}/server/jar",
         sys.argv[1] + "/fabric-server.jar")

manifest = get("https://piston-meta.mojang.com/mc/game/version_manifest_v2.json")
vurl = next(v["url"] for v in manifest["versions"] if v["id"] == chosen)
java = get(vurl).get("javaVersion", {}).get("majorVersion", 21)
open(sys.argv[1] + "/VERSION_INFO", "w").write(f"MC={chosen}\nJAVA={java}\nLOADER={loader}\n")
PY
python3 "$MC_DIR/pick_versions.py" "$MC_DIR"
# shellcheck disable=SC1091
. "$MC_DIR/VERSION_INFO"

# --- Java (Eclipse Temurin, the version this Minecraft release needs) --------
wget -qO - https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor -o /usr/share/keyrings/adoptium.gpg
echo "deb [signed-by=/usr/share/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb $(. /etc/os-release; echo "$VERSION_CODENAME") main" > /etc/apt/sources.list.d/adoptium.list
apt-get update -y
apt-get install -y "temurin-${JAVA}-jre" || apt-get install -y "temurin-${JAVA}-jdk"
JAVA_BIN=$(ls -d /usr/lib/jvm/temurin-${JAVA}-*/bin/java | head -1)

# --- Server config -----------------------------------------------------------
RCON_PASS=$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)
echo "eula=true" > "$MC_DIR/eula.txt"
cat > "$MC_DIR/server.properties" <<EOF
motd=\u00a7aServidor de Mendi \u00a77| Santiago
online-mode=false
enforce-secure-profile=false
max-players=20
difficulty=normal
view-distance=12
simulation-distance=8
sync-chunk-writes=false
network-compression-threshold=256
spawn-protection=0
enable-rcon=true
rcon.port=25575
rcon.password=${RCON_PASS}
broadcast-rcon-to-ops=false
white-list=false
EOF

# Tiny RCON client (RCON port is NOT opened to the internet, local use only)
cat > "$MC_DIR/rcon.py" <<'PY'
import socket, struct, sys, re
props = dict(l.strip().split("=", 1) for l in open("/opt/minecraft/server.properties") if "=" in l and not l.startswith("#"))
def pkt(i, t, body): d = struct.pack("<ii", i, t) + body.encode() + b"\x00\x00"; return struct.pack("<i", len(d)) + d
def recv(s):
    n = struct.unpack("<i", s.recv(4))[0]; d = b""
    while len(d) < n: d += s.recv(n - len(d))
    return d[8:-2].decode(errors="replace")
s = socket.create_connection(("127.0.0.1", int(props["rcon.port"])), timeout=10)
s.sendall(pkt(1, 3, props["rcon.password"])); recv(s)
for cmd in sys.argv[1:]:
    s.sendall(pkt(2, 2, cmd)); print(recv(s))
PY

# One-time gamerules once the world exists (old and new gamerule names; one will no-op)
cat > "$MC_DIR/first_start.sh" <<'EOF'
#!/bin/bash
[ -f /opt/minecraft/.rules_done ] && exit 0
for i in $(seq 1 60); do python3 /opt/minecraft/rcon.py "list" >/dev/null 2>&1 && break; sleep 10; done
python3 /opt/minecraft/rcon.py "gamerule playersSleepingPercentage 1" "gamerule minecraft:players_sleeping_percentage 1" \
  "gamerule players_sleeping_percentage 1" "chunky radius 2000" "chunky start" && touch /opt/minecraft/.rules_done
EOF
chmod +x "$MC_DIR/first_start.sh"

# Daily backup at 05:00 Chile time, keeps the last 7
cat > "$MC_DIR/backup.sh" <<'EOF'
#!/bin/bash
cd /opt/minecraft || exit 1
python3 rcon.py "save-off" "save-all flush" >/dev/null 2>&1; sleep 5
tar --zstd -cf "backups/world-$(date +%F).tar.zst" world world_nether world_the_end 2>/dev/null
python3 rcon.py "save-on" >/dev/null 2>&1
ls -1t backups/world-*.tar.zst | tail -n +8 | xargs -r rm -f
EOF
chmod +x "$MC_DIR/backup.sh"
timedatectl set-timezone America/Santiago || true
echo "0 5 * * * minecraft /opt/minecraft/backup.sh" > /etc/cron.d/minecraft-backup

chown -R minecraft:minecraft "$MC_DIR"

# --- systemd service (auto start on boot, auto restart on crash) -------------
cat > /etc/systemd/system/minecraft.service <<EOF
[Unit]
Description=Minecraft Fabric server
After=network-online.target
Wants=network-online.target

[Service]
User=minecraft
WorkingDirectory=$MC_DIR
ExecStart=$JAVA_BIN -Xms$HEAP -Xmx$HEAP -XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 \
 -XX:+UnlockExperimentalVMOptions -XX:+DisableExplicitGC -XX:+AlwaysPreTouch -XX:G1NewSizePercent=30 \
 -XX:G1MaxNewSizePercent=40 -XX:G1HeapRegionSize=8M -XX:G1ReservePercent=20 -XX:G1HeapWastePercent=5 \
 -XX:G1MixedGCCountTarget=4 -XX:InitiatingHeapOccupancyPercent=15 -XX:G1MixedGCLiveThresholdPercent=90 \
 -XX:G1RSetUpdatingPauseTimePercent=5 -XX:SurvivorRatio=32 -XX:+PerfDisableSharedMem -XX:MaxTenuringThreshold=1 \
 -jar fabric-server.jar nogui
ExecStartPost=+/bin/bash -c '/opt/minecraft/first_start.sh &'
Restart=always
RestartSec=10
SuccessExitStatus=0 143
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now minecraft.service
echo "SETUP DONE: Minecraft $MC on Java $JAVA" > /var/log/mc-setup.done
