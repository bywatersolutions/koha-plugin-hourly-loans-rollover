package Koha::Plugin::Com::ByWaterSolutions::HourlyLoansRollover;

## It's good practive to use Modern::Perl
use Modern::Perl;

use Data::Dumper;
## Required for all plugins
use base qw(Koha::Plugins::Base);

## We will also need to include any Koha libraries we want to access
use C4::Context;
use C4::Auth;
use Koha::DateUtils;
use Koha::Libraries;

## Here we set our plugin version
our $VERSION = "{VERSION}";

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name   => 'Hourly Loans Rollover',
    author => 'Kyle M Hall',
    description =>
'Adds ability to set library opening and closing hours and to make hourly loans due after hours to be due in the morning',
    date_authored   => '2017-06-26',
    date_updated    => '2017-06-26',
    minimum_version => '16.11.00.000',
    maximum_version => undef,
    version         => $VERSION,
};

our @days_of_week =
  qw( Monday Tuesday Wednesday Thursday Friday Saturday Sunday );

sub new {
    my ( $class, $args ) = @_;

    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    my $self = $class->SUPER::new($args);

    return $self;
}

sub tool {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $template = $self->get_template( { file => 'tool.tt' } );

    my $dbh   = C4::Context->dbh();
    my $query = q{
        SELECT * FROM issues
        LEFT JOIN borrowers USING ( borrowernumber )
        LEFT JOIN items USING ( itemnumber )
        LEFT JOIN biblio USING ( biblionumber )
        WHERE date_due > NOW()
    };
    my $sth = $dbh->prepare($query);
    $sth->execute();

    my @checkouts;
    while ( my $row = $sth->fetchrow_hashref() ) {
        my ( $closing_time, $closing_date ) = $self->get_time(
            {
                type       => 'closing',
                branchcode => $row->{holdingbranch},
                datetime   => $row->{date_due},
            }
        );

        if ($closing_time) {
            my ( undef, $time_due ) = split( / /, $row->{date_due} );
            if ( $time_due gt $closing_time ) {
                $row->{closing_time} = $closing_time;

                my ( $opening_time, $opening_date ) = $self->get_time(
                    {
                        type       => 'opening',
                        branchcode => $row->{holdingbranch},
                        datetime   => $row->{date_due},
                    }
                );

                $row->{opening_date} = $opening_date;
                $row->{opening_time} = $opening_time;

                my $dt = dt_from_string( "$opening_date $opening_time" );
                $dt->add( hours => 1 );
                $row->{new_date_due} = $dt->ymd('-') . ' ' . $dt->hms(':');

                push( @checkouts, $row );
            }
        }
    }

    $template->param( checkouts => \@checkouts );

    if ( $cgi->param('update') ) {
        my $update_query = "UPDATE issues SET date_due = ? WHERE issue_id = ?";
        my $update_sth = $dbh->prepare( $update_query );

        foreach my $c ( @checkouts ) {
            my $res = $update_sth->execute( $c->{new_date_due}, $c->{issue_id} );
            warn "RES $res";
            warn "NEW DATE DUE: " . $c->{new_date_due};
        }

        $template->param( updated => 1 );
    }

    print $cgi->header();
    print $template->output();

}

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $dbh = C4::Context->dbh();

    unless ( $cgi->param('save') ) {
        my $template = $self->get_template( { file => 'configure.tt' } );

        my $sth = $dbh->prepare("SELECT * FROM com_bws_hlr_hours");
        $sth->execute();
        while ( my $row = $sth->fetchrow_hashref ) {
            my $branchcode = $row->{branchcode};
            my $dow        = $row->{dow};
            my ( $opens_hour,  $opens_min )  = split( ':', $row->{opens} );
            my ( $closes_hour, $closes_min ) = split( ':', $row->{closes} );

            $template->param(
                "HoO-$branchcode-$dow-opening-hour" => $opens_hour,
                "HoO-$branchcode-$dow-opening-min"  => $opens_min,
                "HoO-$branchcode-$dow-closing-hour" => $closes_hour,
                "HoO-$branchcode-$dow-closing-min"  => $closes_min,
            );
        }

        my $exceptions;
        $sth = $dbh->prepare("SELECT * FROM com_bws_hlr_exceptions");
        $sth->execute();
        while ( my $row = $sth->fetchrow_hashref ) {
            my $id         = $row->{id};
            my $branchcode = $row->{branchcode};
            my $on_date    = $row->{on_date};
            my ( $opens_hour,  $opens_min )  = split( ':', $row->{opens} );
            my ( $closes_hour, $closes_min ) = split( ':', $row->{closes} );

            $exceptions->{$branchcode}->{$on_date}->{opens_hour} = $opens_hour;
            $exceptions->{$branchcode}->{$on_date}->{opens_min}  = $opens_min;
            $exceptions->{$branchcode}->{$on_date}->{closes_hour} =
              $closes_hour;
            $exceptions->{$branchcode}->{$on_date}->{closes_min} = $closes_min;
            $exceptions->{$branchcode}->{$on_date}->{id}         = $id;
        }
        $template->param( exceptions => $exceptions );

        ## Grab the values we already have for our settings, if any exist
        my $libraries = Koha::Libraries->search();
        $template->param( libraries => $libraries, );

        print $cgi->header();
        print $template->output();
    }
    else {
        my $vars = $cgi->Vars;

        my @libraries = Koha::Libraries->search();
        my @branchcodes = map { $_->id } @libraries;
        unshift( @branchcodes, 'ALL_LIBS' );

        #FIXME: Make this all atomic
        $dbh->do("DELETE FROM com_bws_hlr_hours");
        my $query_hours =
"INSERT INTO com_bws_hlr_hours ( branchcode, dow, opens, closes ) VALUES ( ?, ?, ?, ? )";
        my $sth_hours = $dbh->prepare($query_hours);

        foreach my $day (@days_of_week) {
            foreach my $branchcode (@branchcodes) {
                my $opens_hour  = $vars->{"HoO-$branchcode-$day-opening-hour"};
                my $opens_min   = $vars->{"HoO-$branchcode-$day-opening-min"};
                my $closes_hour = $vars->{"HoO-$branchcode-$day-closing-hour"};
                my $closes_min  = $vars->{"HoO-$branchcode-$day-closing-min"};

                if ( $opens_hour && $opens_min && $closes_hour && $closes_min )
                {
                    $sth_hours->execute( $branchcode, $day,
                        "$opens_hour:$opens_min", "$closes_hour:$closes_min" );
                }
            }
        }

        $dbh->do("DELETE FROM com_bws_hlr_exceptions");
        my $query_exceptions =
"INSERT INTO com_bws_hlr_exceptions ( branchcode, on_date, opens, closes ) VALUES ( ?, ?, ?, ? )";
        my $sth_exceptions = $dbh->prepare($query_exceptions);

        my @exception_date        = $cgi->param('exception_date');
        my @exception_branchcode  = $cgi->param('exception_branchcode');
        my @exception_opens_hour  = $cgi->param('exception_opens_hour');
        my @exception_opens_min   = $cgi->param('exception_opens_min');
        my @exception_closes_hour = $cgi->param('exception_closes_hour');
        my @exception_closes_min  = $cgi->param('exception_closes_min');

        while (1) {
            my $exception_date        = pop(@exception_date);
            my $exception_branchcode  = pop(@exception_branchcode);
            my $exception_opens_hour  = pop(@exception_opens_hour);
            my $exception_opens_min   = pop(@exception_opens_min);
            my $exception_closes_hour = pop(@exception_closes_hour);
            my $exception_closes_min  = pop(@exception_closes_min);

            if ($exception_date) {

            # Some dates will come in as ISO, some in the preferred date format.
            # Let's convert them all to ISO for simplicity
                $exception_date = output_pref(
                    {
                        dt         => dt_from_string($exception_date),
                        dateformat => 'iso',
                        dateonly   => 1,
                    }
                );

                $sth_exceptions->execute(
                    $exception_branchcode,
                    $exception_date,
                    "$exception_opens_hour:$exception_opens_min",
                    "$exception_closes_hour:$exception_closes_min"
                );
            }
            else {
                last;
            }
        }

        $self->store_data(
            {
                last_configured_by => C4::Context->userenv->{'number'},
            }
        );
        $self->go_home();
    }
}

