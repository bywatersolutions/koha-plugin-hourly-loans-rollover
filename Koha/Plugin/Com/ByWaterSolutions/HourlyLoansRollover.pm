package Koha::Plugin::Com::ByWaterSolutions::HourlyLoansRollover;

## It's good practive to use Modern::Perl
use Modern::Perl;

use Data::Dumper;
## Required for all plugins
use base qw(Koha::Plugins::Base);

## We will also need to include any Koha libraries we want to access
use C4::Context;
use C4::Auth;
use C4::Installer qw(TableExists);
use C4::Circulation qw(GetLoanLength);

use Koha::DateUtils qw(dt_from_string);
use Koha::Libraries;
use Koha::Calendar;

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

our $calendars = {};
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
    my $silent = $args->{silent} // undef;

    my $template = $self->get_template( { file => 'tool.tt' } );

    my $dbh   = C4::Context->dbh();
    my $query = q{
        SELECT * FROM issues
        LEFT JOIN borrowers USING ( borrowernumber )
        LEFT JOIN items USING ( itemnumber )
        LEFT JOIN biblio USING ( biblionumber )
        WHERE DATE(issuedate) = CURDATE()
          AND date_due > NOW()
          AND (
            DATE(date_due) = CURDATE()
            OR
            DATE(date_due) = CURDATE() + INTERVAL 1 DAY
          )
    };
    my $sth = $dbh->prepare($query);
    $sth->execute();

    my @checkouts;
    while ( my $row = $sth->fetchrow_hashref() ) {
        my $loanlength = C4::Circulation::GetLoanLength( $row->{categorycode}, $row->{itype}, $row->{branchcode} );
        next if $loanlength->{lengthunit} eq 'days';

        my ( $closing_time, $closing_date ) = $self->get_time(
            {
                type       => 'closing',
                branchcode => $row->{holdingbranch},
                datetime   => $row->{date_due},
            }
        );

        my ( $opening_time, $opening_date ) = $self->get_time(
            {
                type       => 'opening',
                branchcode => $row->{holdingbranch},
                datetime   => $row->{date_due},
            }
        );

        $row->{opening_date} = $opening_date;
        $row->{opening_time} = $opening_time;
        $row->{closing_date} = $closing_date;
        $row->{closing_time} = $closing_time;

        # If the next time the library closes is *after* the item is due
        # don't change the due date. This is needed because some libraries
        # are open 24 hours a day during the weekdays, closing only on weekends
        if ($closing_time) {
            my $closing_dt = "$closing_date $closing_time";
            my $skip       = $row->{date_due} le $closing_dt;
            next if $row->{date_due} le $closing_dt;
        }

        # If due before opening, push due date/time to 1 hour after opening on that day
        if ($opening_time) {
            my ( undef, $time_due ) = split( / /, $row->{date_due} );

            if ( $time_due lt $opening_time ) {
                my $dt = dt_from_string("$opening_date $opening_time");
                $dt->add(
                    hours   => $self->retrieve_data('due_after_opening_hours')   || 0,
                    minutes => $self->retrieve_data('due_after_opening_minutes') || 0,
                );
                $row->{new_date_due} = $dt->ymd('-') . ' ' . $dt->hms(':');

                push( @checkouts, $row );
                next;
            }
        }

        # If closing, push due date/time to 1 hour after opening the following open day
        if ($closing_time) {
            my ( undef, $time_due ) = split( / /, $row->{date_due} );
            if ( $time_due gt $closing_time ) {
                my $dt = dt_from_string("$opening_date $opening_time");
                $dt->add( hours => 1 );
                $row->{new_date_due} = $dt->ymd('-') . ' ' . $dt->hms(':');

                push( @checkouts, $row );
            }
        }
    }

    $template->param( checkouts => \@checkouts );

    if ( $cgi->param('update') ) {
        my $update_query = "UPDATE issues SET date_due = ? WHERE issue_id = ?";
        my $update_sth   = $dbh->prepare($update_query);

        foreach my $c (@checkouts) {
            my $res =
              $update_sth->execute( $c->{new_date_due}, $c->{issue_id} );
        }

        $template->param( updated => 1 );
    }

    unless( $silent ){
        print $cgi->header();
        print $template->output();
    }

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
        $template->param(
            exceptions                => $exceptions,
            due_after_opening_hours   => $self->retrieve_data('due_after_opening_hours'),
            due_after_opening_minutes => $self->retrieve_data('due_after_opening_minutes'),
        );

        ## Grab the values we already have for our settings, if any exist
        my $libraries = Koha::Libraries->search();
        $template->param( libraries => $libraries, );

        print $cgi->header();
        print $template->output();
    }
    else {
        my $vars = $cgi->Vars;

        my @libraries = Koha::Libraries->search()->as_list;
        my @branchcodes = map { $_->id } @libraries;
        unshift( @branchcodes, 'ALL_LIBS' );

        #FIXME: Make this all atomic
        $dbh->do("DELETE FROM com_bws_hlr_hours");
        my $query_hours = "INSERT INTO com_bws_hlr_hours ( branchcode, dow, opens, closes ) VALUES ( ?, ?, ?, ? )";
        my $sth_hours = $dbh->prepare($query_hours);

        foreach my $day (@days_of_week) {
            foreach my $branchcode (@branchcodes) {
                my $opens_hour  = $vars->{"HoO-$branchcode-$day-opening-hour"};
                my $opens_min   = $vars->{"HoO-$branchcode-$day-opening-min"};
                my $closes_hour = $vars->{"HoO-$branchcode-$day-closing-hour"};
                my $closes_min  = $vars->{"HoO-$branchcode-$day-closing-min"};
                
                my $opens = ( $opens_hour && $opens_min ) ? "$opens_hour:$opens_min" : undef;
                my $closes = ( $closes_hour && $closes_min ) ? "$closes_hour:$closes_min" : undef;

                $sth_hours->execute( $branchcode, $day, $opens, $closes );
            }
        }

        $dbh->do("DELETE FROM com_bws_hlr_exceptions");
        my $query_exceptions = "INSERT INTO com_bws_hlr_exceptions ( branchcode, on_date, opens, closes ) VALUES ( ?, ?, ?, ? )";
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
            
            my $exception_opens = ( $exception_opens_hour && $exception_opens_min ) ? "$exception_opens_hour:$exception_opens_min" : undef;
            my $exception_closes = ( $exception_closes_hour && $exception_closes_min ) ? "$exception_closes_hour:$exception_closes_min" : undef;

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
                    $exception_opens,
                    $exception_closes,
                );
            }
            else {
                last;
            }
        }

        $self->store_data(
            {
                last_configured_by        => C4::Context->userenv->{'number'},
                due_after_opening_hours   => $cgi->param('due_after_opening_hours'),
                due_after_opening_minutes => $cgi->param('due_after_opening_minutes'),
            }
        );
        $self->go_home();
    }
}

