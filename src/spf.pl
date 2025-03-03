#! /usr/local/bin/perl -Tw
#
# This tool can expand and report on the given domains SPF use.
# This is accomplished by (possibly recursive) inspection of the DNS
# TXT records in question.
#
# Originally written in July 2022 by Jan Schaumann <jschauma@netmeister.org>.

use 5.008;

use strict;
use File::Basename;
use Getopt::Long;
Getopt::Long::Configure("bundling");

use JSON;

use Socket qw(PF_UNSPEC PF_INET PF_INET6 SOCK_STREAM inet_ntoa);
use Socket6;

use Net::DNS;
use Net::Netmask;


###
### Constants
###

use constant TRUE => 1;
use constant FALSE => 0;

use constant EXIT_FAILURE => 1;
use constant EXIT_SUCCESS => 0;

use constant MAXLOOKUPS => 10;

# RFC7208, Section 3.4
use constant MAXLENGTH => 450;

###
### Globals
###

my %OPTS = ( v => 0 );
my $PROGNAME = basename($0);
my $RETVAL = 0;
my $VERSION = 0.6;

# The final result in json representation:
# {
#   "query"    : "input domain",
#   "expanded" : {
#     "<domain>": {
#       "all"     : mechanism,
#       "errors"  : [ error, error, ...],
#       "parents  : [ domain, domain, ...],
#       "pass"    : {
#         "a"       : {
#           "cidrs"      : [ cidr, cidr, ...],
#           "ips"        : [ ip, ip, ...],
#           "names"      : [ name, name, ...],
#           "directives" : [ a, a, ...],
#         },
#         "cidrs"        : [ cidr, cidr, ...],
#         "count"   : {
#           "a-cidrs"       : count-of-a-cidrs,
#           "a-directives"  : count-of-mx-names,
#           "a-names"       : count-of-a-names,
#           "exists"        : count-of-exists,
#           "exp"           : count-of-exp,
#           "include"       : count-of-includes,
#           "ip4"           : count-of-v4-cidrs,
#           "ip4count"      : count-of-all-v4-ips,
#           "ip6"           : count-of-v6-cidrs,
#           "ip6count"      : count-of-all-v6-ips,
#           "mx-cidrs"      : count-of-mx-cidrs,
#           "mx-directives" : count-of-mx-names,
#           "mx-names"      : count-of-mx-names,
#           "ptr"           : count-of-ptrs,
#         },
#         "exists"  : [ domain-spec, domain-spec, ...],
#         "exp"     : [ domain-spec, domain-spec, ...],
#         "include" : [ domain, domain, ... ],
#         "ip4"     : [ IP, IP, IP, ... ],
#         "ip6"     : [ IP, IP, IP, ... ],
#         "mx"      : {
#           "cidrs"      : [ cidr, cidr, ...],
#           "ips"        : [ ip, ip, ...],
#           "names"      : [ name, name, ...],
#           "directives" : [ mx, mx, ...],
#         },
#         "ptr"     : [ domain, domain, ...],
#         "redirect": domain,
#         "total" : {    present if the domain contains an include
#           "a-cidrs"           : count-of-a-cidrs,
#           "a-directives"      : count-of-mx-names,
#           "exists"            : [ domain, domain, ...],
#           "exp"               : [ domain, domain, ...],
#           "include"           : [ domain, domain, ...],
#           "include-directives : count,
#           "ip4"               : [ cidr, cidr, ...],
#           "ip4-directives     : count,
#           "ip4count"          : count of all IPs,
#           "ip6"               : [ cidr, cidr, ...],
#           "ip6-directives     : count,
#           "ip6count"          : count of all IPs,
#           "ptr"               : [ ptr, ptr, ...],
#           "redirect"          : [ domain, domain, ...],
#          },
#       },
#       "neutral" : {
#         as above
#       }
#       "softfail": {
#         as above
#       }
#       "fail"    : {
#         as above
#       }
#       "spf"     : "SPF record for the domain",
#       "valid"   : valid|invalid
#       "warnings": [ warning, warning, ...],
#     },
#     "<domain2>" : {
#       for each include/redirect, a full object as for 'domain' above
#     },
#   }
# }
my %RESULT;

# This is super-yanky: the RFC says there shouldn't be more than 10
# *additional* lookups, i.e., not including the initial first TXT
# record lookup.  So instead of setting our MAX to 11 or some other
# shenanigans, we'll start with -1 instead.
$RESULT{"lookups"} = -1;

###
### Subroutines
###

sub addTopCountsByQualifier($);
sub addTopCountsByQualifier($) {
	my ($domain) = @_;

	verbose("Adding up top counts by qualifier for query '$domain'...", 1);

	if (!defined($RESULT{"expanded"}{$domain})) {
		return;
	}

	if ($RESULT{"state"}{"counted"}{$domain}) {
		return;
	}
	$RESULT{"state"}{"counted"}{$domain} = 1;

	my $top = $RESULT{"query"};
	my %domainData = %{$RESULT{"expanded"}{$domain}};

	if (defined($domainData{"redirect"})) {
		my $d = $domainData{"redirect"};
		verbose("Encountered redirect...", 2);
		if (defined($RESULT{"redirect"}{$d})) {
			return;
		}

		$RESULT{"redirect"}{$d} = 1;
	}

	foreach my $q (qw/fail neutral pass softfail/) {
		if (!defined($domainData{$q})) {
			next;
		}

		countIPs($domain, $q);

		if (defined($domainData{$q}{"count"})) {
			my %counts = %{$domainData{$q}{"count"}};

			foreach my $k (grep(!/-directives/, keys(%counts))) {
				$RESULT{"expanded"}{$domain}{$q}{"total"}{$k} = $counts{$k};
			}
		}
	}
}

