package Text::Unicode::Equivalents;

use strict;
use warnings;
use utf8;
use Unicode::Normalize qw(NFD getCanon getComposite getCombinClass);
use Unicode::UCD;
use Encode;
use Carp;

require 5.8.0;		# Had some trouble with Unicode character handling in 5.6.

require Exporter;

our @ISA = qw(Exporter);
our @EXPORT_OK = qw( all_strings );

our $VERSION = '0.05';	#   RMH 2011-06-27
#	Changes to Makefile.PL and tests.t to improve portability
#   Added comments about \X being different on 5.10 vs 5.12
# our $VERSION = '0.04';	#   RMH 2011-06-27
#	Perl 5.14 doesn't have unicore/UnicodeData.txt, so changing to use unicode/Decomposition.pl
# our $VERSION = '0.03';	#   RMH 2011-06-24
#   Change module name to Text::Unicode::Equivalents -- more acceptable to CPAN
#   Eliminate all but one public function, which is renamed all_strings()
#   Previous version didn't synthesize singletons
#   Eliminate hard-coding of %nonStarterComposites
#   Eliminate $ignoreSingletons parameter -- not very useful and implementation was squirrely anyay
# our $VERSION = '0.02';	#   RMH 2004-11-08
#   Added equivalents()
#   Rewrote permuteCompositeChar() so composes medial sequences as well as initial
#   As a result, it now composes 0308+0301 -> 0344
# our $VERSION = '0.01';	#   RMH 2003-05-02     Original

=head1 NAME

Text::Unicode::Equivalents - synthesize canonically equivalent strings

=head1 SYNOPSIS

	use Text::Unicode::Equivalents qw( all_strings);
	
	$aref = all_strings ($string);
	map {print "$_\n"} @{$aref};
	
=head1 DESCRIPTION

=cut

# The two things I can't seem to make the Unicode module do are to (1) compose two diacritics, e.g.,
# <0308+0301> => 0344 (Unicode calls such decompositions "non-starters" and won't compose them) and
# (2) *compose* a singleton.  So I use unicore/Decomposition.pl to generate two hashes:

my %sSingletonCompositions;	# keyed by single character string; returns its singleton composite, as a string.
my %cpNonStarterComposites;	# keyed by two-character string that has a non-starter composition; returns codepoint of the composite.

=over

=item all_string($s)

Given an arbitrary string, C<all_strings()> 
returns a reference to an unsorted array of all unique strings that are canonically
equivalent to the argument. 

=cut

