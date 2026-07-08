package PGAutoCalRun;
# Per-run LG Auto Cal diagnostics record. Fail-safe: every public sub swallows
# its own errors and returns quietly so a record failure can never disturb a
# calibration run. Core Perl only.
use strict;
use warnings;
use JSON::PP ();
use File::Path qw(make_path remove_tree);
use Fcntl qw(:flock);

our $VERSION  = '1.0';
our $BASE_DIR = $ENV{'PGEN_AUTOCAL_RUNS_DIR'} || '/var/lib/PGenerator/lg/autocal-runs';
our $KEEP     = 10;

my $JSON = JSON::PP->new->utf8->canonical;
my $SEQ  = 0;

sub _now_ms { return int(time() * 1000); }

sub _safe_id {
 my ($id) = @_;
 return "" if(!defined($id));
 return "" if($id !~ /\A[A-Za-z0-9._-]+\z/);   # no path separators / traversal
 return $id;
}

sub _ensure_dir {
 my ($dir) = @_;
 return 1 if(-d $dir);
 eval { make_path($dir); 1 };
 return -d $dir ? 1 : 0;
}

sub _write_text_atomic {
 my ($path, $text) = @_;
 my $tmp = "$path.tmp.$$";
 open(my $fh, '>', $tmp) or return 0;
 binmode($fh);
 print $fh $text;
 close($fh) or return 0;
 return rename($tmp, $path) ? 1 : 0;
}

sub _write_json_atomic {
 my ($path, $data) = @_;
 my $text;
 eval { $text = $JSON->encode($data); 1 } or return 0;
 return _write_text_atomic($path, $text);
}

sub _read_json {
 my ($path) = @_;
 return {} if(!-f $path);
 open(my $fh, '<', $path) or return {};
 local $/; my $t = <$fh>; close($fh);
 my $d = {};
 eval { $d = $JSON->decode($t); 1 } or return {};
 return (ref($d) eq 'HASH') ? $d : {};
}

sub _current_path { return "$BASE_DIR/current"; }

sub current {
 my $p = _current_path();
 open(my $fh, '<', $p) or return "";
 local $/; my $v = <$fh>; close($fh);
 $v = "" if(!defined($v));
 $v =~ s/\s+//g;
 return _safe_id($v);
}

sub _set_current {
 my ($id) = @_;
 return _write_text_atomic(_current_path(), $id);
}

sub _gen_run_id {
 my @t = localtime(time());
 my $stamp = sprintf('%04d%02d%02d-%02d%02d%02d', $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0]);
 my $suffix = sprintf('%03x%03x', ($$ & 0xfff), (($SEQ++) & 0xfff));
 return "$stamp-$suffix";
}

sub run_dir {
 my ($id) = @_;
 $id = _safe_id($id);
 return "" if($id eq "");
 return "$BASE_DIR/$id";
}

sub _prune {
 opendir(my $dh, $BASE_DIR) or return;
 my @dirs = grep { /\A\d{8}-\d{6}-/ && -d "$BASE_DIR/$_" } readdir($dh);
 closedir($dh);
 @dirs = sort @dirs;   # timestamp+seq prefix => lexical order is chronological
 return if(scalar(@dirs) <= $KEEP);
 for my $d (@dirs[0 .. ($#dirs - $KEEP)]) {
  eval { remove_tree("$BASE_DIR/$d"); 1 };
 }
}

sub run_begin {
 my ($manifest) = @_;
 my $run_id = "";
 eval {
  $manifest = {} if(ref($manifest) ne 'HASH');
  _ensure_dir($BASE_DIR) or die "base\n";
  my $cur = current();
  if($cur ne "") {
   my $cdir = "$BASE_DIR/$cur";
   if(-d $cdir && !-e "$cdir/summary.json") {
    _write_json_atomic("$cdir/summary.json", { status => 'superseded', ended_at => _now_ms() });
   }
  }
  $run_id = _gen_run_id();
  my $dir = "$BASE_DIR/$run_id";
  _ensure_dir($dir) or die "dir\n";
  $manifest->{'run_id'}     = $run_id;
  $manifest->{'started_at'} = _now_ms() if(!$manifest->{'started_at'});
  _write_json_atomic("$dir/manifest.json", $manifest);
  _set_current($run_id);
  _prune();
  1;
 } or return "";
 return $run_id;
}

sub run_stage {
 my ($run_id, $stage, $record) = @_;
 eval {
  my $dir = run_dir($run_id);
  return if($dir eq "" || !-d $dir);
  $record = {} if(ref($record) ne 'HASH');
  $record->{'stage'} = $stage;
  $record->{'ts'}    = _now_ms() if(!$record->{'ts'});
  my $line;
  eval { $line = $JSON->encode($record); 1 } or return;
  open(my $fh, '>>', "$dir/stages.ndjson") or return;
  binmode($fh);
  eval { flock($fh, LOCK_EX); 1 };
  print $fh $line, "\n";
  close($fh);
  1;
 };
 return;
}

sub run_snapshot {
 my ($run_id, $label, $src, $tail_lines) = @_;
 eval {
  my $dir = run_dir($run_id);
  return if($dir eq "" || !-d $dir);
  $label = _safe_id($label);
  return if($label eq "" || !defined($src) || !-f $src);
  my $dst = "$dir/$label";
  open(my $in, '<', $src) or return;
  binmode($in);
  my @lines = <$in>;
  close($in);
  if(defined($tail_lines) && $tail_lines > 0 && scalar(@lines) > $tail_lines) {
   @lines = @lines[ -$tail_lines .. -1 ];
  }
  _write_text_atomic($dst, join('', @lines));
  1;
 };
 return;
}

sub run_merge_manifest {
 my ($run_id, $partial) = @_;
 eval {
  my $dir = run_dir($run_id);
  return if($dir eq "" || !-d $dir);
  $partial = {} if(ref($partial) ne 'HASH');
  my $path = "$dir/manifest.json";
  my $cur = _read_json($path);
  $cur->{$_} = $partial->{$_} for (keys %$partial);
  _write_json_atomic($path, $cur);
  1;
 };
 return;
}

sub run_end {
 my ($run_id, $summary) = @_;
 eval {
  my $dir = run_dir($run_id);
  return if($dir eq "" || !-d $dir);
  $summary = {} if(ref($summary) ne 'HASH');
  $summary->{'ended_at'} = _now_ms() if(!$summary->{'ended_at'});
  $summary->{'status'}   = 'complete' if(!$summary->{'status'});
  _write_json_atomic("$dir/summary.json", $summary);
  1;
 };
 return;
}

sub latest_dir {
 my $best = ""; my $best_m = -1;
 opendir(my $dh, $BASE_DIR) or return "";
 for my $d (readdir($dh)) {
  next if($d !~ /\A\d{8}-\d{6}-/);
  my $p = "$BASE_DIR/$d";
  next if(!-d $p);
  my $m = (stat($p))[9] || 0;
  if($m > $best_m) { $best_m = $m; $best = $p; }
 }
 closedir($dh);
 return $best;
}

1;
