#!/bin/sh

# ============================================
# Network setup: eth1 as WAN
# ============================================

echo "============================================"
echo "Starting network setup..."
echo "============================================"

# Configure eth1 as WAN interface with DHCP
echo "Configuring WAN interface eth1 via DHCP..."
uci set network.wan=interface
uci set network.wan.device='eth1'
uci set network.wan.proto='dhcp'
uci set network.wan.metric='0'
echo "WAN interface (eth1) configured with DHCP"

# Configure IPv6 WAN
echo "Configuring IPv6 WAN..."
uci set network.wan6=interface
uci set network.wan6.device='eth1'
uci set network.wan6.proto='dhcpv6'
uci set network.wan6.metric='0'
echo "IPv6 WAN configured"

# Ensure eth0 remains in LAN
echo "Configuring LAN interface eth0..."
uci del network.lan.ifname 2>/dev/null
uci del network.lan.device 2>/dev/null
uci set network.lan.device='eth0'
echo "LAN interface (eth0) configured"

# ============================================
# Firewall zone configuration for WAN
# ============================================

echo "Configuring firewall zone for WAN..."

# ИСПРАВЛЕНИЕ: Удаляем дублирующиеся зоны WAN, если их больше одной
WAN_ZONE_COUNT=$(uci show firewall 2>/dev/null | grep "zone\[@.*\].name='wan'" | wc -l)
if [ "$WAN_ZONE_COUNT" -gt 1 ]; then
    echo "WARNING: Found $WAN_ZONE_COUNT WAN zones, cleaning up duplicates..."
    uci revert firewall 2>/dev/null
fi

# Check if WAN zone already exists
EXISTING_WAN_ZONE=$(uci show firewall 2>/dev/null | grep "zone\[@.*\].name='wan'" | head -1)

if [ -n "$EXISTING_WAN_ZONE" ]; then
    # Zone exists, extract its index and update it
    WAN_ZONE=$(echo "$EXISTING_WAN_ZONE" | cut -d'[' -f2 | cut -d']' -f1)
    uci set firewall.@zone[$WAN_ZONE].network='wan wan6'
    uci set firewall.@zone[$WAN_ZONE].input='REJECT'
    uci set firewall.@zone[$WAN_ZONE].output='ACCEPT'
    uci set firewall.@zone[$WAN_ZONE].forward='REJECT'
    uci set firewall.@zone[$WAN_ZONE].masq='1'
    uci set firewall.@zone[$WAN_ZONE].mtu_fix='1'
    echo "Firewall zone 'wan' updated (index: $WAN_ZONE)"
else
    # Create the wan zone
    uci add firewall zone
    uci set firewall.@zone[-1].name='wan'
    uci set firewall.@zone[-1].network='wan wan6'
    uci set firewall.@zone[-1].input='REJECT'
    uci set firewall.@zone[-1].output='ACCEPT'
    uci set firewall.@zone[-1].forward='REJECT'
    uci set firewall.@zone[-1].masq='1'
    uci set firewall.@zone[-1].mtu_fix='1'
    echo "Firewall zone 'wan' created"
fi

# ============================================
# Allow forwarding between LAN and WAN
# ============================================

echo "Allowing forwarding between LAN and WAN..."

# Look for existing forwarding rule from lan to wan
EXISTING_FWD=$(uci show firewall 2>/dev/null | grep "forwarding\[@.*\].src='lan'" | grep "dest='wan'")

if [ -z "$EXISTING_FWD" ]; then
    # Create forwarding rule
    uci add firewall forwarding
    uci set firewall.@forwarding[-1].src='lan'
    uci set firewall.@forwarding[-1].dest='wan'
    echo "Forwarding rule added"
else
    echo "Forwarding rule already exists, skipping"
fi

# ============================================
# Open ports for remote management via WAN
# ============================================

echo "Opening management ports (HTTP, HTTPS, SSH) for access from WAN..."

# Check if rules already exist to avoid duplicates on repeated runs
EXISTING_HTTP=$(uci show firewall 2>/dev/null | grep "rule\[@.*\].name='Allow-HTTP-from-WAN'")

if [ -z "$EXISTING_HTTP" ]; then
    # HTTP (port 80)
    uci add firewall rule
    uci set firewall.@rule[-1].name='Allow-HTTP-from-WAN'
    uci set firewall.@rule[-1].src='wan'
    uci set firewall.@rule[-1].dest_port='80'
    uci set firewall.@rule[-1].proto='tcp'
    uci set firewall.@rule[-1].target='ACCEPT'

    # HTTPS (port 443)
    uci add firewall rule
    uci set firewall.@rule[-1].name='Allow-HTTPS-from-WAN'
    uci set firewall.@rule[-1].src='wan'
    uci set firewall.@rule[-1].dest_port='443'
    uci set firewall.@rule[-1].proto='tcp'
    uci set firewall.@rule[-1].target='ACCEPT'

    # SSH (port 22)
    uci add firewall rule
    uci set firewall.@rule[-1].name='Allow-SSH-from-WAN'
    uci set firewall.@rule[-1].src='wan'
    uci set firewall.@rule[-1].dest_port='22'
    uci set firewall.@rule[-1].proto='tcp'
    uci set firewall.@rule[-1].target='ACCEPT'

    echo "Rules for ports 80, 443, 22 added"
else
    echo "Management rules already exist, skipping"
fi

# ============================================
# Save and apply
# ============================================

echo "Saving settings..."
uci commit network || echo "Warning: Failed to commit network"
uci commit firewall || echo "Warning: Failed to commit firewall"
echo "Settings saved"

# ИСПРАВЛЕНИЕ: Используем ubus и fw4 вместо /etc/init.d (т.к. нет rc.common)
echo "Restarting network and firewall..."
ubus call network reload 2>/dev/null || echo "Warning: Failed to reload network via ubus"
fw4 reload 2>/dev/null || echo "Warning: Failed to reload firewall via fw4"
echo "Network and firewall restarted"

# Remove script so it doesn't run again
echo "Removing script..."
rm -f "$0"
echo "============================================"
echo "Setup complete."
echo "============================================"
