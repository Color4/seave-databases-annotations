#!/usr/bin/perl

use strict;
use warnings;
use DBI; # MySQL connection
use Tie::File; # File -> array for parsing without loading whole thing into RAM

####################################

my $input_file; # Stores the input filename from the argument passed to the script
my $mysql_host; # Stores the MySQL hostname to connect to from the argument passed to the script
my $mysql_user; # Stores the MySQL username to connect to from the argument passed to the script
my $mysql_password; # Stores the MySQL password to connect to from the argument passed to the script

if (scalar(@ARGV) != 4) {
	print "FATAL ERROR: arguments must be supplied as 1) input file path 2) MySQL host 3) MySQL user 4) MySQL password.\n";
	exit;
} else {
	$input_file = $ARGV[0];
	$mysql_host = $ARGV[1];
	$mysql_user = $ARGV[2];
	$mysql_password = $ARGV[3];
}

####################################

my $driver = "mysql"; 
my $database = "CLINVAR_NEW";
my $dsn = "DBI:$driver:database=$database;host=$mysql_host";

my $dbh = DBI->connect($dsn, $mysql_user, $mysql_password) or die $DBI::errstr;

####################################

my $num_input_columns = 8; # The number of columns expected in the input VCF
my $num_insert_columns = 7; # The number of columns being inserted into the DB
my $num_rows_to_add_per_insert = 1000;

my @input_file_lines;
my $inserted_rows = 0;
my @insert_values;

####################################

# Check that the file exists
-e $input_file or die "File \"$input_file\" does not exist.\n";

print "\nIndexing input file.\n";

# Load the input file into an array (each element is a line but the whole thing is not loaded into memory)
tie @input_file_lines, 'Tie::File', $input_file or die "Cannot index input file.\n";

####################################

my $mysql_query_fresh = "INSERT INTO `clinvar` (chr, position, ref, alt, clinvar_rs, clinsig, clintrait) VALUES ";
my $mysql_query = $mysql_query_fresh;

for (my $i=0; $i<scalar(@input_file_lines); $i++) {
	# Print indexing finished message once parsing starts
	if ($i == 0) { # Disregard the header line
		print "\nFinished indexing input file.\n";
		
		next;
	}
	
	# Ignore header lines
	if ($input_file_lines[$i] =~ /^#.*/) {
		next;
	}
	
	# Split the row by tab characters
	my @split_line = split(/\t/, $input_file_lines[$i]);
	
	if (scalar(@split_line) == 0) {
		print "WARNING: Found a line in the input file that does not contain tab-separated values. Line number: ".($i + 1)." Line contents: ".$input_file_lines[$i]."\n";
		
		next;
	} elsif (scalar(@split_line) != $num_input_columns) {
		print "WARNING: Found a line that doesn't contain ".$num_input_columns." columns of information. Line number: ".($i + 1)." Line contents: ".$input_file_lines[$i]." Number of columns detected: ".scalar(@split_line)."\n";
		
		next;
	}
	
	my $chr = $split_line[0];
	my $position = $split_line[1];
	my $clinvar_variation_id = $split_line[2]; # Extract the clinvar variation id, this used to be the dbSNP rs ID prior to 10/2017
	my $ref = $split_line[3];
	my $alt = $split_line[4];
	my $clinsig = "";
	my $clintrait = "";
	
	# Extract the clinical significance
	if ($split_line[7] =~ /CLNSIG=(.*?);/) {
		$clinsig = $1;
	# Some variants don't have a CLNSIG= as of 10/2017
	} else {
		$clinsig = "Unknown";
	}
	
	# Extract the clinical trait
	if ($split_line[7] =~ /CLNDN=(.*?);/) {
		$clintrait = $1;
	# Some variants don't have a clinical trait as of 10/2017
	} else {
		$clintrait = "Unknown";
	}
	
	my @split_alt = split(/,/, $alt);

	#1	949523	183381	C	T	.	.	ALLELEID=181485;CLNDISDB=MedGen:C4015293,OMIM:616126,Orphanet:ORPHA319563;CLNDN=Immunodeficiency_38_with_basal_ganglia_calcification;CLNHGVS=NC_000001.10:g.949523C>T;CLNREVSTAT=no_assertion_criteria_provided;CLNSIG=Pathogenic;CLNVC=single_nucleotide_variant;CLNVCSO=SO:0001483;CLNVI=OMIM_Allelic_Variant:147571.0003;GENEINFO=ISG15:9636;MC=SO:0001587|nonsense;ORIGIN=1;RS=786201005
	
	foreach my $alt (@split_alt) {
		# Insert a ? as a reference to each variable, this is then populated in the execute() function below on the array of values to put in
		$mysql_query .= "(?, ?, ?, ?, ?, ?, ?), ";
	
		$inserted_rows++;
		
		# Add the values to be inserted
		push(@insert_values, $chr); # chr
		push(@insert_values, $position); # position
		push(@insert_values, $ref); # ref
		push(@insert_values, $alt); # alt
		push(@insert_values, $clinvar_variation_id); # clinvar_rs
		push(@insert_values, $clinsig); # clinsig
		push(@insert_values, $clintrait); # clintrait
		
		# If there are $num_rows_to_add_per_insert waiting to be inserted OR the end of the input file has been reached so all the remaining rows should be inserted
		if ($num_rows_to_add_per_insert == scalar(@insert_values) / $num_insert_columns || ($i + 1) == scalar(@input_file_lines)) {
			chop($mysql_query); # Remove the extra space at the end of the list of data
			chop($mysql_query); # Remove the extra comma at the end of the list of data
		
			$mysql_query .= ";";
		
			# Execute the insertion of the row into the MySQL DB
			my $sth = $dbh->prepare($mysql_query);
			$sth->execute(@insert_values) or die $DBI::errstr."\n\nQuery causing problem: ".$mysql_query;
			$sth->finish();
		
			# Empty the array of values to add
			@insert_values = ();
		
			# Reset the MySQL query
			$mysql_query = $mysql_query_fresh;
		}		
	}
	
	if ($i =~ /0000$/) {
		print "[".localtime()."] Processed: ".$i." lines from a total of ".(scalar(@input_file_lines)-1).".\n";
	}
}

print "\nPARSING COMPLETE!\nInserted a total of ".$inserted_rows." from ".(scalar(@input_file_lines)-1)." lines in the input file (this includes header lines). Multi-allelic sites are split up so more can be inserted than are present in the input file.\n\n";

exit;