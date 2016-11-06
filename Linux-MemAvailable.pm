#!/usr/bin/perl

package Linux::MemAvailable;

=head1 NAME

Linux::MemAvailable - Backport of the /proc/meminfo "MemAvailable" metric for Linux kernels before 3.14.

=head1 SYNOPSIS

	require 'Linux-MemAvailable.pm';

	#Linux::MemAvailable::set_debug();
	#Linux::MemAvailable::set_old_calc();

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
my $old_calc = 0;

sub set_debug {
	$debug = 1;
}
sub set_old_calc {
	$old_calc = 1;
}

sub _get_empty_zone_struct {
	return {
		'zone_header' => {
				'regexp' => '^(Node\s+\d+,\s+zone\s+.+)$',
				'value' => undef,
		},
		'high_wmark_pages' => {
				'regexp' => '^\s+high\s+(\d+)\s*$',
				'value' => undef,
		},
		'managed_pages' => {
				'regexp' => '^\s+managed\s+(\d+)\s*$',
				'value' => undef,
		},
		'lowmem_reserve' => {
				'regexp' => '^\s+protection:\s+\(([0-9, ]+)\)\s*$',
				'value' => undef,
		},
	};
}

sub _zone_end {
	my ($zone, $all_zones) = @_;
	my ($key, $v);
	my @arr;
	my $node_id;

	foreach $key (keys %{$zone}) {
		if (!defined($zone->{$key}->{'value'})) {
			die("ERROR: Zone parsing is incomplete; missing key='$key'");
		}
	}
	@arr = split(/, /, $zone->{'lowmem_reserve'}->{'value'});
	foreach $v (@arr) {
		if ($v !~ /^\d+$/) {
			die("Invalid value for 'lowmem_reserve': $v");
		}
	}
	$zone->{'lowmem_reserve'}->{'value'} = \@arr;

	# https://www.kernel.org/doc/gorman/html/understand/understand005.html
	if ($zone->{'zone_header'}->{'value'} !~ /^Node\s+(\d+),\s+zone\s+/) {
		die("Unable to parse the zone header: ".$zone->{'zone_header'}->{'value'});
	}
	$node_id = $1;

	if (!exists($all_zones->[$node_id])) {
		$all_zones->[$node_id] = [];
	}
	push(@{$all_zones->[$node_id]}, $zone);
}

sub parse_proc_zoneinfo {
	my ($zoneinfo_lines, $all_zones) = @_;
	my $zone;
	my (@lines, $line);
	my ($key, $v);
	my $regexp;
	my $line_num = 0;

	if (!defined($zoneinfo_lines)) {
		open(F, '<', '/proc/zoneinfo') or die("open('/proc/zoneinfo'): $!");
		@lines = <F>;
		close(F) or die("close('/proc/zoneinfo'): $!");
	} else {
		@lines = @{$zoneinfo_lines};
	}

	$zone = _get_empty_zone_struct();
	foreach $line (@lines) {
		++$line_num;
		foreach $key (keys %{$zone}) {
			$regexp = $zone->{$key}->{'regexp'};
			if ($line =~ /$regexp/) {
				$v = $1;
				if ($key eq 'zone_header') {
					if ($line_num > 1) {
						_zone_end($zone, $all_zones);
					}
					$zone = _get_empty_zone_struct();
				}
				if (defined($zone->{$key}->{'value'})) {
					die("ERROR: Got Zone key='$key' for the second time");
				}
				if ($key ne 'zone_header' && !defined($zone->{'zone_header'}->{'value'})) {
					die("ERROR: Got Zone key='$key' before we encountered a Zone start");
				}
				$zone->{$key}->{'value'} = $v;
			}
		}
	}
	_zone_end($zone, $all_zones);
}