sub all_strings
{
	my ($s, $trace) = @_;
	my $i;
	
	# If string starts with combining mark, prefix space so we get a proper cluster:
	my $spaceAdded;
	if ($s =~ /^\pM/)
	{
		$s = ' ' . $s ;
		$spaceAdded = 1;
	}
	
	# Split string into Extended Grapheme Clusters 
	
	# NB:
	# on Perl prior to v5.12, \X matches Unicode "combining character sequence", equivalent to (?>\PM\pM*)
	# on Perl v5.12 and later, \X matches Unicode "eXtended grapheme cluster"
	# Thus \X matches combining hangul jamo sequence such as "\x{1100}\x{1161}\x{11a8}" on 12.0, but not 10.1
	
	my @clusters = ($s =~ m/(\X)/g);	
	
	# Generate all canonically equivalent permutation of each cluster:
	for $i (0 .. $#clusters)
	{
		$clusters[$i] = _permute_cluster ($clusters[$i], $trace);
		# Note: result is a reference to an array!
	}
	
	# Now rebuild all possible combinations of the clusters:
	my $res = _generator (\@clusters);
	if ($spaceAdded)
	{
		# Need to remove that leading space from each:
		foreach $i (0 .. $#{$res})
		{
			$res->[$i] =~ s/^ //o;
		}
	}
	if ($trace)
	{
		map { printMessage ($_) } @$res;
	}
	
	return $res;
}

# Given a reference to a list of arrays of strings, C<generator()> returns reference to an unsorted list 
# of all strings that can be generated by concatenating together one string from each array in the list.

sub _generator
{
	my ($a,				# Initial parameter
	    $res, $i, $s	# Parameters used in recursion
	    ) = @_;
	unless ($res)
	{
		$res = {};
		$i = 0;
		$s = '';
	}
	if ($i > $#{$a})
	{
		$res->{$s} = 1;
	}
	else
	{
		foreach (@{$a->[$i]})
		{
			_generator ($a, $res, $i+1, $s . $_);
		}
	}
	return if $i > 1;
	return [ keys %{$res} ];
}	


# Given an L<Extended Grapheme Cluster|http://unicode.org/glossary/#extended_grapheme_cluster>
# (EGC) C<_permute_cluster()> returns a reference to an unsorted array of all unique strings that
# are canonically equivalent to the EGC
#
# returns undef if the parameter is not an EGC, i.e. does not match C</^\X$/>.

# Implemented by brute force evaluation of all permutations so isn't too clever.
# Could be made more efficient, but since EGCs are short the inefficiency isn't huge.

sub _permute_cluster {
	my ($s, $trace) = @_;
	
	# make sure argument is an EGC
	return undef unless $s =~ /^\X$/;
	
	# retrieve required data from UnicodeData.txt
	_getCompositions() unless %cpNonStarterComposites;
	
	my %res;	# Place to keep result strings (as keys so we eliminate duplicates)

	# compute and save NFD of original -- we'll use it to tell whether a candidate
	# is canonically equivalent to the original.
	my $origNFD = NFD($s);
	
	# Start with fully decomposed string:
	$s = $origNFD;
	if (length($s) == 1)
	{
		# we can short-circuit the computation if the length of the decomposed string == 1
		if (exists $sSingletonCompositions{$s})
		{	return [ $s, $sSingletonCompositions{$s} ];	}
		else
		{	return [ $s ]; }
	}

	# pick up the base character 
	my $base = substr($s, 0, 1);

	# Now calculate all permutations of everything else. We'll figure out whether a given
	# permutation is canonically equivalent to the original in a minute.
	
	my %strList;
	map { $strList{$base . $_ } = 1} @{_permute(substr($s,1))};

	# Try every one of the generated permutations of marks:
	foreach $s (keys %strList)
	{
		next if NFD($s) ne $origNFD;	# Not equivalent to original -- ignore it.
		next if exists $res{$s};		# Already seen this sequence

		# Now the fun! Generate every possible sequence from $s by composing pairs and singletons:
		
		my @work = ( [$s, 0] );
		while ($#work >= 0)
		{
			my ($s, $i) = @{pop @work};
			printMessage ('POP:', $s, $i, length($s)) if $trace;
			if ($i >= length ($s))
			{
				# We've worked our way to the end of the string. At this point we have
				# some combination of composition and decomposition that should be equivalent
				# to the original!
				$res{$s} = 1;	# Here's a keeper!
			}
			else
			{
				push @work, [ $s, $i+1 ];
				if (exists $sSingletonCompositions{substr($s, $i, 1)})
				{
					# recompose this singleton and save result for work
					printMessage("SING at $i:", substr($s, $i, 1), ' -> ', $sSingletonCompositions{substr($s, $i, 1)}) if $trace;
					my $s2 = $s;
					substr($s2, $i, 1) = $sSingletonCompositions{substr($s, $i, 1)};
					push @work, [ $s2, $i ];
				}
				while ($i+1 < length($s))
				{
					# Try to combine two chars:
					my $s2 = substr($s, $i, 2);
					my ($u1, $u2) = unpack ( 'UU', $s2);
					my $u = getComposite($u1, $u2) || $cpNonStarterComposites{$s2};
					printMessage ("COMP at $i:", sprintf('%04X',$u1), sprintf('%04X',$u2), '->', defined $u ? sprintf('%04X',$u) : 'undef') if $trace;
					last unless defined $u;
					my $c = pack('U', $u);
					substr($s, $i, 2) = $c;
					push @work, [$s, $i+1];
					if (exists $sSingletonCompositions{$c})
					{
						printMessage("SING at $i:", $c, '->', $sSingletonCompositions{$c}) if $trace;
						my $s2 = $s;
						substr($s2, $i, 1) = $sSingletonCompositions{$c};
						push @work, [$s2, $i+1];
					}
				}
			}
		}
	}

	# All done. Return the results
	[ keys(%res) ]
}

# I'm not happy with this hack. unicore/Decomposition.pl explicitly says the code is for internal use
# only, but I don't know any other reasonably efficient way to construct lists of Unicode compositions
# other than including my own copy of, for example UnicodeData.txt, but then I couldn't guarantee that
# my copy was in sync with the local Perl installation.  Oh well.

sub _getCompositions {
	# Next few lines stolen shamelessly from Unicode::UCD
    for (split /^/m, do "unicore/Decomposition.pl") {
        my ($start, $end, $decomp) = / ^ (.+?) \t (.*?) \t (.+?)
                                        \s* ( \# .* )?  # Optional comment
                                        $ /x;
        $end = $start if $end eq "";
    
    	if ($decomp =~ /^([[:xdigit:]]{4,6})$/o) {
			# Singleton decomposition -- keep a record of these:
			my $d = $1;
			foreach my $c (hex($start) .. hex($end)) {
				$sSingletonCompositions{pack('U', hex($d))} = pack('U', $c);	# NB: hash values are strings
			}
		}
		elsif ($decomp =~ /^([[:xdigit:]]{4,6})\s+([[:xdigit:]]{4,6})$/o) {
			# Possible non-starter decompsition
			my ($d1, $d2) = map{hex} ($1, $2);
			foreach my $c (hex($start) .. hex($end)) {
				$cpNonStarterComposites{pack('UU', $d1, $d2)} = $c if getCombinClass($c) || getCombinClass($d1);  # NB: hash values are codepoints
			}
		}
	}
}


# Given a string, return a reference to an unsorted array containing 
# all permutations of the string. Does not filter out duplicates which
# can result if one or more chars of the string are the same.

# adaptation of the array permutation algorithm in FAQ 4
#(see "How do I permute N elements of a list?")
#
# I tried to making $list a hash rather than an array so as to eliminate duplicates,
# but Perl 5.6.1 had trouble figuring out that some strings were in fact
# UTF-8, so some data got munged. A hash would probably work on 5.8.

sub _permute {
    my ($src,			# initial parameter
    	$res , $list	# Parameters used in recursion 
    	) = @_;
    unless ($list)
    {
    	$list = {};
    	$res = '';
    }
    unless ($src) {
        $list->{$res} = 1;
    } else {
        my($newsrc,$newres,$i);
        foreach $i (0 .. length($src)-1) {
            $newsrc = $src;
            $newres = $res . substr($newsrc, $i, 1, "");
            _permute($newsrc, $newres, $list);
        }
    }
	# All done. Return the results
	return [ keys %{$list} ];
}

sub printMessage
{
	my $s = join(' ', @_);
	print STDERR encode('ascii', $s, Encode::FB_PERLQQ) . "\n";
}

1;

=back

=head1 BUGS

Uses L<Unicode::Normalize>. On some systems (e.g. ActiveState 5.6.1) Unicode::Normalize is aware 
only of Unicode 3.0 and thus de/compositions introduced since Unicode 3.0 will not be used.

=head1 AUTHOR

Bob Hallissy

=head1 COPYRIGHT

  Copyright(C) 2003-2011, SIL International. 

  This package is published under the terms of the Perl Artistic License.
