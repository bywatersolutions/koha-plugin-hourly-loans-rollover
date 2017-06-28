#!/usr/bin/perl

use Modern::Perl;

use FindBin;                                # locate this script
use lib "$FindBin::Bin/../../../../../";    # use the parent directory

use Koha::Plugin::Com::ByWaterSolutions::HourlyLoansRollover;

use CGI;

my $cgi = new CGI;
$cgi->param( -name => 'update', -value => '1' );

my $coverflow = Koha::Plugin::Com::ByWaterSolutions::HourlyLoansRollover->new( { cgi => $cgi } );
$coverflow->tool();
