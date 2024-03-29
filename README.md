# Introduction

The Hourly Loans Rollover plugin fills a gap in Koha's current hourly loans implementation. At this time, Koha does not track the closing and opening times for libraries and as such cannot make checkouts due after hours to be due the following morning. This plugin is meant to fill this gap in functionality until such time as this behavior is built into Koha.

Koha’s Plugin System (available in Koha 3.12+) allows for you to add additional tools and reports to [Koha](http://koha-community.org) that are specific to your library. Plugins are installed by uploading KPZ ( Koha Plugin Zip ) packages. A KPZ file is just a zip file containing the perl files, template files, and any other files necessary to make the plugin work. Learn more about the Koha Plugin System in the [Koha 3.22 Manual](http://manual.koha-community.org/3.22/en/pluginsystem.html) or watch [Kyle’s tutorial video](http://bywatersolutions.com/2013/01/23/koha-plugin-system-coming-soon/).

# Downloading

From the [release page](https://github.com/bywatersolutions/koha-plugin-hourly-loans-rollover/releases) you can download the relevant *.kpz file

# Installing

Koha's Plugin System allows for you to add additional tools and reports to Koha that are specific to your library. Plugins are installed by uploading KPZ ( Koha Plugin Zip ) packages. A KPZ file is just a zip file containing the perl files, template files, and any other files necessary to make the plugin work.

The plugin system needs to be turned on by a system administrator.

To set up the Koha plugin system you must first make some changes to your install.

* Change `<enable_plugins>0<enable_plugins>` to `<enable_plugins>1</enable_plugins>` in your koha-conf.xml file
* Confirm that the path to `<pluginsdir>` exists, is correct, and is writable by the web server
* Restart your webserver

Once set up is complete you will need to alter your UseKohaPlugins system preference. On the Tools page you will see the Tools Plugins and on the Reports page you will see the Reports Plugins.

# Configuration

This plugin has a configuration page where the standard weekly hours for each library can be set, as well as a default set of hours if most of the libraries share the same hours of operation.

In addition to the standard weekly hours, it is possible to add system wide and library specific exceptions to the standard operating hours.

When the plugin looks for the opening or closing hours for a day, it looks for them in the following order and uses the first it finds:
1) An exception day for the specific library
2) An exception day that is system-wide
3) The standard hours of operation for the specific library
4) The standard hours of operation system-wide

Once the hours of operation for the libraries have been set, running the tool will produce a list of current checkouts that are due after hours and what the new due date and time should be. Overdue items are not included in this list.

If the new due dates and times look good, they checkouts can be updated by clicking the "Change due dates and times" button and confirming the change.

## Cronjob

To automate the rollover, set up the script `Koha/Plugin/Com/ByWaterSolutions/HourlyLoansRollover/cli.pl` to run periodically, preferably sometime between every minute and every 5 minutes.