## This is the 'upgrade' method. It will be triggered when a newer version of a
## plugin is installed over an existing older version of a plugin
sub upgrade {
    my ( $self, $args ) = @_;

    my $database_version = $self->retrieve_data('__INSTALLED_VERSION__') || 0;

    if ( $self->_version_compare( "1.3.11", $database_version ) ) {

        my $po_table = $self->get_qualified_table_name('purchase_orders');

        my $dbh = C4::Context->dbh;
        
        $dbh->do(qq{ALTER TABLE com_bws_hlr_hours CHANGE opens opens TIME NULL});
        $dbh->do(qq{ALTER TABLE com_bws_hlr_hours CHANGE closes closes TIME NULL});
        
        $dbh->do(qq{ALTER TABLE com_bws_hlr_exceptions CHANGE opens opens TIME NULL});
        $dbh->do(qq{ALTER TABLE com_bws_hlr_exceptions CHANGE closes closes TIME NULL});

        $self->store_data({ '__INSTALLED_VERSION__' => "1.3.11" });
    }

    return 1;
}

## This is the 'install' method. Any database tables or other setup that should
## be done when the plugin if first installed should be executed in this method.
## The installation method should always return true if the installation succeeded
## or false if it failed.
sub install() {
    my ( $self, $args ) = @_;

    unless( TableExists("com_bws_hlr_hours") ){
        C4::Context->dbh->do(
            qq{
                CREATE TABLE com_bws_hlr_hours (
                    id INT(11) NOT NULL auto_increment,
                    branchcode VARCHAR(10) NOT NULL default '',
                    dow VARCHAR(10),
                    opens TIME NULL,
                    closes TIME NULL,
                    PRIMARY KEY (id),
                    KEY `branchcode` (`branchcode`)
                ) ENGINE = INNODB;
            }
        );
    }

    unless( TableExists("com_bws_hlr_exceptions")  ){
        C4::Context->dbh->do(
            qq{
                CREATE TABLE com_bws_hlr_exceptions (
                    id INT(11) NOT NULL auto_increment,
                    branchcode VARCHAR(10) NOT NULL default '',
                    on_date DATE NOT NULL,
                    opens TIME NULL,
                    closes TIME NULL,
                    PRIMARY KEY (id),
                    KEY `branchcode` (`branchcode`)
                ) ENGINE = INNODB;
            }
        );
    }

    return 1;
}

