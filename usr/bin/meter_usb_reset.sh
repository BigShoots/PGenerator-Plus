#!/bin/bash
# meter_usb_reset.sh - Reset USB hub to re-enumerate disconnected meter
# Called via sudo from PGenerator daemon when meter USB fails

# Kill any lingering spotread processes
pkill -9 -x spotread 2>/dev/null
pkill -9 -f 'script.*spotread' 2>/dev/null
pkill -9 -f 'spotread_wrapper' 2>/dev/null
sleep 0.3

# Find the USB hub that has (or had) the meter
# RPi 400: internal hub is 1-1
for hub in 1-1; do
 if [ -e "/sys/bus/usb/drivers/usb/$hub" ]; then
  echo "$hub" > /sys/bus/usb/drivers/usb/unbind 2>/dev/null
  sleep 1
  echo "$hub" > /sys/bus/usb/drivers/usb/bind 2>/dev/null
  sleep 2
  break
 fi
done

# Clear stale port cache
rm -f /tmp/spotread_port_cache 2>/dev/null
