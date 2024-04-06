use Encode qw(encode decode);
die <<USAGE unless @ARGV == 2;
Usage: perl $0 gid.csv gdp.lgx
	csv must contain recorded multgid data in UTF-8;
	lgx must correspond to the same route, contain same station names as in csv; train data will be replaced and printed to stdout.
USAGE
open my $F, '<', $ARGV[0] or die "$ARGV[0]: $!";
<$F>;
my %state = (); # [ position, speed, station ]
my %gid = (); # station => { arr, dep, start, entry }
while (<$F>) {
	chomp;
	my @row = split /\t/;
	my $num = $row[2];
	my $time = ($row[1] =~ /(\d\d:\d\d:\d\d)/)[0];
	my $speed = $row[5];
	my $pos = $row[9];
	my $station = lc decode('utf-8', $row[6]);
	$state{$num} = [ 0, 0, $station ] unless exists $state{$num};
	if (abs($state{$num}[1]) < 0.1 and abs($speed) >= 0.1 and $pos != 4) { # movement start
		$gid{$num}{$station}{'start'} = $time;
	} elsif (abs($state{$num}[1]) >= 0.1 and abs($speed) < 0.1 and $pos != 4) { # movement stop
		$gid{$num}{$station}{'arr'} = $time unless exists $gid{$num}{$station}{'arr'};
	}
	if ($state{$num}[0] == 4 and $pos != 4) { # entry to station
		$gid{$num}{$station}{'entry'} = $time;
	} elsif ($state{$num}[0] != 4 and $pos == 4) { # exit from station
		$gid{$num}{$station}{'dep'} = exists $gid{$num}{$station}{'start'} ? $gid{$num}{$station}{'start'} : $time;
	}
	$state{$num}[0] = $pos;
	$state{$num}[1] = $speed;
	$state{$num}[2] = $station;
}
close $F;
sub parsetime {
	my ($t) = @_;
	return undef unless defined $t;
	my ($h, $m, $s) = $t =~ /(\d\d):(\d\d):(\d\d)/;
	my $r = $h * 120 + $m * 2;
	$r += 2 if $s > 30;
	return $r;
}
my @rps = ();
my $skip = 0;
my $fragdir = 0;
open my $G, '<', $ARGV[1] or die "$ARGV[1]: $!";
while (<$G>) {
	if (/<Fragment.*?Dir="(\d)/i) {
		@rps = ();
		$fragdir = $1;
	}
	push @rps, lc decode('cp1251', $1) if /<RP.*?Name=("[^"]+")/i;
	if (/<Trains/) {
		print;
		for my $num (sort { $a <=> $b } keys %gid) {
			next if $num == 9999;
			next if keys %{$gid{$num}} <= 1;
			print qq#    <Train Num="$num">\n#;
			for my $rp (@rps) {
				if (exists $gid{$num}{$rp}) {
					my $arr = parsetime $gid{$num}{$rp}{'arr'};
					my $dep = parsetime $gid{$num}{$rp}{'dep'};
					$arr = $dep unless defined $arr;
					print qq#     <Pt R5="0" P="$arr" O="$dep" F="16"/>\n#;
				} else {
					print qq#     <Pt R5="0"/>\n#;
				}
			}
			print qq#    </Train>\n#;
		}
		$skip = 1;
	}
	$skip = 0 if m#</Trains>#;
	print unless $skip;
}
close $G;