## This is the 'install' method. Any database tables or other setup that should
## be done when the plugin if first installed should be executed in this method.
## The installation method should always return true if the installation succeeded
## or false if it failed.
sub install() {
    my ( $self, $args ) = @_;

    C4::Context->dbh->do(
        qq{
            CREATE TABLE com_bws_hlr_hours (
                id INT(11) NOT NULL auto_increment,
                branchcode VARCHAR(10) NOT NULL default '',
                dow VARCHAR(10),
                opens TIME NOT NULL,
                closes TIME NOT NULL,
                PRIMARY KEY (id),
                KEY `branchcode` (`branchcode`)
            ) ENGINE = INNODB;
        }
    );

    C4::Context->dbh->do(
        qq{
            CREATE TABLE com_bws_hlr_exceptions (
                id INT(11) NOT NULL auto_increment,
                branchcode VARCHAR(10) NOT NULL default '',
                on_date DATE NOT NULL,
                opens TIME NOT NULL,
                closes TIME NOT NULL,
                PRIMARY KEY (id),
                KEY `branchcode` (`branchcode`)
            ) ENGINE = INNODB;
        }
    );

    return 1;
}

## This method will be run just before the plugin files are deleted
## when a plugin is uninstalled. It is good practice to clean up
## after ourselves!
sub uninstall() {
    my ( $self, $args ) = @_;

    my $table = $self->get_qualified_table_name('mytable');

    return C4::Context->dbh->do("DROP TABLE $table");
}