sub addTotalsFromDomainToParent($$$) {
	my ($domain, $q, $parent) = @_;

	my $msg = "Adding up '$q' totals for ";
	if ($parent eq "top") {
		$msg .= "top domain '$parent'";
	} else {
		$msg .= "included domain '$domain' to '$parent'";
	}

	verbose("$msg...", 2);

	if ($parent ne "top") {
		if (defined($RESULT{"expanded"}{$domain}{"warnings"})) {
			foreach my $w (@{$RESULT{"expanded"}{$domain}{"warnings"}}) {
				$RESULT{"state"}{$parent}{"warnings"}{$w} = 1;
			}
			my @warnings= keys(%{$RESULT{"state"}{$parent}{"warnings"}});
			$RESULT{"expanded"}{$parent}{"warnings"} = \@warnings;
		}

		# If an invalid included policy encounters an error, it returns an error
		if ($RESULT{"expanded"}{$domain}{"valid"} eq "invalid") {
			$RESULT{"expanded"}{$parent}{"valid"} = "invalid";
			if (defined($RESULT{"expanded"}{$domain}{"errors"})) {
				foreach my $e (@{$RESULT{"expanded"}{$domain}{"errors"}}) {
					$RESULT{"state"}{$parent}{"errors"}{$e} = 1;
				}
			}
			my @errors = keys(%{$RESULT{"state"}{$parent}{"errors"}});
			$RESULT{"expanded"}{$parent}{"errors"} = \@errors;
		# ...but we still want to count results, so we continue.
		}

		# Only explicit "pass" from the included domain are added.
		if (!defined($RESULT{"expanded"}{$domain}{"pass"}{"count"})) {
			# No "pass", so nothing to add.
			return;
		}
	} else {
		$parent = $domain;
	}

	my (%count, %total);
	if (defined($RESULT{"expanded"}{$parent}{$q}{"total"})) {
		%total = %{$RESULT{"expanded"}{$parent}{$q}{"total"}};
	}

	if (!defined($RESULT{"expanded"}{$domain}{$q}{"count"})) {
		return;
	}

	my %child = %{$RESULT{"expanded"}{$domain}{$q}};
	my %childCount = %{$child{"count"}};

	foreach my $which (qw/exists exp include ip4 ip6/) {
		$total{$which} = mergeArrays($child{$which}, $total{$which});
		if (defined($child{"total"})) {
			$total{$which} = mergeArrays($child{"total"}{$which}, $total{$which});
		}
	}

	foreach my $which (qw/a mx/) {
		foreach my $sub (qw/cidrs directives ips names/) {
			if (!defined($childCount{$which}{$sub})) {
				next;
			}
			$total{"${which}-${sub}"} = mergeArrays($child{$which}{$sub}, $total{"${which}-${sub}"});
			if (defined($child{"total"})) {
				$total{"${which}-${sub}"} = mergeArrays($child{"total"}{"${which}-${sub}"}, $total{$which});
			}
		}
	}

	$RESULT{"expanded"}{$parent}{$q}{"total"} = \%total;

	if (defined($child{"cidrs"})) {
		my $new = $child{"cidrs"};
		my $old = $RESULT{"expanded"}{$parent}{$q}{"cidrs"};
		$RESULT{"expanded"}{$parent}{$q}{"cidrs"} = mergeArrays($new, $old);
	}

	if ($parent eq "top") {
		$parent = $domain;
	}
	addTopCountsByQualifier($parent);
}

sub createCount($$) {
	my ($domain, $q) = @_;

	if (!defined($RESULT{"expanded"}{$domain}{$q})) {
		return;
	}

	verbose("Creating counts for '$domain' ($q)...", 2);

	my %info = %{$RESULT{"expanded"}{$domain}{$q}};
	my %count;
	foreach my $which (qw/exists exp include ip4 ip6/) {
		if (!defined($info{$which})) {
			next;
		}
		my @a = @{$info{$which}};
		$count{$which} = scalar(@a);
	}
	foreach my $which (qw/a mx/) {
		foreach my $sub (qw/cidrs directives ips names/) {
			if (!defined($info{$which}{$sub})) {
				next;
			}
			my @a = @{$info{$which}{$sub}};
			$count{"${which}-${sub}"} = scalar(@a);
		}
	}

	$RESULT{"expanded"}{$domain}{$q}{"count"} = \%count;
}

