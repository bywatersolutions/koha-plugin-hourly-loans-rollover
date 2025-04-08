#!/usr/bin/perl

use Modern::Perl;

use C4::Context;

use Koha::Plugin::Com::ByWaterSolutions::HourlyLoansRollover;

use CGI;

my $cgi = new CGI;
$cgi->param( -name => 'update', -value => '1' );

my $hourly = Koha::Plugin::Com::ByWaterSolutions::HourlyLoansRollover->new( { cgi => $cgi } );
$hourly->tool({ silent => 1 });
