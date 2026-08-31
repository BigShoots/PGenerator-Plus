#!/bin/sh
# Hook script triggered by udev when a BT PAN device connects.
# Supports both the legacy plain bnep interface name and numbered bnep0/bnep1
# variants before restarting dhcpd so it binds to the active PAN port.

IFACE="$1"
[ -n "$IFACE" ] || IFACE="bnep"

tries=0
while [ $tries -lt 5 ]; do
 [ -d "/sys/class/net/$IFACE" ] && break
 [ "$IFACE" = "bnep" ] && [ -d "/sys/class/net/bnep0" ] && break
 tries=`expr $tries + 1`
 sleep 1
done

/etc/init.d/dhcp restart &