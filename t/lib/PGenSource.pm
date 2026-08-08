package PGenSource;
#
# Shared helpers for the source-level contract tests in t/.
#
# These tests assert on source text because this project has no way to spin up
# a WebOS session, a meter or a panel in a test. That is a real constraint, but
# it is not a licence to write assertions that cannot fail. Two rules follow
# from the first version of t/cec_autocal_contract.t, which passed with every
# removed gate re-introduced under a new name and failed when someone added an
# explanatory comment:
#
#   1. Assert on the CONTENTS of a region, never on "A appears before B".
#      A /A.*?B/s pattern places no constraint on the gap -- and the gap is
#      exactly where deleted code would come back.
#   2. Strip comments before asserting on code. Documenting a removal must
#      never break a test about behaviour.
#
use strict;
use warnings;
use File::Spec ();
use File::Find ();

use Exporter ();
our @ISA=qw(Exporter);
our @EXPORT_OK=qw(repo_root source_path slurp_source code_only slice_between code_lines_between scan_tree);

sub repo_root {
 my ($bin)=@_;
 return File::Spec->rel2abs(File::Spec->catdir($bin,".."));
}

sub source_path {
 my ($root,$relative)=@_;
 return File::Spec->catfile($root,split(m{/},$relative));
}

sub slurp_source {
 my ($root,$relative)=@_;
 my $path=source_path($root,$relative);
 open(my $fh,"<",$path) or die "read $relative: $!";
 local $/;
 my $source=<$fh>;
 close($fh);
 return $source;
}

# Remove comments so an assertion about code cannot be tripped by prose.
# Perl: full-line comments only -- a trailing "#" is too easily inside a string
# or a regex to strip safely, and full-line is what documentation uses.
# JS: "//" to end of line, but not the "//" in a URL, plus /* ... */ blocks.
sub code_only {
 my ($text,$style)=@_;
 return "" if(!defined($text));
 $style="perl" if(!defined($style));
 if($style eq "perl") {
  $text=~s{^[ \t]*\#.*$}{}mg;
 } else {
  $text=~s{/\*.*?\*/}{}gs;
  $text=~s{(?<!:)//[^\n]*}{}g;
 }
 return $text;
}

# Return the text lying strictly between the end of $start_re and the start of
# the next $end_re after it. Returns undef if either anchor is missing, so a
# renamed anchor surfaces as a failed test rather than a silently empty slice.
sub slice_between {
 my ($source,$start_re,$end_re)=@_;
 return undef if($source !~ /$start_re/);
 my $from=$+[0];
 my $rest=substr($source,$from);
 return undef if($rest !~ /$end_re/);
 return substr($rest,0,$-[0]);
}

# Return the executable lines lying strictly between the line matching
# $start_re and the next line matching $end_re, comment-stripped, trimmed and
# with blanks dropped. Slicing by line rather than by character offset keeps
# the anchors themselves out of the result, so callers can compare what is
# left against an exact expected sequence -- which is what makes an inserted
# statement fail no matter what it is called.
sub code_lines_between {
 my ($source,$start_re,$end_re,$style)=@_;
 my @lines=split(/\n/,$source,-1);
 my ($start,$end);
 for(my $i=0;$i<@lines;$i++) {
  if(!defined($start)) { $start=$i if($lines[$i]=~/$start_re/); next; }
  if($lines[$i]=~/$end_re/) { $end=$i; last; }
 }
 return undef if(!defined($start) || !defined($end));
 my $body=join("\n",@lines[$start+1..$end-1]);
 return [grep { /\S/ } map { my $l=$_; $l=~s/^\s+//; $l=~s/\s+$//; $l } split(/\n/,code_only($body,$style),-1)];
}

# Walk a subtree and hand every readable text file to $callback as
# ($repo_relative_path, $contents). Binary blobs and oversized files are
# skipped -- usr/share/PGenerator/icc-companion holds .so/.dll/.exe payloads.
sub scan_tree {
 my ($root,$subdir,$callback)=@_;
 my $base=File::Spec->catdir($root,split(m{/},$subdir));
 return if(!-d $base);
 File::Find::find({
  no_chdir => 1,
  wanted   => sub {
   my $path=$File::Find::name;
   return if(!-f $path);
   return if(-s $path > 5_000_000);
   open(my $fh,"<",$path) or return;
   binmode($fh);
   local $/;
   my $contents=<$fh>;
   close($fh);
   return if(!defined($contents));
   return if($contents=~/\0/);
   my $relative=File::Spec->abs2rel($path,$root);
   $relative=~s{\\}{/}g;
   $callback->($relative,$contents);
  },
 },$base);
}

1;