## This method will be run just before the plugin files are deleted
## when a plugin is uninstalled. It is good practice to clean up
## after ourselves!
sub uninstall() {
    my ( $self, $args ) = @_;

    return 1;
}

sub get_time {
    my ( $self, $args ) = @_;

    my $type       = $args->{type};         # Must be 'closing' or 'opening'
    my $branchcode = $args->{branchcode};
    my $datetime   = $args->{datetime};

    my $dbh = C4::Context->dbh;

    my $dt = dt_from_string($datetime);

    my $days  = $type eq 'closing' ? 0        : 1;
    my $field = $type eq 'closing' ? 'closes' : 'opens';

    # Skip over holidays when finding new due date and time
    if ( $field eq 'opens' ) {
        # We assume that for opening hours, we want the next day, but if the item is due before opening hours on the current due date,
        # we don't way to start the next day, we want to start with the current due day
        my $current_due_date_hlr_hours = $dbh->selectrow_hashref("SELECT * FROM com_bws_hlr_exceptions WHERE on_date = ? AND branchcode = ?", undef, $dt->ymd,      $branchcode);    
        $current_due_date_hlr_hours  //= $dbh->selectrow_hashref("SELECT * FROM com_bws_hlr_exceptions WHERE on_date = ? AND branchcode = ?", undef, $dt->ymd,      'ALL_LIBS');
        $current_due_date_hlr_hours  //= $dbh->selectrow_hashref("SELECT * FROM com_bws_hlr_hours      WHERE dow = ? AND branchcode = ?"    , undef, $dt->day_name, $branchcode);    
        $current_due_date_hlr_hours  //= $dbh->selectrow_hashref("SELECT * FROM com_bws_hlr_hours      WHERE dow = ? AND branchcode = ?"    , undef, $dt->day_name, 'ALL_LIBS');
        if ( $dt->hms lt $current_due_date_hlr_hours->{opens} ) {
            $days = 0;
        }

        $dt->add( days => $days );

        $calendars->{$branchcode} ||=
          Koha::Calendar->new( branchcode => $branchcode );
        my $calendar = $calendars->{$branchcode};

        while ( $calendar->is_holiday($dt) ) {
            $dt->add( days => 1 );
            $days++;
        }
    }

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
    $result =
      $hours_of_operation_sth->execute( $datetime, $branchcode, $datetime );
    $row = $hours_of_operation_sth->fetchrow_hashref;
    return ( $row->{$field}, $row->{calculated_date} )
      if $result && $result ne '0E0';

    # Finally, check if there are weekly hours set for all libraries
    $result =
      $hours_of_operation_sth->execute( $datetime, 'ALL_LIBS', $datetime );
    $row = $hours_of_operation_sth->fetchrow_hashref;
    return ( $row->{$field}, $row->{calculated_date} )
      if $result && $result ne '0E0';
}

1;
