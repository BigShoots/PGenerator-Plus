#!/usr/bin/perl
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
# See the File README and COPYING for more detail about License
#
# Program: PGenerator.pl
# Version: 1.0
#
#########################################
#                Modules                #
#########################################
use Cwd;
use Config;
use Time::HiRes qw(usleep);
use IO::Socket::INET;
use IO::Select;
use Getopt::Long;
use File::Copy;
use threads;
use threads::shared;
use URI::Escape;
use MIME::Base64;
use XML::Simple;
use List::Util qw(sum);

#########################################
#              Shared Dir               #
#########################################
BEGIN { use lib $shared_dir="/usr/share/PGenerator"; }
chdir($shared_dir);

#########################################
#                 My pm                 #
#########################################
do "version.pm"       || die "Error";
do "command.pm"       || die "Error";
do "variables.pm"     || die "Error";
do "conf.pm"          || die "Error";
do "info.pm"          || die "Error";
do "file.pm"          || die "Error";
do "log.pm"           || die "Error";
do "pattern.pm"       || die "Error";
do "daemon.pm"        || die "Error";
do "client.pm"        || die "Error";
do "discovery.pm"     || die "Error";
do "webui.pm"         || die "Error";
do "bash.pm"          || die "Error";
do "serial.pm"        || die "Error";

#############################################
#                Get Conf                   #
#############################################
&get_conf();

#############################################
#                  Bash                     #
#############################################
&bash();

#############################################
#                Serial                     #
#############################################
&serial();

#############################################
#               Start Daemon                #
#############################################
fork_pattern_daemon();