sub countIPs($$) {
	my ($domain, $q) = @_;

	verbose("Counting IPs for '$domain' ($q)...", 3);

	if (!defined($RESULT{"expanded"}{$domain}{$q})) {
		return;
	}

	my %data = %{$RESULT{"expanded"}{$domain}{$q}};

	my %cidrs;
	foreach my $which (qw/a mx/) {
		if (defined($data{$which}{"ips"})) {
			foreach my $ip (@{$data{$which}{"ips"}}) {
				if ($ip =~ m/:/) {
					$cidrs{"${ip}/128"} = 1;
				} else {
					$cidrs{"${ip}/32"} = 1;
				}
			}
		}
		if (defined($data{$which}{"cidrs"})) {
			foreach my $c (@{$data{$which}{"ips"}}) {
				$cidrs{$c} = 1;
			}
		}
	}

	foreach my $ipv (qw/ip4 ip6/) {
		if (defined($data{$ipv})) {
			foreach my $c (@{$data{$ipv}}) {
				$cidrs{$c} = 1;
			}
		}
	}

	foreach my $c (@{$data{"cidrs"}}) {
		$cidrs{$c} = 1;
	}

	my $href = dedupeCIDRs(\%cidrs);
	my @uniqueCIDRs = keys(%{$href});
	$data{"cidrs"} = \@uniqueCIDRs;

	my $prevCIDRCount = 0;
	if (defined($RESULT{"state"}{"countIPs"}{$domain}{$q})) {
		$prevCIDRCount = $RESULT{"state"}{"countIPs"}{$domain}{$q};
	}

	if (scalar(@uniqueCIDRs) <= $prevCIDRCount) {
		return;
	}

	$data{"count"}{"ip6count"} = 0;
	$data{"count"}{"ip4count"} = 0;
	foreach my $c (@uniqueCIDRs) {
		my $count = getCIDRCount($c);
		if ($count < 0) {
			spfError("Invalid CIDR '$c' for domain '$domain' found.", $domain);
			next;
		}

		if ($c =~ m/:/) {
			$data{"count"}{"ip6count"} += $count;
		} else {
			$data{"count"}{"ip4count"} += $count;
		}
	}

	if ($domain eq $RESULT{"query"}) {
		foreach my $ipv (qw/ip4 ip6/) {
			$RESULT{"expanded"}{$domain}{$q}{"total"}{"${ipv}count"} = $data{"count"}{"${ipv}count"};
		}
	}

	$RESULT{"expanded"}{$domain}{$q} = \%data;
	$RESULT{"state"}{"countIPs"}{$domain}{$q} = scalar(@uniqueCIDRs);
}


sub dedupeCIDRs($) {
	my ($href) = @_;

	my (%blocks, %allblocks);
	my %cidrs = %{$href};

	foreach my $v (qw/v4 v6/) {
		my @which = grep(!/:/, keys(%cidrs));
		if ($v eq "v6")  {
			@which = grep(/:/, keys(%cidrs));
		}
		foreach my $c (@which) {
			my $b = Net::Netmask->new2($c);
			if (!$b) {
				next;
			}
			push(@{$allblocks{$v}}, $b);
		}

		my @b = cidrs2cidrs(@{$allblocks{$v}});
		foreach my $b (@b) {
			$blocks{$b} = 1;
		}
	}

	return \%blocks;
}

sub error($;$) {
	my ($msg, $err) = @_;

	warning($msg, "Error");

	$RETVAL++;
	if ($err) {
		exit($err);
		# NOTREACHED
	}
}

sub expandAorMX($$$$$$) {
	my ($res, $domain, $q, $which, $sep, $spec) = @_;

	my $top = $RESULT{"query"};

	verbose("Expanding $which for domain '$domain'...", 2);
	$RESULT{"expanded"}{$domain}{$q}{"count"}{"${which}-directives"}++;
	$RESULT{"expanded"}{$top}{$q}{"total"}{"${which}-directives"}++;

	my (%directives, %result, %names, %ipaddrs);

	if (defined($RESULT{"expanded"}{$domain}{$q}{$which})) {
       		%result = %{$RESULT{"expanded"}{$domain}{$q}{$which}};
		%names = map { $_ => 1 } @{$result{"names"}};
		%directives = map { $_ => 1 } @{$result{"directives"}};

		if ($result{"ips"}) {
			%ipaddrs = map { $_ => 1 } @{$result{"ips"}};
		}
	}

	my $d = $which;
	if ($sep) {
		$d .= "${sep}${spec}";
	}
	$directives{$d} = 1;
	my @dirs = keys(%directives);
	$RESULT{"expanded"}{$domain}{$q}{$which}{"directives"} = \@dirs;

	my $cidr = "";
	my ($v4cidr, $v6cidr);
	($spec, $v4cidr, $v6cidr) = parseAMX($domain, $sep, $spec);
	if (!$spec) {
		return FALSE;
	}

	if ($spec =~ m/%/) {
		# RFC7208, Section 7 allows for macros;
		# we can't resolve those, so don't bother trying
		verbose("Not resolving '$spec' - macro expansion required.", 2);
	} else {
		if ($which eq "a") {
			$names{$spec} = 1;
			foreach my $ip (getIPs($res, $spec, $which)) {
				$ipaddrs{$ip} = 1;
			}

		} elsif ($which eq "mx") {
			incrementLookups("mx", $spec);

			my @mxs = mx($res, $spec);
			if (!scalar(@mxs)) {
				spfError("No MX record for domain '$spec' found.", $domain, "warn");
				# "TRUE" because the entry was well formatted.
				return TRUE;
			}

			if (scalar(@mxs) > 10) {
				# RFC7208, Section 4.6.4
				spfError("More than 10 MX records for domain '$spec' found.", $domain);
				return TRUE;
			}

			foreach my $rr (@mxs) {
				my $mx = $rr->exchange;
				$names{$mx} = 1;
				foreach my $ip (getIPs($res, $mx, $which)) {
					$ipaddrs{$ip} = 1;
				}
			}
		}
	}

	my @names = keys(%names);
	$RESULT{"expanded"}{$domain}{$q}{$which}{"names"} = \@names;

	my @iparray = keys(%ipaddrs);
	my ($old, $new);

	if ($v4cidr || $v6cidr) {
		$old = $RESULT{"expanded"}{$domain}{$q}{$which}{"cidrs"};
		$new = expandAMXCIDR($domain, $q, $which, \@iparray, $v4cidr, $v6cidr);
		if (!$new) {
			return TRUE;
		}

		$new = mergeArrays($new, $old);
		$RESULT{"expanded"}{$domain}{$q}{$which}{"cidrs"} = \@{$new};
	} else {
		$old = $RESULT{"expanded"}{$domain}{$q}{$which}{"ips"};
		$new = mergeArrays(\@iparray, $old);
		$RESULT{"expanded"}{$domain}{$q}{$which}{"ips"} = \@{$new};
	}

	return TRUE;
}

