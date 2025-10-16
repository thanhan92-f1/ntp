#!/bin/bash
# =========================================
# NTP / Multichronyd Installer & Manager
# Full Install / Uninstall / Hot-Reload / Reset
# =========================================

CONFIG_FILE="/etc/multichronyd.conf"
SERVICE_FILE="/etc/systemd/system/multichronyd.service"
SCRIPT_FILE="/root/multichronyd.sh"

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

echo "### MULTICHRONYD INSTALLER & MANAGER ###"
echo "Choose an option:"
echo "1) Install / Reinstall (reset chrony config)"
echo "2) Uninstall Multichronyd only"
echo "3) Uninstall Multichronyd + chrony/NTP completely"
echo "4) Change number of cores (server instances)"
read -p "Enter choice [1-4]: " CHOICE

case "$CHOICE" in
1)
    # ---------------- Install / Reinstall ----------------
    read -p "Enter number of chronyd server instances to run (1 recommended for high-core VPS): " NUM
    NUM=${NUM:-1}
    echo "$NUM" > "$CONFIG_FILE"

    echo "### Installing chrony and inotify-tools... ###"
    apt update
    apt install -y chrony inotify-tools

    # Stop default chrony service
    systemctl stop chrony.service
    systemctl disable chrony.service

    # Remove old config/log/drift/pid/sock
    echo "Cleaning old chrony/multichronyd data..."
    rm -f /etc/chrony/chrony.conf /etc/chrony/chrony.conf.bak
    rm -f /var/lib/chrony/chrony.drift
    rm -rf /var/log/chrony
    rm -rf /var/run/chrony
    mkdir -p /var/run/chrony
    chmod 1777 /var/run/chrony
    chown root:root /var/run/chrony

    # Create new chrony.conf
    cat << 'EOF' > /etc/chrony/chrony.conf
server time.cloudflare.com iburst
server time.aws.com iburst
server time.google.com iburst
server time.nist.gov iburst
server time.facebook.com iburst
server time.apple.com iburst
server clock.sjc.he.net iburst
server clock.fmt.he.net iburst
server 1.ntp.vnix.vn iburst
server 2.ntp.vnix.vn iburst
server ntp.nict.jp iburst
server ntp.ntsc.ac.cn iburst
server ntp.sgix.sg iburst
server time.stdtime.gov.tw iburst
server time.kriss.re.kr iburst
server ntp.hko.hk iburst
server ntp.aarnet.edu.au iburst
allow
driftfile /var/lib/chrony/chrony.drift
keyfile /etc/chrony/chrony.keys
logdir /var/log/chrony
rtcsync
makestep 1.0 3
sched_priority 1
EOF

    # Create multichronyd script
    cat << 'EOF' > "$SCRIPT_FILE"
#!/bin/bash
CONFIG_FILE="/etc/multichronyd.conf"
CHRONYD="/usr/sbin/chronyd"

mkdir -p /var/run/chrony
chmod 1777 /var/run/chrony
chown root:root /var/run/chrony

log() { echo "[`date '+%F %T'`] $*"; }
declare -A PID_MAP

start_client() {
    "$CHRONYD" -n include /etc/chrony/chrony.conf port 11123 bindaddress 127.0.0.1 sched_priority 1 allow 127.0.0.1 &
    CLIENT_PID=$!
    log "Client instance started: PID $CLIENT_PID"
}

start_server() {
    local i=$1
    "$CHRONYD" -x -n \
        "server 127.0.0.1 port 11123 minpoll 0 maxpoll 0" \
        "allow" \
        "cmdport 0" \
        "bindcmdaddress /var/run/chrony/chronyd-server$i.sock" \
        "pidfile /var/run/chrony/chronyd-server$i.pid" &
    PID_MAP[$i]=$!
    sleep 0.5
    chmod 777 /var/run/chrony/chronyd-server$i.sock
    log "Server instance #$i started: PID ${PID_MAP[$i]}"
}

stop_server() {
    local i=$1
    local pidfile="/var/run/chrony/chronyd-server$i.pid"
    if [ -f "$pidfile" ]; then
        pid=$(cat "$pidfile")
        kill "$pid" 2>/dev/null
        rm -f "$pidfile" "/var/run/chrony/chronyd-server$i.sock"
        log "Server instance #$i stopped"
        unset PID_MAP[$i]
    fi
}

start_client

NUM_SERVERS=$(cat "$CONFIG_FILE" 2>/dev/null)
NUM_SERVERS=${NUM_SERVERS:-1}
for i in $(seq 1 "$NUM_SERVERS"); do
    start_server $i
done

while inotifywait -e modify "$CONFIG_FILE" >/dev/null 2>&1; do
    NEW_NUM=$(cat "$CONFIG_FILE" 2>/dev/null)
    if [ "$NEW_NUM" != "$NUM_SERVERS" ]; then
        log "Config change detected: $NUM_SERVERS -> $NEW_NUM"
        if [ "$NEW_NUM" -gt "$NUM_SERVERS" ]; then
            for i in $(seq $((NUM_SERVERS+1)) "$NEW_NUM"); do
                start_server $i
            done
        else
            for i in $(seq $((NEW_NUM+1)) "$NUM_SERVERS"); do
                stop_server $i
            done
        fi
        NUM_SERVERS=$NEW_NUM
    fi
done
EOF

    chmod +x "$SCRIPT_FILE"

    # Create systemd service
    cat << 'EOF' > "$SERVICE_FILE"
[Unit]
Description=Custom Chronyd Service Manager with Immediate Hot-Reload
After=network.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/root
ExecStart=/root/multichronyd.sh
Restart=always
RestartSec=5s
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable multichronyd.service
    systemctl restart multichronyd.service

    echo "### Immediate Hot-Reload multichronyd installed! ###"
    echo "Check status: systemctl status multichronyd.service"
    echo "Change number of server instances instantly: echo <num> > /etc/multichronyd.conf"
    ;;
2)
    # ---------------- Uninstall Multichronyd only ----------------
    echo "Stopping service..."
    systemctl stop multichronyd.service
    systemctl disable multichronyd.service
    rm -f "$SERVICE_FILE" "$SCRIPT_FILE" "$CONFIG_FILE"
    echo "Multichronyd uninstalled successfully."
    ;;
3)
    # ---------------- Uninstall Multichronyd + chrony/NTP completely ----------------
    echo "Stopping service..."
    systemctl stop multichronyd.service
    systemctl disable multichronyd.service
    rm -f "$SERVICE_FILE" "$SCRIPT_FILE" "$CONFIG_FILE"
    echo "Removing chrony and inotify-tools packages..."
    apt remove -y chrony inotify-tools
    apt autoremove -y
    echo "Removing all chrony data..."
    rm -f /etc/chrony/chrony.conf /etc/chrony/chrony.conf.bak
    rm -f /var/lib/chrony/chrony.drift
    rm -rf /var/log/chrony
    rm -rf /var/run/chrony
    echo "Multichronyd + chrony/NTP uninstalled completely."
    ;;
4)
    # ---------------- Change cores ----------------
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Multichronyd is not installed yet."
        exit 1
    fi
    read -p "Enter new number of server instances: " NUM
    NUM=${NUM:-1}
    echo "$NUM" > "$CONFIG_FILE"
    systemctl restart multichronyd.service
    echo "Server instances updated and service restarted."
    ;;
*)
    echo "Invalid choice."
    exit 1
    ;;
esac
