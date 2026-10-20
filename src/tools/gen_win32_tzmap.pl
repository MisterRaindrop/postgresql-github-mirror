#----------------------------------------------------------------------
#
# gen_win32_tzmap.pl
#	Perl script that transforms the CLDR windowsZones.xml file into
#	suitable entries for findtimezone.c's win32_tzmap[] array.
#
# The input is an XML file containing entries like
#   <!-- (UTC-12:00) International Date Line West -->
#   <mapZone other="Dateline Standard Time" territory="001" type="Etc/GMT+12"/>
# as well as some other lines that we ignore.  (This is far from being a
# full XML parser, as CLDR is sufficiently rigid about their data layout
# that we don't need that.)  We ignore entries that aren't for territory 001.
#
# The output is a fragment of C with entries like
#	{
#		/* (UTC-12:00) International Date Line West */
#		"Dateline Standard Time", "Dateline Daylight Time",
#		"Etc/GMT+12"
#	},
# This can be merged into findtimezone.c; however, don't just blindly
# replace the contents of the win32_tzmap[] array.  We don't want to
# drop any obsolete Windows zone names, since initdb might get run on
# a machine whose timezone registry isn't up to date.  Therefore, check
# for zone names that are no longer present, and move those entries to
# the bottom of the array.
#
# To ease making that check manually, the output of this program is
# sorted by Windows zone name by default.
#
#
# Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
# Portions Copyright (c) 1994, Regents of the University of California
#
# src/tools/gen_win32_tzmap.pl
#
#----------------------------------------------------------------------

use strict;
use warnings FATAL => 'all';
use Getopt::Long;

my $output_file = 'tzmap.tmp.c';
my $sort_rule = 'stdname';

GetOptions(
	'output:s' => \$output_file,
	'sort:s' => \$sort_rule) || usage();

my $cldr_input_file = shift @ARGV || die "No input file.\n";

open(my $xmlif, '<', $cldr_input_file) || die "$cldr_input_file: $!\n";
open(my $outfile, '>', $output_file) || die "$output_file: $!\n";

# Parse input file to extract data.
my @timezones;
my $last_comment = '';
my $okay = 1;
while (<$xmlif>)
{
	if (/^\s*<!-- (.*?) -->/)
	{
		$last_comment = $1;
	}
	elsif (/^\s*<mapZone/)
	{
		if (m|^\s*<mapZone\s+other="(.*)"\s+territory="(.*)"\s+type="(.*)"/>\s*$|
		  )
		{
			my $stdname = $1;
			my $territory = $2;
			my $zone = $3;
			next if $territory ne "001";
			# print "$stdname => $zone ($last_comment)\n";
			push @timezones,
			  {
				stdname => $stdname,
				zone => $zone,
				comment => $last_comment
			  };
		}
		else
		{
			print "unintelligible mapZone: $_";
			$okay = 0;
		}
		$last_comment = '';
	}
	elsif (!m/^\s*$/)
	{
		# useful for debugging:
		# print "ignoring line: $_";
	}
}

exit 1 unless $okay;

if ($sort_rule eq 'stdname')
{
	@timezones = sort { lc($a->{stdname}) cmp lc($b->{stdname}) } @timezones;
}
elsif ($sort_rule eq 'zone')
{
	@timezones = sort { $a->{zone} cmp $b->{zone} } @timezones;
}
elsif ($sort_rule eq 'comment')
{
	@timezones = sort { $a->{comment} cmp $b->{comment} } @timezones;
}

for my $timezone (@timezones)
{
	my $stdname = ${$timezone}{'stdname'};
	my $dayname = $stdname;
	$dayname =~ s/Standard/Daylight/;
	my $zone = ${$timezone}{'zone'};
	my $comment = ${$timezone}{'comment'};

	print $outfile "\t{\n";
	print $outfile "\t\t/* $comment */\n";
	print $outfile "\t\t\"$stdname\", \"$dayname\",\n";
	print $outfile "\t\t\"$zone\"\n";
	print $outfile "\t},\n";
}

exit 0;


sub usage
{
	die <<EOM;
Usage: gen_win32_tzmap.pl [--output/-o <file>] [--sort/-s <rule>] input_file
    --output        Output file (default 'tzmap.tmp.c')
    --sort          Sort rule: stdname,zone,comment,none (default 'stdname')

gen_win32_tzmap.pl transforms windowsZones.xml into constant data
for findtimezone.c.
EOM
}