sub get_max_nr_zones {
	my ($all_zones) = @_;
	my $zone;
	my $MAX_NR_ZONES = undef;
	my $val;
	my $node_zones;

	foreach $node_zones (@{$all_zones}) {
		foreach $zone (@{$node_zones}) {
			$val = scalar @{$zone->{'lowmem_reserve'}->{'value'}};
			if (!defined($MAX_NR_ZONES)) {
				$MAX_NR_ZONES = $val;
			}
			if ($MAX_NR_ZONES != $val) {
				die("ERROR: Got different count for MX_NR_ZONES: $val");
			}
		}
	}

	print "MAX_NR_ZONES: $MAX_NR_ZONES\n" if ($debug);
	return $MAX_NR_ZONES;
}

# https://github.com/famzah/linux-memavailable-procfs/issues/2
# https://github.com/torvalds/linux/blob/6aa303defb7454a2520c4ddcdf6b081f62a15890/mm/page_alloc.c#L6559
sub calculate_totalreserve_pages {
	my ($all_zones) = @_;
	my $zone;
	my $MAX_NR_ZONES = get_max_nr_zones($all_zones);
	my $reserve_pages = 0;
	my ($i, $j);
	my $node_zones;
	my $max;

	foreach $node_zones (@{$all_zones}) {
		for ($i = 0; $i < $MAX_NR_ZONES; $i++) {
			if (!defined($node_zones->[$i])) {
				# The Linux kernel implementation loops over not active zones too?
				# Maybe they are zero-initialized, since the result is the same
				# as if we stop iterating MAX_NR_ZONES.
				# Or maybe we get MAX_NR_ZONES inappropriately.
				#
				# Nevertheless, iterating only the existing zones seems correct,
				# and also gives the same results as the Linux kernel implementation.

				last;
			}

			$zone = $node_zones->[$i];
			$max = 0;

			# find valid and maximum lowmem_reserve in the zone
			for ($j = $i; $j < $MAX_NR_ZONES; $j++) {
				if ($zone->{'lowmem_reserve'}->{'value'}->[$j] > $max) {
					$max = $zone->{'lowmem_reserve'}->{'value'}->[$j];
				}
			}

			# we treat the high watermark as reserved pages
			$max += $zone->{'high_wmark_pages'}->{'value'};

			if ($max > $zone->{'managed_pages'}->{'value'}) {
				$max = $zone->{'managed_pages'}->{'value'};
			}

			print $zone->{'zone_header'}->{'value'}.": reserve_pages=$max\n" if ($debug);
			$reserve_pages += $max;
		}
	}

	return $reserve_pages; # totalreserve_pages
}

# TODO: Refactor to use parse_proc_zoneinfo()
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

sub pages_to_kb {
	my ($label, $value) = @_;
	my $pagesize = POSIX::sysconf(POSIX::_SC_PAGESIZE);

	if (!defined($pagesize)) {
		die("ERROR: Unable to determine the memory 'pagesize'");
	}

	print "$label: $value pages\n" if ($debug);
	$value *= $pagesize; # convert to Bytes
	$value = sprintf('%.0f', $value / 1024); # convert to kB
	print "$label: $value kB\n" if ($debug);

	return $value;
}

sub calculate {
	my ($meminfo_lines, $zoneinfo_lines) = @_;

	my $wmark_low;
	my $totalreserve_pages;
	my $all_zones = [];
	my $meminfo;
	my $available;
	my $pagecache;
	my ($lru_active_file, $lru_inactive_file);
	my $memfree;
	my $slab_reclaimable;

	parse_proc_zoneinfo($zoneinfo_lines, $all_zones);

	$totalreserve_pages = calculate_totalreserve_pages($all_zones);
	$totalreserve_pages = pages_to_kb('totalreserve_pages', $totalreserve_pages);

	$wmark_low = get_wmark_low_in_pages($zoneinfo_lines);
	$wmark_low = pages_to_kb('wmark_low', $wmark_low);

	$meminfo = parse_meminfo($meminfo_lines);

	$memfree = get_v($meminfo, 'MemFree');
	print "MemFree: $memfree kB\n" if ($debug);

	# https://github.com/famzah/linux-memavailable-procfs/issues/2
	# https://github.com/torvalds/linux/commit/84ad5802a33a4964a49b8f7d24d80a214a096b19
	if ($old_calc) {
		$available = $memfree - $wmark_low;
	} else {
		$available = $memfree - $totalreserve_pages;
	}

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
