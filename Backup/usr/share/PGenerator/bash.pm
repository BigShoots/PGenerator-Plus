#########################################
#                 Bash                  #
#########################################
sub bash (@) {
 if($0 eq $bash_program_name) {
  if($ENV{SUDO_USER} eq "" && $ENV{SHELL} eq $bash_program_name) {
   &bash_menu() if($#ARGV == -1);
   exit;
  }
  exit;
 }
}

#########################################
#                 Menu                  #
#########################################
sub bash_menu (@) {
 my $channel=$distro_name;
 my $text_subscribe="Unsubscribe from Beta Channel";
 system("clear");
 if(&read_from_file($distro_conf) !~/$distro_name(Beta)/) {
  $text_subscribe="Subscribe to Beta Channel";
  $channel=$distro_name."Beta";
 }
 print "\t\t\tPGenerator $version Update Login\n\n";
 print "1) $text_subscribe\n";
 print "2) Update Software\n";
 print "3) Change Password\n";
 print "4) Reboot Device\n";
 print "5) Shutdown Device\n";
 print "6) Exit\n";
 print "\n";
 print "Select an option: ";
 chomp($answer=<STDIN>);
 print "\n";
 &bash_return_to_menu("Wrong option selected") if($bash_action{$answer}eq "");
 eval "$bash_action{$answer}($channel)";
}


#########################################
#                 Error                 #
#########################################
sub bash_return_to_menu (@) {
 my $text = shift;
 print "$text, press Enter to go to the Menu...";
 <STDIN>;
 &bash_menu();
}

#########################################
#                 Update                #
#########################################
sub bash_update (@) {
 exit if(&sudo("BASH_CMD","PKG_UPDATE") eq "REBOOT");
 &bash_return_to_menu("Update finished");
}

#########################################
#              Subscribe                #
#########################################
sub bash_subscribe (@) {
 my $channel = shift;
 &sudo("BASH_CMD","PKG_SUBSCRIBE",$channel);
 &bash_return_to_menu("Subscribe done");
}

#########################################
#           Change Password             #
#########################################
sub bash_change_password (@) {
 &sudo("BASH_CMD","CHANGE_PASSWORD","pgenerator");
 &bash_return_to_menu("Password changed");
}

#########################################
#                Reboot                 #
#########################################
sub bash_reboot (@) {
 &sudo("REBOOT");
 exit;
}

#########################################
#                Shutdown               #
#########################################
sub bash_shutdown (@) {
 &sudo("HALT");
 exit;
}

return 1;
