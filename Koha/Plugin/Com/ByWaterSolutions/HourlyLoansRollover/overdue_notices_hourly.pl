#!/usr/bin/perl

use Modern::Perl;

use Data::Dumper;
use Getopt::Long;
use Pod::Usage;

use C4::Context;
use C4::Letters;

my @branchcodes;
my @categories;
my $delay;
my $interval;
my $notice;
my $restrict;

my $confirm = 0;

my $help     = 0;
my $man      = 0;
my $verbose  = 0;

GetOptions(
    'l|library=s'  => \@branchcodes,
    'c|category=s' => \@categories,
    'd|delay=i'    => \$delay,
    'i|interval=i' => \$interval,
    'n|notice=s'     => \$notice,
    'r|restrict'     => \$restrict,

    'confirm' => \$confirm,

    'h|help' => \$help,
    'man'    => \$man,
    'v+'     => \$verbose,
) or pod2usage(2);
pod2usage(1) if $help;
pod2usage( -verbose => 2 ) if $man;
pod2usage(1) unless ( $delay && $interval && $notice );

=head1 NAME

overdue_notices_hourly.pl - Send notices for hourly loans taht are overdue

=head1 SYNOPSIS

overdue_notices_hourly.pl -d=<delay> -i=<interval> -n=<notice> [ -l=<library> -c=<categorycode> -r=<restricte> ]

 Options:
   --help    brief help message
   --man     full documentation
   -v        verbose mode, incrementable
   -l        <library>   only deal with checkouts from this library/branch
   -c        <category>  only deal with patrons of this category
   -d        <delay>     only select hourly loans at least this many minutes overdue
   -i        <interval>  starting from the delay, this is the maximum minutes overdue
                         for which to select overdue checkouts.
   --confirm Enqueue notices, otherwise display only

=head1 OPTIONS

=over 8

=item B<--help>

Print a brief help message and exits.

=item B<--man>

Prints the manual page and exits.

=item B<-v>

Verbose. Without this flag set you will get more info on what's going on. Repeatable to increase verbosity.

=item B<-c>

Patron category code. Only run overdue notices for patrons of this category type. Repeatable.

=item B<-l>

Checkout library. Limit overdue notices to overdue hourly checkouts from this library. Repeatable.

=item B<-d>

How many minutes overdue a checkout needs to be to be selected for sending an overdue notice.

=item B<-i>

How many minutes overdue past the delay can an item be and still be selected. E.g. -d 60 -i 60 will send a notice for hourly loans that are 1 to 2 hours overdue, no less, no more.

=item B<--confirm>

Enqueue notices. Without this flag, notices will be generated in test mode and only displayed.

=back

=head1 DESCRIPTION

This script is designed to send overdue notices for hourly loans.

=cut

my $branchcode_limit =
  @branchcodes
  ? 'AND issues.branchcode IN ('
  . join( ',', map { qq{'$_'} } @branchcodes ) . ')'
  : q{};
my $category_limit =
  @categories
  ? 'AND borrowers.categorycode IN ('
  . join( ',', map { qq{'$_'} } @categories ) . ')'
  : q{};

my $query = qq{
SELECT borrowernumber, biblionumber, itemnumber, issues.branchcode, lang,
       TIMESTAMPDIFF( MINUTE, issues.date_due, NOW() ) AS minutes_overdue
  FROM issues
  LEFT JOIN borrowers USING ( borrowernumber )
  LEFT JOIN items USING ( itemnumber )
  WHERE
        TIME( issues.date_due ) != '23:59:00'
    AND issues.date_due < NOW()
    AND TIMESTAMPDIFF( MINUTE, issues.date_due, NOW() ) > $delay
    AND TIMESTAMPDIFF( MINUTE, issues.date_due, NOW() ) < $delay + $interval
    $branchcode_limit
    $category_limit
};
print "QUERY:$query\n\n" if $verbose > 1;

my $sth = C4::Context->dbh->prepare($query);
$sth->execute();

while ( my $row = $sth->fetchrow_hashref ) {
    print Data::Dumper::Dumper($row) . "\n" if $verbose > 4;

    if (
        my $letter = C4::Letters::GetPreparedLetter(
            module      => 'circulation',
            letter_code => $notice,
            branchcode  => $row->{branchcode},
            lang        => $row->{lang},
            tables      => {
                borrowers   => $row->{borrowernumber},
                biblio      => $row->{biblionumber},
                biblioitems => $row->{biblionumber},
                items       => $row->{itemnumber},
                issues      => $row->{itemnumber},
            },
            message_transport_type => 'email',
        )
      )
    {
        C4::Letters::EnqueueLetter(
            {
                letter                 => $letter,
                borrowernumber         => $row->{borrowernumber},
                message_transport_type => 'email'
            }
        ) if $confirm;

        print "NOTICE:$letter->{content}\n" if !$confirm || $verbose > 3;
    }

    if ( $confirm && $restrict ) {
        AddUniqueDebarment(
            {
                borrowernumber => $row->{borrowernumber},
                type           => 'OVERDUES',
                comment        => "OVERDUES_PROCESS "
                  . output_pref( dt_from_string() ),
            }
        );
    }
}
