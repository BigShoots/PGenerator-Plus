
   Pi4 is reachable at 192.168.1.179 username root password PGenerator!!$
   Pi5 is reachable at 192.168.1.249
   Commit your changes as you make them so we can revert.

   Deploying runtime changes to the Pi4:
   - Back up the target files before overwriting them:
     SSHPASS='PGenerator!!$' sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/pgen_known_hosts root@192.168.1.179 'ts=$(date +%Y%m%d-%H%M%S); mkdir -p /root/pgen-backups/$ts; cp -a /usr/bin/meter_lg_autocal.pl /usr/bin/meter_lg_3d_autocal.pl /usr/sbin/pgenerator-lg /usr/share/PGenerator/webui.pm /root/pgen-backups/$ts/ 2>/dev/null; echo $ts'
   - Copy only the changed runtime files to their matching absolute paths, for example:
     SSHPASS='PGenerator!!$' sshpass -e scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/pgen_known_hosts -p usr/bin/meter_lg_autocal.pl usr/bin/meter_lg_3d_autocal.pl root@192.168.1.179:/usr/bin/
     SSHPASS='PGenerator!!$' sshpass -e scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/pgen_known_hosts -p usr/sbin/pgenerator-lg root@192.168.1.179:/usr/sbin/pgenerator-lg
     SSHPASS='PGenerator!!$' sshpass -e scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/pgen_known_hosts -p usr/share/PGenerator/webui.pm root@192.168.1.179:/usr/share/PGenerator/webui.pm
   - Restart PGenerator with the SysV init script. This image does not have systemctl/service; redirect output so SSH does not stay attached to daemon logs:
     SSHPASS='PGenerator!!$' sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/pgen_known_hosts root@192.168.1.179 '/etc/init.d/PGenerator restart >/tmp/PGenerator-restart.log 2>&1 </dev/null &'
   - Verify after restart from a fresh SSH command:
     SSHPASS='PGenerator!!$' sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/pgen_known_hosts root@192.168.1.179 'ps w | grep -E "[P]Generatord.pl|[P]Generator_serial" || true; wget -q -O - http://127.0.0.1/api/status 2>/dev/null | head -c 500 || true'

   Use subagents to do your work, you are their boss, you delegate and review their reports. Try to reusse agents that will require similar context to the new task. For example, if an agent was delegeated to run a calibration test for sdr and you need to run another one, reuse that same agent instead of creating a new one. Do not touch tools let them do the work. 

   Visually confirm your work with screenshots where possible. 

   source code should not include references to calman source code.

   No commits or files should contain reference to being authored by claude or chatgpt. 