sub tool_step1 {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

}

sub tool_step2 {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $template = $self->get_template( { file => 'tool.tt' } );

    my $borrowernumber = C4::Context->userenv->{'number'};
    my $borrower = GetMember( borrowernumber => $borrowernumber );
    $template->param( 'victim' => $borrower );

    ModMember( borrowernumber => $borrowernumber, firstname => 'Bob' );

    my $dbh = C4::Context->dbh;

    my $table = $self->get_qualified_table_name('mytable');

    my $sth = $dbh->prepare("SELECT DISTINCT(borrowernumber) FROM $table");
    $sth->execute();
    my @victims;
    while ( my $r = $sth->fetchrow_hashref() ) {
        push( @victims, GetMember( borrowernumber => $r->{'borrowernumber'} ) );
    }
    $template->param( 'victims' => \@victims );

    $dbh->do( "INSERT INTO $table ( borrowernumber ) VALUES ( ? )",
        undef, ($borrowernumber) );

    print $cgi->header();
    print $template->output();
}

sub get_time {
    my ( $self, $args ) = @_;

    my $type       = $args->{type};         # Must be 'closing' or 'opening'
    my $branchcode = $args->{branchcode};
    my $datetime   = $args->{datetime};

    my $days = $type eq 'closing' ? 0 : 1;
    my $field = $type eq 'closing' ? 'closes' : 'opens';

    my $dbh = C4::Context->dbh;

    my $exceptions_query =
"SELECT *, DATE(DATE_ADD(?, INTERVAL $days DAY)) AS calculated_date FROM com_bws_hlr_exceptions WHERE branchcode = ? AND on_date = DATE(DATE_ADD(?, INTERVAL $days DAY))";
    my $exceptions_sth = $dbh->prepare($exceptions_query);

    my $hours_of_operation_query =
"SELECT *, DATE(DATE_ADD(?, INTERVAL $days DAY)) AS calculated_date FROM com_bws_hlr_hours WHERE branchcode = ? AND dow = DAYNAME(DATE_ADD(?, INTERVAL $days DAY))";
    my $hours_of_operation_sth = $dbh->prepare($hours_of_operation_query);

    # Look for a library specific exception first
    my $result = $exceptions_sth->execute( $datetime, $branchcode, $datetime );
    my $row = $exceptions_sth->fetchrow_hashref;
    return ( $row->{$field}, $row->{calculated_date} )
      if $result && $result ne '0E0';

    # Then an all libraries exception
    $result = $exceptions_sth->execute( $datetime, 'ALL_LIBS', $datetime );
    $row = $exceptions_sth->fetchrow_hashref;
    return ( $row->{$field}, $row->{calculated_date} )
      if $result && $result ne '0E0';

    # Then weekly hours for the specific libary
    $result = $hours_of_operation_sth->execute( $datetime, $branchcode, $datetime );
    $row = $hours_of_operation_sth->fetchrow_hashref;
    return ( $row->{$field}, $row->{calculated_date} )
      if $result && $result ne '0E0';

    # Finally, check if there are weekly hours set for all libraries
    $result = $hours_of_operation_sth->execute( $datetime, 'ALL_LIBS', $datetime );
    $row = $hours_of_operation_sth->fetchrow_hashref;
    return ( $row->{$field}, $row->{calculated_date} )
      if $result && $result ne '0E0';
}

1;