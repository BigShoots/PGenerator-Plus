#########################################
#                 Serial                #
#########################################
sub serial (@) {
 if($0 eq $serial_program_name) {
  my $device=&get_serial_device();
  exit if($device eq "" || !-e $device);
  while(1) {
   `$socat_program $device,$socat_device_options tcp:$pgenerator_conf{ip_pattern}:$pgenerator_conf{port_pattern}`;
   open(SERIAL,">$device");
   print SERIAL $end_cmd_string;
   close(SERIAL);
   sleep(0.5);
  }
 }
}

#########################################
#           Get Serial Device           #
#########################################
sub get_serial_device (@) {
 for(my $i=0;$i<=5;$i++) {
  next if(!-e "/dev/$serial_name$i" || &process_pid("$serial_name$i","get_with_pattern"));
  return "/dev/$serial_name$i";
 }
}

return 1;
