#!/usr/bin/perl

package Linux::MemAvailable;

=head1 NAME

Linux::MemAvailable - Backport of the /proc/meminfo "MemAvailable" metric for Linux kernels before 3.14.

=head1 SYNOPSIS

	require 'Linux-MemAvailable.pm';

	#Linux::MemAvailable::set_debug();

	my ($avail, $meminfo) = Linux::MemAvailable::calculate();

	my $total = $meminfo->{'MemTotal'};
	printf("Available: %d / %d kB (%.0f%%)\n", $avail, $total, $avail/$total*100);

=head1 NOTE

Kernel commit in C:
  https://git.kernel.org/cgit/linux/kernel/git/torvalds/linux.git/commit/?id=34e431b0ae398fc54ea69ff85ec700722c9da773

WARNING: This module uses die() on errors which should never happen. Wrap with eval() if needed.

=head1 METHODS

calculate() - returns a list with:

	(
		[0] => the calculated value of MemAvailable in kB,
		[1] => hashref containing the parsed "/proc/meminfo",
	)

Note that you can call calculate() by supplying ($meminfo_lines_aref, $zoneinfo_lines_aref) as function arguments. In this case the calculation uses the provided array refs as a source for "/proc/meminfo" and "/proc/zoneinfo" respectively.

set_debug() - enables debug messages on the STDOUT

=head1 EXAMPLES

Easy way to consume memory in user-space:
  perl -e '$s = ""; for ($i = 0; $i < 2000; ++$i) { $s .= "A" x 1048576 }; print "Done\n"; sleep(6000);'

Easy way to put contents into the page cache buffer:
  find /usr -type f -print0|xargs -r -0 cat >/dev/null

NOTE: If you want to test when the system will start swapping, simply disable swap and then try to allocate lots of memory until you get an out-of-memory error.

=head1 AUTHOR

Ivan Zahariev (famzah)

=cut

use strict;
use warnings;

use POSIX;

my $debug = 0;

sub set_debug {
	$debug = 1;
}

sub get_wmark_low_in_pages {
	my ($zoneinfo_lines) = @_;
	my $line;
	my @lines;
	my $got_zone_hdr = 0;
	my $got_low_val = 0;
	my $wmark_low = 0;
	my $v;

	if (!defined($zoneinfo_lines)) {
		open(F, '<', '/proc/zoneinfo') or die("open('/proc/zoneinfo'): $!");
		@lines = <F>;
		close(F) or die("close('/proc/zoneinfo'): $!");
	} else {
		@lines = @{$zoneinfo_lines};
	}

	foreach $line (@lines) {
		if ($line =~ /^Node\s+\d+,\s+zone\s+/) {
			$got_zone_hdr = 1;
			$got_low_val = 0;

			next;
		}
		if ($line =~ /^\s+low\s+(\d+)\s*$/) {
			$v = $1;

			if (!$got_zone_hdr) {
				die("ERROR: Got 'low' before we encountered a 'zone' start");
			}
			if ($got_low_val) {
				die("ERROR: Got 'low' for the second time");
			}

			$got_low_val = 1;
			$wmark_low += $v;

			next;
		}
	}

	return $wmark_low; # /proc/zoneinfo is in "pages", not in kB
}

sub parse_meminfo {
	my ($meminfo_lines) = @_;
	my $line;
	my $data = {};
	my @lines;

	if (!defined($meminfo_lines)) {
		open(F, '<', '/proc/meminfo') or die("open('/proc/meminfo'): $!");
		@lines = <F>;
		close(F) or die("close('/proc/meminfo'): $!");
	} else {
		@lines = @{$meminfo_lines};
	}

	foreach $line (@lines) {
		#print "/proc/meminfo: $line" if ($debug);
		if ($line =~ /^HugePages_/) {
			next; # those lines don't match the regexp below, and we don't need them anyway
		}
		if ($line !~ /^([^:]+):\s+(\d+)\s+kB\s*$/) {
			die("ERROR: Unable to parse a line in '/proc/meminfo': $line");
		}
		$data->{$1} = $2;
	}

	return $data;
}

sub get_v {
	my ($data, $k) = @_;

	if (!exists($data->{$k}) || !defined($data->{$k})) {
		die("ERROR: Key '$k' not found in '/proc/meminfo'");
	}

	return $data->{$k};
}

sub min ($$) { $_[$_[0] > $_[1]] }; # http://www.perlmonks.org/?node_id=406883

sub calculate {
	my ($meminfo_lines, $zoneinfo_lines) = @_;

	my $wmark_low;
	my $meminfo;
	my $available;
	my $pagecache;
	my ($lru_active_file, $lru_inactive_file);
	my $memfree;
	my $slab_reclaimable;

	my $pagesize = POSIX::sysconf(POSIX::_SC_PAGESIZE);

	if (!defined($pagesize)) {
		die("ERROR: Unable to determine the memory 'pagesize'");
	}

	$wmark_low = get_wmark_low_in_pages($zoneinfo_lines);
	print "wmark_low: $wmark_low pages\n" if ($debug);
	$wmark_low *= $pagesize; # convert to Bytes
	$wmark_low = sprintf('%.0f', $wmark_low / 1024); # convert to kB
	print "wmark_low: $wmark_low kB\n" if ($debug);

	$meminfo = parse_meminfo($meminfo_lines);

	$memfree = get_v($meminfo, 'MemFree');
	print "MemFree: $memfree kB\n" if ($debug);

	$available = $memfree - $wmark_low;

	$lru_active_file = get_v($meminfo, 'Active(file)');
	$lru_inactive_file = get_v($meminfo, 'Inactive(file)');
	print "Active(file): $lru_active_file kB\n" if ($debug);
	print "Inactive(file): $lru_inactive_file kB\n" if ($debug);

	$pagecache = $lru_active_file + $lru_inactive_file;
	$pagecache -= min($pagecache / 2, $wmark_low);
	$pagecache = sprintf('%.0f', $pagecache); # round
	$available += $pagecache;

	$slab_reclaimable = get_v($meminfo, 'SReclaimable');
	print "SReclaimable: $slab_reclaimable kB\n" if ($debug);

	$available += $slab_reclaimable - min($slab_reclaimable / 2, $wmark_low);

	if ($available < 0) {
		$available = 0;
	}

	if ($debug) {
		print "MemAvailable: $available kB\n";
	}

	return (
		$available,
		$meminfo,
	);
}

1;
