#!/usr/bin/perl
use strict;
use warnings;
use Data::Dumper;
use feature 'say';
use MIME::Lite;
use LWP::Simple qw($ua get);
$ua->timeout(15);
use DBI;

my $suppress_textmsg = 0;
my $phone = '6509969162@mms.att.net';
my $DB_host = 'stockpiledb.caffeinated.org';
my $DB_name = 'stockpiledb';
my $DB_port = '3306';
my $DB_user = 'stockpile';
my $DB_pwd = '3lipkcot$';
my $textmsg = MIME::Lite->new (
	From	=> 'Alerts@caffeinated.org',
	To		=> $phone,
	Data	=> ''
);
my $rest = 24*60*60;	# 24 hour rest between reminder alerts
my $title = "---- IN STOCK ----\r\n";
my $Sites;	# hash reference
my $Items;	# hash reference
my $Searches;	# hash reference
pull_from_db();
#say Dumper($Searches);
my $alertsdb = "/home/gconklin/scripts/alerts.db";
my $unknownslog = "/home/gconklin/scripts/unknowns.log";
my $resultshtml = "/home/gconklin/caffeinated.org/stockpile/results.html";
my @unknowns;
my $msg;
print "Checking stock...\n";
# loop through items since that's what we care about
foreach my $itemId (keys %{ $Items }) {
	print "  ". $Items->{$itemId}{'Name'};
	my $stdPrice = $Items->{ $itemId }{'StdPrice'};
	print ($stdPrice ? " (\$$stdPrice)" : '');
	print ' -'x10 ."\n";
	# loop through searches
	LINE: foreach my $search (values %{ $Searches }) {
		# check if this search is for the current site
		next LINE unless ($search->{'ItemId'} eq $itemId);
		my $siteId = $search->{'SiteId'};
		print "      ". $Sites->{ $siteId }{'Name'} ." ... ";
		my $instock = $search->{'SearchInStock'};
		my $outstock = $search->{'SearchOutStock'};
		my $url = $search->{'TinyUrl'} ? $search->{'TinyUrl'} : $search->{'Url'};
 		my $html = get $url || warn "Timed out! $url";;
		warn "Couldn't get $url" unless defined $html;
		$html =~ s/[^[:ascii:]]+/\'/g;		# get rid of non-ASCII characters
		# reformat html lines by row
		$html =~ s/\n//g;		# remove line breaks 
		$html =~ s/\r//g;		# remove ^M from windows files
		$html =~ s/[\s\s]+/ /g;		# remove ^M from windows files
		$html =~ s/\<\/tr\>/\<\/tr\>\n/g;	# add line breaks after TR tags
		$html =~ s/\<\/div\>/\<\/div\>\n/g;	# add line breaks after DIV tags
		$html =~ s/\<option /\n\<option /g;	# add line breaks before OPTION tags
		my @lines = split(/\n/, $html);
		my $search_name = $search->{'SearchName'};
		# make sure the page has the item somewhere
		unless ($html =~ m/$search_name/i) {
			print "Item not found at $url\n";
			next LINE;
		}
		my $range = $search->{'LinesRange'};
		my $itemPrice = '';
		# iterate through lines of html file
		for (my $x=0; $x<@lines; $x++) {
			my $htmlline = $lines[$x];
			# check if line consists of NAME or ID
			if ($htmlline =~ m/$search_name/i) {
				# iterate down the file to find the item's availability
				for (my $i=$x; $i<$x+$range; $i++) {
					my $nextline = $lines[$i];
					# extract price if possible
					my $searchPrice = $search->{'SearchPrice'};
					if ($searchPrice) {
						if ($nextline =~ m/$searchPrice/i) {
							$itemPrice = $1 if ($1);
						}
					}
					# check if line indicates in-stock
					if ($nextline =~ m/$instock/i && $nextline !~ m/$outstock/i) {
						my $price = '';
						$price = ($itemPrice < $Items->{ $itemId }{'StdPrice'} ? 
								"*\$$itemPrice*" : "") if ($itemPrice);
						print " --> IN STOCK!  $price\n";
						# check if alert was already sent
						if (my $aepoc = alerted($itemId,$siteId)) {
							# check how long its been since last alert
							my $epoc = time();
							if ($epoc<$aepoc+$rest) {
								# not sending new alert, waiting for a time
								#print "resting\n";
								next LINE;
							} else {
								# remove alert from db so it will alert next time
								delete_alerted($itemId,$siteId);
							}
						}
						# add to TEXT message to send alert
						$msg .= "\r\n". $Items->{ $itemId }{'Name'} ."\r\n". 
								$Sites->{ $siteId }{'Name'} ."\r\n$price (\$$stdPrice)\r\n". 
								$search->{'Url'} ."\r\n";
						# record that alert was sent
						add_alerted($itemId,$siteId);
						next LINE;
					# check if line indicates out-of-stock
					} elsif ($nextline =~ m/$outstock/i) {
						print "Out of stock\n";
						next LINE;
					}
				}
				# if we reached this point, then we don't know if its available or not
				print "unknown availability\n";
				# want to log this as an issue
				push (@unknowns, "$itemId\n$siteId\n$search_name\n$html");
				next LINE;
			}
		}
	}
}
=begin COMMENT_OUT
=end COMMENT_OUT
=cut
if ($msg) {
	# send text message
	if ($msg && !$suppress_textmsg) {
		$textmsg->attach (
			Type => 'TEXT',
			Data => "$title $msg"
		) or warn "Error adding text message: $!\n";
		$textmsg->send;
		print "  Text message sent\n";
		# create html file for online viewing
		my @msgs = split ($msg, '\n');
		open (HTML, ">$resultshtml") or warn "Unable to create log $resultshtml: $!";
		print HTML "<HTML><TITLE>Stock Pile by caffeianted.org</TITLE><BODY>\n";
		print HTML "Last updated: ". scalar localtime() ."<BR><HR><h3>In Stock:<ul>\n";
		print HTML join('<li>\n', @msgs);
		print HTML "</ul></BODY></HTML>";
		close HTML;
		print "  HTML file created\n";
	} else {
		print "  Supressing text message\n";
	}
} else {
	print "  Nothing to report.\n";
}
if (@unknowns) {
	print "  Logging the unknowns ($unknownslog)...\n";
	# overwrite previous file so these are easier to find
	open (LOG, ">$unknownslog") or warn "Unable to create log $unknownslog: $!";
	print LOG scalar localtime() ."\n". '.'x40 ."\n";
	print LOG join('\n', @unknowns);
	print LOG '='x40 ."\n";
	close LOG;
}
print "Done\n";
exit;

