#!/bin/sh
# Hook script triggered by udev when a BT PAN device connects (bnep0, bnep1, ...).
# Restarts dhcpd after the interface exists so it binds to the active PAN port.

IFACE="$1"
[ -n "$IFACE" ] || IFACE="bnep0"

tries=0
while [ $tries -lt 5 ]; do
 [ -d "/sys/class/net/$IFACE" ] && break
 tries=`expr $tries + 1`
 sleep 1
done

/etc/init.d/dhcp restart &