sub expandAMXCIDR($$$$$$) {
	my ($domain, $q, $which, $aref, $v4cidr, $v6cidr) = @_;

	if (!$v4cidr) {
		$v4cidr = 32;
	}
	if (!$v6cidr) {
		$v6cidr = 128;
	}

	my @cidrs;
	my $cidr = $v4cidr;
	foreach my $ip (@{$aref}) {
		if (inet_pton(PF_INET, $ip)) {
			push(@cidrs, "$ip/$v4cidr");
		} elsif (inet_pton(PF_INET6, $ip)) {
			push(@cidrs, "$ip/$v6cidr");
			$cidr = $v6cidr;
		} else {
			spfError("Invalid IP address $ip for '$domain'.", $domain);
			next;
		}
	}

	return \@cidrs;
}

sub expandCIDR($$$$) {
	my ($q, $domain, $ipv, $cidr) = @_;

	my $top = $RESULT{"query"};

	$RESULT{"expanded"}{$top}{$q}{"total"}{"${ipv}-directives"}++;
	$RESULT{"expanded"}{$domain}{$q}{"count"}{"${ipv}-directives"}++;

	if (!$cidr) {
		spfError("Invalid definition '$ipv:' for domain '$domain'.", $domain);
		return;
	}

	verbose("Expanding CIDR $ipv:$cidr for domain '$domain'...", 3);

	if ($cidr !~ m/\/[0-9]+$/) {
		if (!inet_pton(PF_INET, $cidr) && !inet_pton(PF_INET6, $cidr)) {
			spfError("Invalid IP '$cidr' for domain '$domain' found.", $domain);
			return;
		}
		if ($cidr =~ m/:/) {
			$cidr .= "/128";
		} else {
			$cidr .= "/32";
		}
	}

	my (%c, @cidrs);
	if (defined($RESULT{"expanded"}{$domain}{$q}{$ipv})) {
       		@cidrs = @{$RESULT{"expanded"}{$domain}{$q}{$ipv}};
		%c = map { $_ => 1 } @cidrs;
	}

	$c{$cidr} = 1;
	@cidrs = keys(%c);
       	$RESULT{"expanded"}{$domain}{$q}{$ipv} = \@cidrs;

	my $old = $RESULT{"expanded"}{$domain}{$q}{"cidrs"};
	$RESULT{"expanded"}{$domain}{$q}{"cidrs"} = mergeArrays(\@cidrs, $old);
}

sub expandGeneric($$$$) {
	my ($which, $domain, $qualifier, $dest) = @_;

	verbose("Expanding '$which' for domain '$domain'...", 2);

	my (@list, %hash);
	if (defined($RESULT{"expanded"}{$domain}{$qualifier}{$which})) {
       		@list = @{$RESULT{"expanded"}{$domain}{$qualifier}{$which}};
		%hash = map { $_ => 1 } @list;
	}

	$hash{$dest} = 1;

	@list = keys(%hash);
       	$RESULT{"expanded"}{$domain}{$qualifier}{$which} = \@list;
}