############ SUBROUTINES ###############

# check if alert has already been sent for item
sub alerted
{
	my ($itemId, $siteId) = @_;
	# nothing to do if no file exists
	return unless (-r $alertsdb);
	open(FILE, "< $alertsdb") or die "Unable to open < $alertsdb: $!";
	# iterate through file contents
	while(<FILE>) {
		my ($aItemId, $aSiteId, $aepoc) = split(/\|/, $_);
		# check if this is the item being checked
		if ($aItemId eq $itemId && $aSiteId eq $siteId) {
			return $aepoc;
		}
	}
	close FILE;
	return;
}

# record that alert was sent for item
sub add_alerted
{
	my ($itemId, $siteId, $url) = @_;
	# create file if it doesn't exist
	if (-W $alertsdb) {
		open(FILE, ">> $alertsdb") or die "Unable to open >> $alertsdb: $!";
		print FILE "\n" unless (-z FILE);
	} else {
		open(FILE, "> $alertsdb") or die "Unable to open > $alertsdb: $!";
	}
	my $aepoc = time();
	#print " (ADDED)";
	print FILE "$itemId|$siteId|$aepoc";
	close FILE;
}

# remote alert from database
sub delete_alerted
{
	my ($itemId, $siteId) = @_;
	# nothing to do if file isn't writable
	return unless (-W $alertsdb);
	open(FILE, "< $alertsdb") or die "Unable to open < $alertsdb: $!";
	my @lines = <FILE>;
	close FILE;
	open(FILE, "> $alertsdb") or die "Unable to open > $alertsdb: $!";
	# iterate through file contents
	foreach my $line ( @lines ) {
		my ($aItemId, $aSiteId, $aepoc) = split(/\|/, $line);
		# add back in file if this is not the record to delete
		print " (DELETED)" if ($aItemId eq $itemId && $aSiteId eq $siteId);
		print FILE $line unless ($aItemId eq $itemId && $aSiteId eq $siteId);
	}
	close FILE;
}
sub pull_from_db
{
	# pull from db
	my $dsn = "DBI:mysql:database=$DB_name;host=$DB_host;port=$DB_port";
	my $dbh = DBI->connect($dsn, $DB_user, $DB_pwd);

	my $sth = $dbh->prepare("SELECT * FROM Sites");
	$sth->execute;
	$Sites = $sth->fetchall_hashref('Id');

	$sth = $dbh->prepare("SELECT * FROM Items");
	$sth->execute;
	$Items = $sth->fetchall_hashref('Id');

	$sth = $dbh->prepare("SELECT * FROM Searches WHERE Disabled IS null ORDER BY SiteId");
	$sth->execute;
	$Searches = $sth->fetchall_hashref('Id');

	$sth->finish;
	$dbh->disconnect();
}
