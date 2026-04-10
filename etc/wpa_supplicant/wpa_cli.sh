#!/bin/bash
INTERFACE=$1
ACTION=$2

if [ "$ACTION" == "CONNECTED" ]; then
 dhcpcd -n "$INTERFACE" 2>/dev/null
fi

if [ "$ACTION" == "DISCONNECTED" ]; then
 dhcpcd -k "$INTERFACE" 2>/dev/null
 ip addr flush dev "$INTERFACE" 2>/dev/null
fi
