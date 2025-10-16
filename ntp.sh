#!/bin/bash

# This script must be run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

echo "### Step 1: Checking for and stopping existing Chrony services... ###"
if systemctl is-active --quiet multichronyd.service; then
    echo "An existing multichronyd.service is active. Stopping it now..."
    systemctl disable multichronyd.service
fi
if systemctl is-active --quiet chrony.service; then
    echo "The default chrony.service is active. Stopping it now..."
    systemctl disable chrony.service
fi

echo
echo "### Step 2: Configure CPU core usage ###"
TOTAL_CORES=$(nproc)
while true; do
    read -p "Enter the number of CPU cores to use (1-${TOTAL_CORES}, default: ${TOTAL_CORES}): " CPU_CORES
    CPU_CORES=${CPU_CORES:-$TOTAL_CORES}
    if [[ "$CPU_CORES" =~ ^[1-9][0-9]*$ ]] && [ "$CPU_CORES" -le "$TOTAL_CORES" ]; then
        echo "Configuration accepted. Will use $CPU_CORES core(s)."
        break
    else
        echo "Invalid input. Please enter a number between 1 and ${TOTAL_CORES}."
    fi
done

echo
echo "### Step 3: Updating packages and installing Chrony... ###"
apt update
apt install -y chrony

echo
echo "### Step 4: Configuring Chrony... ###"
# The chrony.conf part remains the same
cat << 'EOF' > /etc/chrony/chrony.conf
# ---- BEST PRACTICE UPDATE ----
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
sourcedir /run/chrony-dhcp
sourcedir /etc/chrony/sources.d
keyfile /etc/chrony/chrony.keys
driftfile /var/lib/chrony/chrony.drift
ntsdumpdir /var/lib/chrony
logdir /var/log/chrony
maxupdateskew 100.0
rtcsync
makestep 1.0 3
sched_priority 1
EOF

echo
echo "### Step 5: Disabling the default Chrony service to prevent conflicts... ###"
systemctl disable chrony.service > /dev/null 2>&1

echo
echo "### Step 6: Creating the FIXED multichronyd.sh script in /root... ###"
cat << EOF > /root/multichronyd.sh
#!/bin/bash

servers=${CPU_CORES}
chronyd="/usr/sbin/chronyd"

trap terminate SIGINT SIGTERM

terminate()
{
  for p in /var/run/chrony/chronyd*.pid; do
    pid=\$(cat "\$p" 2> /dev/null)
    [[ "\$pid" =~ [0-9]+ ]] && kill "\$pid"
  done
}

conf=""
for c in /etc/chrony.conf /etc/chrony/chrony.conf; do
  [ -f "\$c" ] && conf=\$c
done

case "\$(\"\$chronyd\" --version | grep -o -E '[1-9]\.[0-9]+')" in
  1.*|2.*|3.*)
    echo "chrony version too old to run multiple instances"
    exit 1;;
  4.0)  opts="";;
  4.1)  opts="xleave copy";;
  *)  opts="xleave copy extfield F323";;
esac

mkdir -p /var/run/chrony

for i in \$(seq 1 "\$servers"); do
  echo "Starting server instance #\$i"
  "\$chronyd" "\$@" -n -x \\
    "server 127.0.0.1 port 11123 minpoll 0 maxpoll 0 \$opts" \\
    "allow" \\
    "cmdport 0" \\
    "bindcmdaddress /var/run/chrony/chronyd-server\$i.sock" \\
    "pidfile /var/run/chrony/chronyd-server\$i.pid" &
done

echo "Starting client instance"
"\$chronyd" "\$@" -n \\
  "include \$conf" \\
  "pidfile /var/run/chrony/chronyd-client.pid" \\
  "port 11123" \\
  "bindaddress 127.0.0.1" \\
  "sched_priority 1" \\
  "allow 127.0.0.1" &

wait

echo Exiting
EOF

echo "### Step 7: Making the script executable... ###"
chmod +x /root/multichronyd.sh

echo
echo "### Step 8: Creating the systemd service file... ###"
cat << 'EOF' > /etc/systemd/system/multichronyd.service
[Unit]
Description=Custom Chronyd Service Manager
After=network.target

[Service]
User=root
Group=root
WorkingDirectory=/root
ExecStart=/root/multichronyd.sh
Restart=always
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF

echo
echo "### Step 9: Enabling and starting the new multichronyd service... ###"
systemctl daemon-reload
systemctl enable multichronyd.service
systemctl start multichronyd.service

echo
echo "### All done! ###"
echo "The corrected multichronyd service is now running using $CPU_CORES core(s)."
echo "You can check its status with: systemctl status multichronyd.service"
