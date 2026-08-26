use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempfile);

my $python=`command -v python3 2>/dev/null`;
chomp($python);
plan skip_all => 'python3 is required for CEC helper tests' if(!$python);

my $helper="$Bin/../usr/sbin/pgenerator-cec";
my ($fh,$script)=tempfile('pgen-cec-XXXX',SUFFIX=>'.py',UNLINK=>1);
print {$fh} <<'PY';
from importlib.machinery import SourceFileLoader
import sys

p=SourceFileLoader('pgen_cec',sys.argv[1]).load_module()
p.time.sleep=lambda _seconds: None

requests=[]
def fake_ioctl(_fd,req,buf):
    if req==p.CEC_ADAP_S_LOG_ADDRS and len(buf)>7 and buf[7]==1:
        requests.append((buf[31],buf[35],buf[39]))
    return True
p.do_ioctl=fake_ioctl
states=[
    {'mask':0,'log_addr':[255,255,255,255],'num_log_addrs':0},
    {'mask':0x10,'log_addr':[4,255,255,255],'num_log_addrs':1},
]
p.get_log_addrs=lambda _fd: states.pop(0) if states else states
assert p.claim_log_addr(1)==4
assert requests[0]==(4,3,0x10), requests

frames=[]
def fake_transmit(_fd,src,dst,opcode,params=None,retries=0):
    frames.append((src,dst,opcode,list(params or [])))
    return p.CEC_TX_STATUS_OK
p.transmit_retry=fake_transmit
assert p.wake_tv(1,4,0x1000)
assert [f[2] for f in frames]==[0x44,0x45,0x04,0x0d,0x82], frames
assert frames[0][3]==[0x6d]
assert frames[-1][1:]==(15,0x82,[0x10,0x00])
print('pgenerator-cec-ok')
PY
close($fh);

my $out=`$python $script $helper 2>&1`;
my $rc=$?;
is($rc,0,'CEC helper unit harness runs cleanly') or diag($out);
like($out,qr/pgenerator-cec-ok/,'playback claim and LG wake sequence are correct');

done_testing();
