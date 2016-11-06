#!/usr/bin/perl
use strict;
use warnings;

use Getopt::Std;
use File::Basename;
use POSIX;

require 'Linux-MemAvailable.pm';

# super-globals modified by the command-line arguments
my $scale = 1024; # default scale is KB
my $show_perc = 0;
my $show_extended = 0;

sub fmt($$$) {
	my ($value, $total, $is_total) = @_;
	my $perc_value;

	if (!defined($value)) {
		return 'N/A';
	}

	if ($total != 0) {
		$perc_value = sprintf('%.0f%%', ($value / $total) * 100);
	} else {
		$perc_value = '-';
	}
	
	$value *= 1024; # kB -> bytes ("/proc/meminfo" returns in "kB")
	$value /= $scale;
	#$value = sprintf('%.0f', $value);
	$value = POSIX::floor($value); # the original "free" tool rounds this way

	if (!$show_perc) {
		return $value;
	} else {
		if ($is_total) {
			return $value; # the "total" is always returned as a raw value
		} else { # the other values are returned as a percentage
			return $perc_value;
		}
	}
}

sub HELP_MESSAGE() {
	my $myname = basename($0);
	my $help = <<EOF;
Usage: $myname [-b|-k|-m|-g] [-p] [-e]
  -b,-k,-m,-g  show output in bytes, KB, MB, or GB
  -p           show output in percentage
  -e           show extended memory usage info
EOF
	die($help);
}

sub VERSION_MESSAGE() {
	HELP_MESSAGE();
}

sub parse_cmd_args() {
	my %opts;
	if (!getopts('bkmgpe', \%opts)) {
		HELP_MESSAGE();
	}

	if (defined($opts{'b'})) {
		$scale = 1;
	}
	if (defined($opts{'m'})) {
		$scale = 1024 * 1024;
	}
	if (defined($opts{'g'})) {
		$scale = 1024 * 1024 * 1024;
	}

	if (defined($opts{'p'})) {
		$show_perc = 1;
	}

	if (defined($opts{'e'})) {
		$show_extended = 1;
	}
}

parse_cmd_args();

#Linux::MemAvailable::set_debug();
#Linux::MemAvailable::set_old_calc();

my ($avail, $meminfo) = Linux::MemAvailable::calculate();

my @mem_row_header = (
	'total', 'used', 'free', 'anonymous', 'kernel', 'caches', 'others'
);

my $mem_row_data = {
	'total' => $meminfo->{'MemTotal'},
	'used' => $meminfo->{'MemTotal'} - $meminfo->{'MemFree'},
	'free' => $meminfo->{'MemFree'},
	'anonymous' => $meminfo->{'Active(anon)'} + $meminfo->{'Inactive(anon)'},
	'kernel' => $meminfo->{'SUnreclaim'} + $meminfo->{'PageTables'} + $meminfo->{'KernelStack'},
	'caches' => $meminfo->{'Active(file)'} + $meminfo->{'Inactive(file)'} + $meminfo->{'SReclaimable'},
};
$mem_row_data->{'others'} = $mem_row_data->{'total'} -
	$mem_row_data->{'free'} -
	$mem_row_data->{'anonymous'} -
	$mem_row_data->{'kernel'} -
	$mem_row_data->{'caches'};

my $minus_caches_data = {
	'used' => $meminfo->{'MemTotal'} - $avail,
	'free' => $avail,
};

my $swap_data = {
	'total' => $meminfo->{'SwapTotal'},
	'used' => $meminfo->{'SwapTotal'} - $meminfo->{'SwapFree'},
	'free' => $meminfo->{'SwapFree'},
};

my @mem_row_values = ();
for my $k (@mem_row_header) {
	push(@mem_row_values, fmt($mem_row_data->{$k}, $mem_row_data->{'total'}, $k eq 'total'));
}

my $first_header_fmt = "%-7s %10s %10s %10s %10s %10s %10s %10s\n";
printf($first_header_fmt, '', @mem_row_header);
printf($first_header_fmt, 'Mem:', @mem_row_values);
printf(
	"%-18s %10s %10s\n",
	'  -/+ avail',
	fmt($minus_caches_data->{'used'}, $mem_row_data->{'total'}, 0),
	fmt($minus_caches_data->{'free'}, $mem_row_data->{'total'}, 0)
);
printf(
	"%-7s %10s %10s %10s\n",
	'Swap:',
	fmt($swap_data->{'total'}, $swap_data->{'total'}, 1),
	fmt($swap_data->{'used'}, $swap_data->{'total'}, 0),
	fmt($swap_data->{'free'}, $swap_data->{'total'}, 0)
);

if (!$show_extended) {
	exit(0); # XXX: Exit here if extended info was not requested
}

my @extended_row_header = (
	'Buffers', 'Cached', 'SwapCached', 'Shmem', 'AnonPages', 'Mapped',
	'Unevict+Mlocked', 'Dirty+Writeback',
	'NFS+Bounce'
);
my $extended_data = {
	'Buffers' => $meminfo->{'Buffers'},
	'Cached' => $meminfo->{'Cached'},
	'SwapCached' => $meminfo->{'SwapCached'},
	'Shmem' => $meminfo->{'Shmem'},
	'AnonPages' => $meminfo->{'AnonPages'},
	'Mapped' => $meminfo->{'Mapped'},
	'Unevict+Mlocked' => $meminfo->{'Unevictable'} + $meminfo->{'Mlocked'},
	'Dirty+Writeback' => $meminfo->{'Dirty'} + $meminfo->{'Writeback'} +
		$meminfo->{'WritebackTmp'},
	'NFS+Bounce' => $meminfo->{'NFS_Unstable'} + $meminfo->{'Bounce'},
};

printf("\nExtended memory usage info:\n");
foreach my $k (@extended_row_header) {
	printf(
		"%-18s %10s\n",
		"  $k", fmt($extended_data->{$k}, $mem_row_data->{'total'}, 0)
	);
}

my @extended_row_header2 = (
	'Active(file)', 'Inactive(file)', 'SReclaimable'
);
my $extended_data2 = {
	'Active(file)' => $meminfo->{'Active(file)'},
	'Inactive(file)' => $meminfo->{'Inactive(file)'},
	'SReclaimable' => $meminfo->{'SReclaimable'},
};

printf("\nExtended caches info:\n");
foreach my $k (@extended_row_header2) {
	printf(
		"%-18s %10s\n",
		"  $k", fmt($extended_data2->{$k}, $mem_row_data->{'total'}, 0)
	);
}