sub expandSPF($$$$);
sub expandSPF($$$$) {
	my ($res, $qualifier, $domain, $parent) = @_;

	my $msg = "Expanding SPF for '$domain' ($qualifier) ";
	if ($parent ne "top") {
		$msg .= "under '$parent'";
	}
	verbose("$msg...", 1);

	my $top = $RESULT{"query"};

	my %parents;
	if (defined($RESULT{"expanded"}{$domain}{"parents"})) {
		%parents = map { $_ => 1 } @{$RESULT{"expanded"}{$domain}{"parents"}};
		if ($parents{$parent}) {
			spfError("Recursive inclusion of '$domain'.", $domain);
			return;
		} elsif (defined($RESULT{"expanded"}{$domain})) {
			verbose("Already seen $domain.", 2);
			return;
		}
	}

	$RESULT{"expanded"}{$domain}{"valid"} = "valid";

	$parents{$domain} = 1;
	my @a = keys(%parents);
	$RESULT{"expanded"}{$domain}{"parents"} = \@a;

	my $spfText;

	if ($domain eq "none") {
		$spfText = matchSPF($OPTS{'p'}, $domain);
	} else {
		$spfText = getSPFText($res, $domain);
	}

	if (!$spfText) {
		if ($domain eq "none") {
			error("Invalid policy given: '" . $OPTS{'p'} . "'", EXIT_FAILURE);
		} elsif ($domain !~ m/%/) {
			# You can have a "include:<domain>" with macros;
			# those are valid, but 'getSPFText' would have returned
			# an empty string, so we need to check for this case here
			# and only mark as invalid domains that don't contain
			# macros.
			$RESULT{"expanded"}{$domain}{"valid"} = "invalid";
		}
		return;
	}

	$RESULT{"expanded"}{$domain}{"spf"} = $spfText;
	$RESULT{"expanded"}{$domain}{"all"} = "neutral (implicit)";

	my @directives = split(/ /, $spfText);
	my $n = 0;
	foreach my $entry (@directives) {
		verbose("Encountered '$entry' directive...", 2);
		my $q = $qualifier;
		$n++;
		if ($entry =~ m/^([+?~-])?(a|mx)(([:\/])(.*))?$/i) {
			if ($1) {
				$q = getQualifier($1);
			}
			my $which = $2;
			my $sep = $4;
			my $arg = $5;
			if (!expandAorMX($res, $domain, $q, $which, $sep, $arg)) {
				spfError("Invalid directive '$entry' for $domain.", $domain);
			}
		}
		elsif ($entry =~ m/^([+?~-])?all$/i) {
			if ($1) {
				$q = getQualifier($1);
			}

			$RESULT{"expanded"}{$domain}{"all"} = $q;
			if ($n != scalar(@directives) && ($directives[$n] !~ m/^exp=/)) {
				spfError("'all' directive is not last in '$domain' policy - ignoring all subsequent directives.", $domain, "warn");
				# RFC7208, Section 5.1:
				# Mechanisms after "all" will never be tested.
				# Mechanisms listed after "all" MUST be ignored.
				last;
			}
		}
		elsif ($entry =~ m/^([+?~-])?(ip[46]):(.*)$/i) {
			if ($1) {
				$q = getQualifier($1);
			}
			expandCIDR($q, $domain, $2, $3);
		}
		elsif ($entry =~ m/^([+?~-])?(include:|redirect=)(.*)$/i) {
			# "redirect" should not have a qualifier, but allowing it
			# here makes our regex easier
			if ($1) {
				$q = getQualifier($1);
			}
			my $type = $2;
			my $includedDomain = $3;
			chop($type);

			if ($type eq "include") {
				push(@{$RESULT{"expanded"}{$domain}{$q}{$type}}, $includedDomain);
			} else {
				if ($spfText =~ m/\b[+?~-]?all\b/) {
					spfError("Ignored 'redirect=$includedDomain' in '$domain' policy with 'all' statement", $domain, "warn");
					next;
				}
				$RESULT{"expanded"}{$domain}{"redirect"} = $includedDomain;
			}

			$RESULT{"expanded"}{$domain}{$q}{"count"}{"${type}-directives"}++;
			$RESULT{"expanded"}{$top}{$q}{"total"}{"${type}-directives"}++;
			expandSPF($res, $q, $includedDomain, $domain);
			addTotalsFromDomainToParent($includedDomain, $qualifier, $domain);

			if ($type eq "redirect") {
				$RESULT{"expanded"}{$domain}{"all"} = $RESULT{"expanded"}{$includedDomain}{"all"};
			}

		}
		elsif ($entry =~ m/^([+?~-])?(exists:|ptr:?|exp=)(.*)$/i) {
			if ($1) {
				$q = getQualifier($1);
			}
			my $type = $2;
			chop($type);

			$RESULT{"expanded"}{$domain}{$q}{"count"}{"${type}-directives"}++;
			$RESULT{"expanded"}{$top}{$q}{"total"}{"${type}-directives"}++;
			# Both exists and ptr have a lookup...
			if ($type ne "exp") {
				incrementLookups($type, $3);
			}

			# But ptr also leads to forward lookups, one for every
			# PTR record returned (and there may be many!), so we
			# add at least one more here.
			if ($type eq "ptr") {
				incrementLookups($type, $3);
			}
			expandGeneric($type, $domain, $q, $3);
		} elsif ($entry) {
			spfError("Unknown directive '$entry' for '$domain'.", $domain);
		}
	}

	if (defined($RESULT{"expanded"}{$domain}{"errors"})) {
		if ($domain eq "none") {
			my $msg = "  " . join("\n  ", @{$RESULT{"expanded"}{$domain}{"errors"}});
			error("Invalid policy given: '" . $OPTS{'p'} . "':\n$msg", EXIT_FAILURE);
		}

		$RESULT{"expanded"}{$domain}{"valid"} = "invalid";
	}

	foreach my $q (qw/pass neutral softfail fail/) {
		createCount($domain, $q);
	}
}

sub getCIDRCount($) {
	my ($cidr) = @_;

	if (defined($RESULT{"state"}{"cidrs"}{$cidr})) {
		return $RESULT{"state"}{"cidrs"}{$cidr};
	}

	my $size = 0;
	# Net::Netmask doesn't handle IPv4-mapped addresses.
	if ($cidr =~ m/::ffff:[0-9.]+(\/([0-9]+))/) {
		my $nm = $2;
		if (!$nm) {
			# Assume /128
			$size = 1;
		} else {
			my $n = 128 - $nm;
			$size = (2**$n);
		}
		$RESULT{"state"}{"cidrs"}{$cidr} = $size;
		return $size;
	}

	my $block = Net::Netmask->new2(lc($cidr));
	if (!$block) {
		return -1;
	}

	$size = $block->size();
	if ($cidr =~ m/:/) {
		$size = $size->numify();
	}

	$RESULT{"state"}{"cidrs"}{$cidr} = $size;
	return $size;
}

sub getIPs($$$) {
	my ($res, $domain, $parent) = @_;

	verbose("Looking up all IPs for '$domain'...", 3);

	my (%ips, %tmp);
	my $req;

	# We only do one increment here even though we perform two lookups
	# because when the mail server performs the lookup, it will only
	# perform a single lookup based on whether the client connected over
	# IPv4 or IPv6.
	#
	# In addition, IP lookups for MX results are (counter-intuitively)
	# _not_ counted.  See
	# https://mailarchive.ietf.org/arch/msg/spfbis/AFvCBHV_QkaifWJpVaA6FCg_VT8/.
	if ($parent ne "mx") {
		incrementLookups("a/aaaa", $domain);
	}

	foreach my $a (qw/A AAAA/) {
		$req = $res->send($domain, $a);
		if (!defined($req)) {
			error($res->errorstring);
		}

		foreach my $rr (grep($_->type eq $a, $req->answer)) {
			$ips{$rr->rdstring} = 1;
		}
	}

	return keys(%ips);
}

