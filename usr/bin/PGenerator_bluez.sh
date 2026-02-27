#!/bin/sh
#
# Copyright (c) 2017-2018 Biasiotto Riccardo
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# See the File COPYING for more detail about License
#
# Program: PGenerator_bluez.sh
# Version: 1.0
#
#############################################
#                 Variables                 #
#############################################
ACTION=$1
DEVICE=$2
PATH_REMOVE="bdaddr (.*) capability.*auth 0x04"
PATH_TRUST="bdaddr (.*) key"
BT_AGENT="/usr/bin/pgenerator-bt-agent"

#############################################
#                 Skip                      #
#############################################
if [[ "$DEVICE" == *:* ]];then
 exit 0
fi

#############################################
#                 Action BT                 #
#############################################
if [ "$ACTION" == "add" ];then
 /usr/bin/hciconfig $DEVICE up
 /etc/init.d/dbus restart
 /etc/init.d/bluetoothd restart
 /etc/init.d/pand restart
 # Restart DHCP immediately after bridge is created, before BT is
 # discoverable, so dhcpd binds to the bnep interface in time.
 /etc/init.d/dhcp restart
 /usr/bin/bluez-test-adapter powered on
 /usr/bin/bluez-test-adapter discoverabletimeout 0
 /usr/bin/bluez-test-adapter discoverable on
 # Start auto-pair agent
 pkill -f "$BT_AGENT" 2>/dev/null
 sleep 1
 $BT_AGENT &
 hcidump -i $DEVICE| while read line ; do
  if [[ $line =~ $PATH_REMOVE ]];then
   mac=${BASH_REMATCH[1]}
   bluez-test-device remove $mac
  fi
  if [[ $line =~ $PATH_TRUST ]];then
   mac=${BASH_REMATCH[1]}
   bluez-test-device trusted $mac yes
  fi
 done
fi
