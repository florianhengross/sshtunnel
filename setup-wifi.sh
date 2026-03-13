#!/bin/bash
# ================================================================
# TunnelVault — WiFi Setup + Fallback AP
# Usage: sudo bash setup-wifi.sh
#
# - Connects to known WiFi (configure HOTSPOT_* below)
# - Falls back to Access Point if no internet after boot
# ================================================================
set -euo pipefail

# ── Config ───────────────────────────────────────────────────
HOTSPOT_SSID="iPhone"
HOTSPOT_PASSWORD="pw12345678"

AP_SSID="SouthAfricaDemo-Syntax"
AP_PASSWORD="Syntax.123"

REMOVE_NETWORKS=("FIT-BYOD")
# ─────────────────────────────────────────────────────────────

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "  ${GREEN}✓${NC} $*"; }
warn()  { echo -e "  ${YELLOW}⚠${NC} $*"; }

[[ $EUID -ne 0 ]] && { echo "Run as root: sudo bash setup-wifi.sh"; exit 1; }

echo ""
echo -e "${BOLD}  TunnelVault WiFi Setup${NC}"
echo "  ──────────────────────────────────────"
echo ""

# ── 1. Connect to hotspot ────────────────────────────────────
echo -e "${BOLD}[1/4]${NC} Adding hotspot: ${HOTSPOT_SSID}"
nmcli con delete "$HOTSPOT_SSID" 2>/dev/null || true
nmcli con add \
    type wifi \
    con-name "$HOTSPOT_SSID" \
    ssid "$HOTSPOT_SSID" \
    wifi-sec.key-mgmt wpa-psk \
    wifi-sec.psk "$HOTSPOT_PASSWORD" \
    connection.autoconnect yes \
    connection.autoconnect-priority 100
info "Hotspot '${HOTSPOT_SSID}' added with autoconnect priority 100"

# Try to connect now if SSID is in range
if nmcli dev wifi list | grep -q "$HOTSPOT_SSID"; then
    nmcli con up "$HOTSPOT_SSID" 2>/dev/null && info "Connected to '${HOTSPOT_SSID}'" || warn "Not in range right now — will connect automatically when available"
else
    warn "'${HOTSPOT_SSID}' not in range right now — will connect automatically when available"
fi

# ── 2. Install fallback AP script ────────────────────────────
echo ""
echo -e "${BOLD}[2/4]${NC} Installing fallback AP script"

cat > /usr/local/bin/tunnelvault-wifi.sh << SCRIPT
#!/bin/bash
# TunnelVault WiFi fallback — starts AP if no internet found after boot

AP_SSID="${AP_SSID}"
AP_PASSWORD="${AP_PASSWORD}"

log() { logger -t tunnelvault-wifi "\$*"; echo "\$*"; }

# Wait for NetworkManager to attempt known networks
sleep 30

# Check internet (up to 10 attempts, 3s apart = 30s max)
for i in \$(seq 1 10); do
    if ping -c 1 -W 3 8.8.8.8 &>/dev/null; then
        log "Internet OK — no fallback needed"
        exit 0
    fi
    sleep 3
done

# No internet — start fallback AP
log "No internet after 60s — starting fallback AP: \${AP_SSID}"
nmcli con delete "TunnelVault-AP" 2>/dev/null || true
nmcli dev wifi hotspot ifname wlan0 ssid "\${AP_SSID}" password "\${AP_PASSWORD}"
log "Fallback AP active — connect to '\${AP_SSID}' to access the Pi"
SCRIPT

chmod +x /usr/local/bin/tunnelvault-wifi.sh
info "Script installed at /usr/local/bin/tunnelvault-wifi.sh"

# ── 3. Create systemd service ────────────────────────────────
echo ""
echo -e "${BOLD}[3/4]${NC} Creating systemd service"

cat > /etc/systemd/system/tunnelvault-wifi.service << SVC
[Unit]
Description=TunnelVault WiFi — fallback AP on no internet
After=NetworkManager.service network-online.target
Wants=NetworkManager.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/tunnelvault-wifi.sh
RemainAfterExit=no
StandardOutput=journal
StandardError=journal
SyslogIdentifier=tunnelvault-wifi

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable tunnelvault-wifi.service
info "Service enabled (runs at every boot)"

# ── 4. Remove unwanted networks ──────────────────────────────
echo ""
echo -e "${BOLD}[4/4]${NC} Removing old networks"

for net in "${REMOVE_NETWORKS[@]}"; do
    if nmcli con show "$net" &>/dev/null; then
        nmcli con delete "$net"
        info "Removed: ${net}"
    else
        info "Not found (already gone): ${net}"
    fi
done

# ── Done ─────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}  Done!${NC}"
echo ""
echo "  Behavior after reboot:"
echo "    1. Pi tries to connect to '${HOTSPOT_SSID}'"
echo "    2. If no internet after ~60s → AP '${AP_SSID}' starts automatically"
echo "    3. AP password: ${AP_PASSWORD}"
echo ""
echo "  View AP logs:  journalctl -t tunnelvault-wifi -f"
echo ""
