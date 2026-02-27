#!/bin/sh
#
# Hook script triggered by udev when a BT PAN device connects (bnep0 created).
# Restarts dhcpd so it serves DHCP on the bnep bridge with the new port.
#
sleep 2
/etc/init.d/dhcp restart &