sub getQualifier($) {
	my ($q) = @_;

	my $qualifier = "pass";
	if ($q) {
		if ($q eq "?") {
			$qualifier = "neutral";
		} elsif ($q eq "~") {
			$qualifier = "softfail";
		} elsif ($q eq "-") {
			$qualifier = "fail";
		}
	}

	return $qualifier;
}
	
sub getSPFText($$) {
	my ($res, $domain) = @_;

	verbose("Looking up SPF records for domain '$domain'...", 1);

	incrementLookups("txt", $domain);

	if ($domain =~ m/%/) {
		# RFC7208, Section 7 allows for macros;
		# we can't resolve those, so don't bother trying
		verbose("Ignoring '$domain' - macro expansion required.", 2);
		return;
	}

	my $req = $res->send($domain, "TXT");
	if (!defined($req)) {
		error($res->errorstring);
		return;
	}

	if ($req->header->ancount < 1) {
		my $errmsg = "No TXT record found for '$domain'.";
		if ($res->errorstring ne "NOERROR") {
			$errmsg = "Unable to look up TXT record for '$domain'; nameserver returned " . $res->errorstring . ".";
		}
		if ($domain eq $RESULT{"query"}) {
			error($errmsg, EXIT_FAILURE);
			# NOTREACHED
		}
		spfError($errmsg, $domain, "warn");
		return;
	}

	my $spf;
	foreach my $rr ($req->answer) {

		# e.g., CNAME
		if ($rr->type ne 'TXT') {
			next;
		}
		my $tmp;
		my $s = join("", $rr->txtdata);
		$s =~ s/"//g;
		$s =~ s/[	\n"]//gi;
		$tmp = matchSPF($s, $domain);

		if ($tmp) {
			if ($spf) {
				spfError("Multiple SPF policies found for '$domain'.", $domain);
				last;
			}
			$spf = $tmp;
		}
	}

	if (!$spf) {
		my $errmsg = "No SPF record found for '$domain'.";;
		if ($domain eq $RESULT{"query"}) {
			error($errmsg, EXIT_FAILURE);
			# NOTREACHED
		}
		spfError($errmsg, $domain, "warn");
		return;
	}

	$spf =~ s/[\n"]//gi;
	$spf =~ s/\s+/ /g;

	return $spf;
}

sub getResolver($) {
	my ($r) = @_;
	my @resolvers;

	my $ip = inet_pton(PF_INET, $r);
	my $ip6 = inet_pton(PF_INET6, $r);

	if ($ip || $ip6) {
		if ($r =~ m/(.*)/) {
			push(@resolvers, $1);
		}
	} else {
		my @res = getaddrinfo($r, 'domain', PF_UNSPEC, SOCK_STREAM);
		while (scalar(@res) >= 5) {
			my ($family, $addr);
			($family, undef, undef, $addr, undef, @res) = @res;
			my ($host, undef) = getnameinfo($addr, NI_NUMERICHOST | NI_NUMERICSERV);
			# untaint
			if ($host =~ m/(.*)/) {
				push(@resolvers, $1);
			}
		}
	}

	return @resolvers;
}


sub getTotalCIDRCount($) {
	my ($aref) = @_;
	my $count = 0;

	my %cidrs = map { $_ => 1 } @{$aref};

	my $href = dedupeCIDRs(\%cidrs);
	my @uniqueCIDRs = keys(%{$href});

	foreach my $c (@uniqueCIDRs) {
		$count += getCIDRCount($c);
	}
	return $count;
}

sub incrementLookups($$) {
	my ($rr, $d) = @_;

	verbose("DNS lookup of type '$rr' for $d...", 2);

	$RESULT{"lookups"}++;
}

sub init() {
	my ($ok);

	if (!scalar(@ARGV)) {
		error("I have nothing to do.  Try -h.", EXIT_FAILURE);
		# NOTREACHED
	}

	$ok = GetOptions(
			 "expand|e" 	=> \$OPTS{'e'},
			 "help|h" 	=> \$OPTS{'h'},
			 "json|j" 	=> \$OPTS{'j'},
			 "policy|p=s"   => \$OPTS{'p'},
			 "resolver|r=s"	=> \$OPTS{'r'},
			 "verbose|v+" 	=> sub { $OPTS{'v'}++; },
			 "version|V"	=> sub {
			 			print "$PROGNAME: $VERSION\n";
						exit(EXIT_SUCCESS);
			 		}
			 );

	if ($OPTS{'h'} || !$ok) {
		usage($ok);
		exit(!$ok);
		# NOTREACHED
	}

	if (((scalar(@ARGV) != 1) && (!$OPTS{'p'})) ||
		       (scalar(@ARGV) && $OPTS{'p'})) {
		error("Please specify exactly one domain or policy.", EXIT_FAILURE);
		# NOTREACHED
	}

	if (!$OPTS{'p'}) {
		$OPTS{'domain'} = $ARGV[0];
	} else {
		$OPTS{'domain'} = "none";
	}
}

sub main() {
	my $domain = $OPTS{'domain'};
	$RESULT{"query"} = $domain;

	my %resolver_opts;
       
	if ($OPTS{'v'} > 3) {
		$resolver_opts{'debug'} = 1;
	}

	if ($OPTS{'r'}) {
		my @resolvers = getResolver($OPTS{'r'});
		$resolver_opts{'nameservers'} = \@resolvers;
	}

	my $res = Net::DNS::Resolver->new(%resolver_opts);
	expandSPF($res, "pass", $domain, "top");
	foreach my $q (qw/pass neutral softfail fail/) {
		addTotalsFromDomainToParent($domain, $q, "top");
		countIPs($domain, $q);
	}

	my $n = $RESULT{"lookups"};
	if ($n > MAXLOOKUPS) {
		my $err = "Too many DNS lookups ($n > " . MAXLOOKUPS . ").";
		spfError($err, $domain);
	}
}

sub matchSPF($$) {
	my ($txt, $domain) = @_;
	my $spf;

	if ($txt =~ m/^"?v=spf1 (.*)/si) {
		my $l = length($txt);
		if ($l > MAXLENGTH) {
			spfError("SPF record for '$domain' too long ($l > " . MAXLENGTH . ").", $domain, "warn");
		}
		$spf = $1;
	}

	return $spf;
}

sub mergeArrays($$) {
	my ($new, $old) = @_;
	my %h = map { $_ => 1 } (@{$old}, @{$new});
	my @keys = keys(%h);
	return \@keys;
}

sub parseAMX($$$) {
	my ($domain, $sep, $spec) = @_;

	# Possible mechanisms for a and mx (by example of mx):
	# mx -- use $domain
	if (!defined($spec)) {
		# invalid: "mx:" or "mx/"
		if (defined($sep)) {
			return (undef, undef, undef);
		}
		$spec = $domain;
		return ($spec, undef, undef);
	}

	# mx:dom/4cidr//6cidr -- use $dom, then add cidr to each IP
	# mx:dom//6cidr -- use $dom, then add cidr to each IP
	# mx:dom/4cidr -- use $dom, then add cidr to each IP
	# mx:dom -- use $dom, no cidr
	if (($sep eq ":") && ($spec =~ m/^([^\/]+)(\/([0-9]+))?(\/\/([0-9]+))?$/)) {
		my $dom = $1;
		my $v4 = $3;
		my $v6 = $5;
		if (($v4 && $v4 > 32) || ($v6 && $v6 > 128)) {
			return (undef, undef, undef);
		}
		return ($dom, $v4, $v6);
	}

	if ($sep eq "/") {
		# mx//6cidr
		if ($spec =~ m/^\/([0-9]+)$/) {
			return ($domain, undef, $1);
		}
		# mx/4cidr//6cidr
		# mx/4cidr
		if ($spec =~ m/^([0-9]+)(\/\/([0-9]+))?$/) {
			return ($domain, $1, $3);
		}
	}

	# everything else is a syntax error
	return (undef, undef, undef);
}

sub printAMXStat($$$$) {
	my ($space, $which, $type, $aref) = @_;
	my @array = @{$aref};

	my $n = scalar(@array);
	if ($n < 1) {
		return;
	}

	printf("%s%s (%s %s%s):\n", $space, $which, $n, $type, $n > 1 ? "s" : "");
	print "$space  " . join("\n$space  ", sort(@array)) . "\n";
	print "\n";
}

sub printArray($$$) {
	my ($name, $aref, $indent) = @_;

	if (!defined($aref)) {
		return;
	}

	my $n = scalar(@{$aref});
	my $space = "  " x ($indent + 1);
	printf("%s%s (%s domain%s):\n", $space, $name, $n,
			$n > 1 ? "s" : "");
	print "$space  " . join("\n$space  ", sort(@{$aref})) . "\n";
	print "\n";
}

sub printExpanded($$);
sub printExpanded($$) {
	my ($domain, $indent) = @_;

	if (!defined($RESULT{"expanded"}{$domain})) {
		return;
	}

	if (defined($RESULT{"seen"}{$domain})) {
		return;
	}

	$RESULT{"seen"}{$domain} = 1;

	if (!defined($RESULT{"expanded"}{$domain}{"spf"})) {
		# e.g., a macro domain
		return;
	}

	print "  " x ($indent - 1);
	print "$domain:\n";
	print "  " x $indent;
	print "policy:\n";
	print "  " x ($indent + 1);
	print $RESULT{"expanded"}{$domain}{"spf"} . "\n";
	print "\n";

	print "  " x $indent;
	print $RESULT{"expanded"}{$domain}{"valid"} . "\n";
	printWarningsAndErrors($indent, $domain);

	my $space = "  " x $indent;
	if (defined($RESULT{"expanded"}{$domain}{"redirect"})) {
		my $r = $RESULT{"expanded"}{$domain}{"redirect"};
		print "${space}redirect: $r\n";
		print "\n";
		printExpanded($r, $indent + 2);
		print "\n";
	}

	$space = "  " x ($indent + 1);

	foreach my $qual (qw/pass neutral softfail fail/) {
		my $i = $RESULT{"expanded"}{$domain}{$qual};
		if (!defined($i) || !scalar(keys(%{$i}))) {
			next;
		}
		my %info = %{$i};

		print "  " x $indent;
		print "$qual:\n";

		foreach my $i (qw/exists exp include ptr/) {
			printArray($i, $info{$i}, $indent);
		}

		foreach my $ipv (qw/ip4 ip6/) {
			if (!defined($info{$ipv})) {
				next;
			}
			my @cidrs = @{$info{$ipv}};
			my $cnum = scalar(@cidrs);
			my $inum = getTotalCIDRCount(\@cidrs);
			printf("%s%s (%s CIDR%s / %s IP%s):\n",
						$space, $ipv, $cnum,
						$cnum > 1 ? "s" : "",
						$inum,
						$inum > 1 ? "s" : "");

			# Yes, sort() isn't quite right for CIDRs, but good enough.
			print "$space  " . join("\n$space  ",  sort(@cidrs)) . "\n";
			if (($ipv eq "ip4") && (defined($info{"ip6"}))) {
				print "\n";
			}
			print "\n";
		}

		foreach my $m (qw/a mx/) {
			if (defined($info{$m})) {
				my (%h, @n, @i, @c);
				my ($nnum, $inum, $cnum) = (0, 0, 0);

				%h = %{$info{$m}};
				if (defined($h{"names"})) {
					@n = @{$h{"names"}};
					$nnum = scalar(@n);
					printAMXStat($space, $m, "name", \@n);
				}
				if (defined($h{"ips"})) {
					@i = @{$h{"ips"}};
					$inum = scalar(@i);
					printAMXStat($space, $m, "IP", \@i);
				}
				if (defined($h{"cidrs"})) {
					@c = @{$h{"cidrs"}};
					$cnum = scalar(@c);
					printAMXStat($space, $m, "CIDR", \@c);
				}
			}
		}

		foreach my $i (@{$info{"include"}}) {
			if ($RESULT{"expanded"}{$i}{"valid"} eq "valid") {
				printExpanded($i, $indent + 2);
				print "\n";
			}
		}
	}

	print "  " x $indent;
	print "All others: " . $RESULT{"expanded"}{$domain}{"all"} . "\n";
}

sub printCount($$$) {
	my ($href, $domain, $q) = @_;

	if (!defined($href)) {
		return;
	}

	my %stats = %{$href};

	foreach my $s (qw/a exists exp include mx ptr redirect/) {
		if (defined($stats{"${s}-directives"})) {
			print "    ";
			printf("Total # of '%s' directives%s: ", $s, " " x (length("redirect") - length($s)));
			print $stats{"${s}-directives"} . "\n";
		}
	}
	foreach my $ipv (qw/ip4 ip6/) {
		if ($stats{"${ipv}-directives"}) {
			print "    ";
			print "Total # of $ipv directives       : ";
			print $stats{"${ipv}-directives"} . "\n";
		}
		if ($stats{"${ipv}count"}) {
			print "    ";
			print "Total # of $ipv addresses        : ";
			print $stats{"${ipv}count"} . "\n";
		}
	}

	print "\n";
}

sub printResults() {
	my $domain = $RESULT{"query"};

	if (!defined($RESULT{"expanded"}{$domain})) {
		return;
	}

	printExpanded($domain, 1);

	print "\n";
	my $m = "SPF record for domain '$domain': ";
	if ($domain eq "none") {
		$m = "Given SPF record                  : ";
	}

	print $m . $RESULT{"expanded"}{$domain}{"valid"} . "\n";
	printWarningsAndErrors(0, $domain);

	print "Total counts:\n";
	if ($RESULT{"lookups"} > 0) {
		print "  Total # of DNS lookups            : " . $RESULT{"lookups"} . "\n\n";
	}

	foreach my $q (qw/pass neutral softfail fail/) {
		if (!defined($RESULT{"expanded"}{$domain}{$q}{"total"})) {
			next;
		}

		my %stats = %{$RESULT{"expanded"}{$domain}{$q}{"total"}};
		if (!scalar(keys(%stats)) > 0) {
			next;
		}

		print "  $q:\n";
		printCount(\%stats, $domain, $q);
	}
	print "All others: " . $RESULT{"expanded"}{$domain}{"all"} . "\n";
}

sub printWarningsAndErrors($$) {
	my ($indent, $domain) = @_;
	if (defined($RESULT{"expanded"}{$domain}{"warnings"})) {
		my $s = "  " x ($indent + 1) . "Warning: ";
		print "$s" . join("\n$s", @{$RESULT{"expanded"}{$domain}{"warnings"}}) . "\n";
	}
	if (defined($RESULT{"expanded"}{$domain}{"errors"})) {
		my $s = "  " x ($indent + 1) . "Error: ";
		print "$s" . join("\n$s", @{$RESULT{"expanded"}{$domain}{"errors"}}) . "\n";
	}
	print "\n";
}


sub spfError($$;$) {
	my ($msg, $domain, $warn) = @_;

	if (!$warn) {
		$RESULT{"state"}{$domain}{"errors"}{$msg} = 1;
		my @errors = keys(%{$RESULT{"state"}{$domain}{"errors"}});
		$RESULT{"expanded"}{$domain}{"errors"} = \@errors;
		$RESULT{"expanded"}{$domain}{"valid"} = "invalid";
	} else {
		$RESULT{"state"}{$domain}{"warnings"}{$msg} = 1;
		my @warnings= keys(%{$RESULT{"state"}{$domain}{"warnings"}});
		$RESULT{"expanded"}{$domain}{"warnings"} = \@warnings;
	}
}

sub usage($) {
	my ($err) = @_;

	my $FH = $err ? \*STDERR : \*STDOUT;

	print $FH <<EOH
Usage: $PROGNAME [-Vhjv] [-r address] -p policy | domain
        -V          print version information and exit
	-h          print this help and exit
	-j          print output in json format
	-p polіcy   expand the given policy
	-r address  explicitly query this resolver
	-v          increase verbosity
EOH
	;
}

sub verbose($;$) {
	my ($msg, $level) = @_;
	my $char = "=";

	return unless $OPTS{'v'};

	$char .= "=" x ($level ? ($level - 1) : 0 );

	if (!$level || ($level <= $OPTS{'v'})) {
		print STDERR "$char> $msg\n";
	}
}

sub warning($;$) {
	my ($msg, $note) = @_;

	if (!$note) {
		$note = "Warning";
	}

	if (!$OPTS{'q'}) {
		print STDERR "$PROGNAME: $note: $msg\n";
	}
}


###
### Main
###

init();

main();

if ($OPTS{'j'}) {
	my $json = JSON->new;
	delete($RESULT{"state"});
	print $json->pretty->encode(\%RESULT);
} else {
	printResults();
}

#use Data::Dumper;
#print Data::Dumper::Dumper \%RESULT;

exit($RETVAL);
