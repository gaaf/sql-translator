#!/usr/bin/perl

# -------------------------------------------------------------------
# $Id: sqlt-dumper.pl,v 1.3 2003-08-21 00:29:57 kycl4rk Exp $
# -------------------------------------------------------------------
# Copyright (C) 2003 Ken Y. Clark <kclark@cpan.org>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation; version 2.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
# 02111-1307  USA
# -------------------------------------------------------------------

=head1 NAME

sqlt-dumper.pl - create a dumper script from a schema

=head1 SYNOPSIS

  ./sqlt-dumper.pl -d Oracle [options] schema.sql > dumper.pl
  ./dumper.pl > data.sql

  Options:

    -h|--help       Show help and exit
    --add-truncate  Add "TRUNCATE TABLE" statements for each table
    --skip=t1[,t2]  Skip tables in comma-separated list
    -u|--user       Database username
    -p|--password   Database password
    --dsn           DSN for DBI

=head1 DESCRIPTION

This script uses SQL::Translator to parse the SQL schema and create a
Perl script that can connect to the database and dump the data as
INSERT statements a la mysqldump.  If you enable "add-truncate" or
specify tables to "skip," then the generated dumper script will have
those hardcoded.  However, these will also be options in the generated
dumper, so you can wait to specify these options when you dump your
database.  The database username, password, and DSN can be hardcoded
into the generated script, or part of the DSN can be intuited from the
"database" argument.

=cut

use strict;
use Pod::Usage;
use Getopt::Long;
use SQL::Translator;

my ( $help, $db, $add_truncate, $skip, $db_user, $db_pass, $dsn );
GetOptions(
    'h|help'        => \$help,
    'd|f|from|db=s' => \$db,
    'add-truncate'  => \$add_truncate,
    'skip:s'        => \$skip,
    'u|user:s'      => \$db_user,
    'p|password:s'  => \$db_pass,
    'dsn:s'         => \$dsn,
) or pod2usage;

pod2usage(0) if $help;
pod2usage( 'No database driver specified' ) unless $db;
$db_user ||= 'username';
$db_pass ||= 'password';
$dsn     ||= "dbi:$db:_";

my $file = shift @ARGV or pod2usage( -msg => 'No input file' );

my $t = SQL::Translator->new;
$t->parser( $db ) or die $t->error, "\n";
$t->filename( $file ) or die $t->error, "\n";

my %skip = map { $_, 1 } map { s/^\s+|\s+$//; $_ } split (/,/, $skip);
my $parser = $t->parser or die $t->error;
$parser->($t, $t->data);
my $schema = $t->schema;
my $now    = localtime;

my $out = <<"EOF";
#!/usr/bin/perl

#
# Generated $now
# By sqlt-dumper.pl, part of the SQLFairy project
# For more info, see http://sqlfairy.sourceforge.net/
#

use strict;
use DBI;
use Getopt::Long;

my ( \$help, \$add_truncate, \$skip );
GetOptions(
    'h|help'        => \\\$help,
    'add-truncate'  => \\\$add_truncate,
    'skip:s'        => \\\$skip,
);

if ( \$help ) {
    print <<"USAGE";
Usage:
  \$0 [options]

  Options:
    -h|--help       Show help and exit
    --add-truncate  Add "TRUNCATE TABLE" statements
    --skip=t1[,t2]  Comma-separated list of tables to skip

USAGE
    exit(0);
}

my \%skip = map { \$_, 1 } map { s/^\\s+|\\s+\$//; \$_ } split (/,/, \$skip);
my \$db = DBI->connect('$dsn', '$db_user', '$db_pass');

EOF

for my $table ( $schema->get_tables ) {
    my $table_name  = $table->name;
    next if $skip{ $table_name };
    my ( @field_names, %types );
    for my $field ( $table->get_fields ) {
        $types{ $field->name } = $field->data_type =~ m/(char|str|long|text)/
            ? 'string' : 'number';
        push @field_names, $field->name;
    }

    $out .= join('',
        "#\n# Table: $table_name\n#\n{\n",
        "    next if \$skip{'$table_name'};\n",
        "    print \"--\\n-- Data for table '$table_name'\\n--\\n\";\n\n",
        "    if ( \$add_truncate ) {\n",
        "        print \"TRUNCATE TABLE $table_name;\\n\";\n",
        "    }\n\n",
    );

    my $insert = "INSERT INTO $table_name (". join(', ', @field_names).
            ') VALUES (';

    if ( $add_truncate ) {
        $out .= "    print \"TRUNCATE TABLE $table_name;\\n\";\n";
    }

    $out .= join('',
        "    my \%types = (\n",
        join("\n", map { "        $_ => '$types{ $_ }'," } @field_names), 
        "\n    );\n\n",
        "    my \$data  = \$db->selectall_arrayref(\n",
        "        'select ", join(', ', @field_names), " from $table_name',\n",
        "        { Columns => {} },\n",
        "    );\n\n",
        "    for my \$rec ( \@{ \$data } ) {\n",
        "        my \@vals;\n",
        "        for my \$fld ( qw[", join(' ', @field_names), "] ) {\n",
        "            my \$val = \$rec->{ \$fld };\n",
        "            if ( \$types{ \$fld } eq 'string' ) {\n",
        "                \$val =~ s/'/\\'/g;\n",
        "                \$val = defined \$val ? qq['\$val'] : qq[''];\n",
        "            }\n",
        "            else {\n",
        "                \$val = defined \$val ? \$val : 'NULL';\n",
        "            }\n",
        "            push \@vals, \$val;\n",
        "        }\n",
        "        print \"$insert\", join(', ', \@vals), \");\\n\";\n",
        "    }\n",
        "    print \"\\n\";\n",
        "}\n\n",
    );
}

print $out;
