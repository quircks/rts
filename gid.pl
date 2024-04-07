use strict; use warnings;
use Encode qw(encode decode);
die <<USAGE unless @ARGV == 2;
Usage: perl $0 gid.csv gdp.lgx
CSV must contain recorded multgid data in UTF-16LE;
it is assumed to be sorted by time;
if there were several files generated, following files are found automatically.
LGX must correspond to the same route, contain same station names as in CSV;
train data will be replaced and printed to stdout.
rts_GIDConvert.exe must be in PATH.
USAGE
my $gidname = $ARGV[0];
$gidname =~ s/\.[^.]+$//;
my @csvs = ($ARGV[0]);
my $suffix = 1;
push @csvs, $gidname."_".$suffix++.".csv" while -e $gidname."_".$suffix.".csv";
my @F = map { qx#iconv -f utf-16 -t utf-8 "$_"# } @csvs;
my $i = 0;
my %trainsbynumber = (); # [ ids ]
my @state = (); # { numbers => [], type, wagons, length, mass, head, tail, position, speed, station }
my @gid = (); # { station => { arr, dep, start, entry } }
sub gettilepq {
	my ($tilecoordstring) = @_;
	my ($p, $q) = $tilecoordstring =~ /(-?\d+)\s+(-?\d+)/;
	return ($p, $q);
}
sub tilesareclose {
	my ($tile1coordstring, $tile2coordstring) = @_;
	my ($p1, $q1) = gettilepq($tile1coordstring);
	my ($p2, $q2) = gettilepq($tile2coordstring);
	return 0 if abs($p1 - $p2) > 1 or abs($q1 - $q2) > 1;
	return 1;
}
sub trainid { # find a train
	my ($num, $type, $wagons, $length, $mass, $head, $tail, $pos, $speed, $station) = @_;
	$trainsbynumber{$num} = [] unless exists $trainsbynumber{$num};
	# first check if we already saw similar train
	for my $id (@{$trainsbynumber{$num}}) {
		next if $state[$id]{'wagons'} != $wagons;
		# check that it is within reasonable range from last known location
		next unless tilesareclose($head, $state[$id]{'head'});
		return $id;
	}
	# try other known trains
	# merge only if the train is moving outside station track
	if (abs($speed) > 0.2 and $pos > 1) {
		for my $id (0 .. $#state) {
			next unless abs($state[$id]{'speed'}) > 0.2 and $state[$id]{'position'} > 1;
			next if $state[$id]{'wagons'} != $wagons;
			next if abs($state[$id]{'mass'} - $mass) > 1000;
			my ($cp, $cq) = $state[$id]{'head'} =~ /(-?\d+)\s+(-?\d+)/;
			next unless tilesareclose($state[$id]{'head'}, $head);
			warn "Treating $num as same train as $state[$id]{'numbers'}[0]\n";
			push @{$trainsbynumber{$num}}, $id;
			push @{$state[$id]{'numbers'}}, $num;
			return $id;
		}
	}
	# create new train
	my $newid = @state;
	push @state, {
		'numbers' => [ $num ],
		'type' => $type,
		'wagons' => $wagons,
		'length' => $length,
		'mass' => $mass,
		'head' => $head,
		'tail' => $tail,
		'position' => $pos,
		'speed' => $speed,
		'station' => $station,
		'departed_from' => '',
		'route_start' => '',
		'route_end' => '',
		'last_written_gid' => '',
	};
	push @gid, {};
	push @{$trainsbynumber{$num}}, $newid;
	return $newid;
}
while (++$i < @F) {
	my ($timestamp, $timestring, $num, $type, $wagons, $speed, $station, $track, $direction, $pos, $km, $dist, $length, $mass, $head, $tail) = split /\t/, $F[$i];
	next unless $timestamp =~ /^\d+$/;
	$station = lc decode('utf-8', $station);
	$station =~ s/^"//;
	$station =~ s/"$//;
	$station = substr($station, 0, 16) if length($station) > 16;
	next unless $type == 1 or $type == 2; # require PLAYER or TRAFFIC
	my $id = trainid($num, $type, $wagons, $length, $mass, $head, $tail, $pos, $speed, $station);
	if (abs($state[$id]{'speed'}) <= 0.15 and abs($speed) > 0.15 and $pos != 4) { # movement start
		$gid[$id]{$station}{'start'} = $timestamp;
	} elsif (abs($state[$id]{'speed'}) > 0.15 and abs($speed) <= 0.15 and $pos <= 2) { # movement stop
		if ($state[$id]{'departed_from'} eq $station) {
			delete $gid[$id]{$station}{'dep'};
		} elsif ($state[$id]{'departed_from'} ne '') {
			$gid[$id]{$station}{'arr'} = $timestamp unless exists $gid[$id]{$station}{'arr'};
		}
		$state[$id]{'route_end'} = $station;
		$state[$id]{'departed_from'} = '';
		$state[$id]{'last_written_gid'} = $station;
	}
	if ($state[$id]{'position'} == 4 and $pos != 4) { # entry to station
		# nop, station might be incorrect if speed < 0
	} elsif ($state[$id]{'position'} == 1 and $pos > 1) { # exit from station track
		$gid[$id]{$station}{'exit'} = $timestamp;
	} elsif ($state[$id]{'position'} == 2 and $pos == 3 or $state[$id]{'position'} != 4 and $pos == 4) { # head or tail went to span
		if (exists $gid[$id]{$station}{'start'}) {
			$gid[$id]{$station}{'dep'} = $gid[$id]{$station}{'start'};
		} elsif (exists $gid[$id]{$station}{'exit'}) {
			$gid[$id]{$station}{'dep'} = $gid[$id]{$station}{'exit'};
		} else {
			$gid[$id]{$station}{'dep'} = $timestamp;
		}
		$state[$id]{'departed_from'} = $station if $state[$id]{'departed_from'} eq '';
		$state[$id]{'route_start'} = $station unless '' ne $state[$id]{'route_start'};
		$state[$id]{'route_end'} = '';
		$state[$id]{'last_written_gid'} = $station;
		# memorize train number first time it enters a span
		$state[$id]{'num'} = $num unless exists $state[$id]{'num'} or $num == 0 or $num == 9999;
	} elsif ($state[$id]{'station'} ne $station and $state[$id]{'position'} == 4 and $pos == 4) { # passed block post too quickly
		if ($speed * $state[$id]{'speed'} > 1) {
			# check that coordinate did not change too much to rule out teleports
			if (tilesareclose($state[$id]{'head'}, $head)) {
				$gid[$id]{$station}{'dep'} = $timestamp;
				$state[$id]{'last_written_gid'} = $station;
			}
		} else {
			warn "Train $num reversed direction on span ".encode('cp1251', $state[$id]{'station'})." - ".encode('cp1251', $station)."\n";
		}
	}
	$state[$id]{'type'} = $type;
	$state[$id]{'wagons'} = $wagons;
	$state[$id]{'length'} = $length;
	$state[$id]{'mass'} = $mass;
	$state[$id]{'head'} = $head;
	$state[$id]{'tail'} = $tail;
	$state[$id]{'position'} = $pos;
	$state[$id]{'speed'} = $speed;
	$state[$id]{'station'} = $station;
}
my @rps = ();
my $skip = 0;
my $fragdir = 0;
open my $G, '<', $ARGV[1] or die "$ARGV[1]: $!";
while (<$G>) {
	if (/<Fragment\s.*?Dir="(\d)/i) {
		@rps = ();
		$fragdir = $1;
	}
	push @rps, lc decode('cp1251', $1) if /<RP.*?Name="([^"]+)"/i;
	if (/<Trains/) {
		$skip = 1 unless m#/>#;
		print qq#   <Trains>\n#;
		for my $id (0 .. $#gid) {
			my @nums = grep { $_ != 9999 and $_ != 0 } @{$state[$id]{'numbers'}};
			next unless @nums;
			next unless keys %{$gid[$id]} > 1;
			my @rpdata = ();
			my @indexspans = ();
			my $currentfirstindex = -1;
			my $currentlastindex = -1;
			for my $i (0 .. $#rps) {
				my $rp = $rps[$i];
				my $arr = undef;
				my $dep = undef;
				if (exists $gid[$id]{$rp}) {
					$arr = $gid[$id]{$rp}{'arr'};
					$dep = $gid[$id]{$rp}{'dep'};
					$dep = $arr unless defined $dep;
					$arr = $dep unless defined $arr;
					if (defined $dep) {
						if ($currentfirstindex == -1) {
							$currentfirstindex = $currentlastindex = $i;
						} elsif ($currentlastindex + 1 == $i) {
							$currentlastindex = $i;
						} else {
							push @indexspans, [ $currentfirstindex, $currentlastindex ] if $currentlastindex > $currentfirstindex;
							$currentfirstindex = $currentlastindex = $i;
						}
					}
				}
				push @rpdata, [ $arr, $dep ];
			}
			push @indexspans, [ $currentfirstindex, $currentlastindex ] if $currentlastindex > $currentfirstindex;
			for (@indexspans) {
				my ($firstindex, $lastindex) = @$_;
				my $num = $state[$id]{'num'};
				$num = $nums[0] if @nums > 0 and not defined $num;
				my $uppertime = $gid[$id]{$rps[$firstindex]}{'dep'};
				$uppertime = $gid[$id]{$rps[$firstindex]}{'arr'} unless defined $uppertime;
				my $lowertime = $gid[$id]{$rps[$firstindex + 1]}{'dep'};
				$lowertime = $gid[$id]{$rps[$firstindex + 1]}{'arr'} unless defined $lowertime;
				# midnight
				$uppertime += 86400 if $uppertime < 3600 and $lowertime > 82800;
				$lowertime += 86400 if $lowertime < 3600 and $uppertime > 82800;
				my $odd = -1;
				if ($fragdir == 0) {
					$odd = $uppertime > $lowertime ? 0 : 1;
				} elsif ($fragdir == 3) {
					$odd = $uppertime > $lowertime ? 1 : 0;
				} else {
					die "Unsupported fragdir $fragdir";
				}
				if ($num % 2 != $odd) {
					my @g = grep { $_ % 2 == $odd } @nums;
					my ($firstrp, $lastrp) = map { encode('cp1251', $rps[$_]) } $firstindex, $lastindex;
					if (@g) {
						warn "Guessing train $num as $g[0] (from @nums) for $firstrp - $lastrp\n";
						$num = $g[0];
					} else {
						my $oldnum = $num;
						if ($num % 2) {
							++$num;
						} else {
							--$num;
						}
						warn "Wrong parity of train $oldnum, changing to $num for $firstrp - $lastrp\n";
					}
				}
				print qq#    <Train Num="$num">\n#;
				print qq#     <Pt R5="0"/>\n# for 0 .. $firstindex - 1;
				for my $i ($firstindex .. $lastindex) {
					my ($a, $d) = map { int(($_ + 15) / 60) * 2 } @{$rpdata[$i]};
					my $flags = 16; # display number
					$flags |= 512 if ($i == $firstindex or $i == $lastindex) and $rps[$i] ne $state[$id]{'last_written_gid'};
					$flags |= 768 if $state[$id]{'route_start'} eq $rps[$i] or $state[$id]{'route_end'} eq $rps[$i];
					print qq#     <Pt R5="0" P="$a" O="$d" F="$flags"/>\n#;
				}
				print qq#     <Pt R5="0"/>\n# for $lastindex + 1 .. $#rps;
				print qq#    </Train>\n#;
			}
		}
		print qq#   </Trains>\n#;
	}
	print unless $skip;
	$skip = 0 if m#</Trains>#;
}
close $G;