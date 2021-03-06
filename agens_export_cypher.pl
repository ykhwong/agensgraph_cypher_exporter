use strict;
use IPC::Open2;
my ($pid, $out, $in);
my %node;
my $flag;
my $changed=0;
my $compt="agens";
my $label_st;
my $idx_uniq_st;
my $no_index=0;
my $no_unique_constraint=0;
my $last_uc_label;
my ($last_ve_label, $last_ve_type);
my (%vlabel, %elabel, $inherits);

sub _get_idx {
	my $ls = shift;
	if ($ls !~ /^.+\s*\|\s*(CREATE +PROPERTY +INDEX )/i) {
		return;
	}
	$ls =~ s/^.+\s*\|\s*(CREATE +PROPERTY +INDEX )/$1/i;
	$ls =~ s/\)(\s*)$/);$1/;
	if ($compt eq "agens") {
		$idx_uniq_st .= $ls;
		return;
	}
	$ls =~ s/CREATE +PROPERTY +INDEX +(.+) +ON +(\S+) +USING +btree *\((.+)\)/CREATE INDEX ON :$2($3)/i;
	$idx_uniq_st .= $ls;
}

sub _get_labels {
	my ($ls, $graph_name) = @_;
	if ($ls =~ /(Vertex|Edge) +label +"(\S+)"\s*$/i) {
		my $type = $1;
		my $label = $2;
		$label =~ s/(.+)\.(.+)/$2/;
		return if ($label =~ /^(ag_vertex|ag_edge)$/i);
		$last_ve_label = $label;
		$last_ve_type = $type;
		if ($type =~ /vertex/i) {
			$vlabel{$label} = "";
		} else {
			$elabel{$label} = "";
		}
		return;
	}
	if ($inherits) {
		if ($ls =~ /^\s*(.+)\s*$/) {
			my $inherit = $1;
			$inherit =~ s/(.+)\.(.+)/$2/;
			if ($inherit =~ /,$/) {
				$inherit =~ s/,$//;
				$inherits .= ", $inherit";
			} else {
				$inherits .= ", $inherit";
				$vlabel{$last_ve_label} = $inherits if ($last_ve_type =~ /vertex/i);
				$elabel{$last_ve_label} = $inherits if ($last_ve_type =~ /edge/i);
				undef $inherits;
			}
		}
	}
	if ($ls =~ /^Inherits: +(.+)\s*$/i) {
		my $inherit = $1;
		$inherit =~ s/(.+)\.(.+)/$2/;
		undef $inherits;
		return if ($inherit =~ /^(ag_vertex|ag_edge)$/i);
		if ($inherit =~ /,$/) {
			$inherit =~ s/,$//;
			$inherits = $inherit;
		} else {
			$vlabel{$last_ve_label} = $inherit if ($last_ve_type =~ /vertex/i);
			$elabel{$last_ve_label} = $inherit if ($last_ve_type =~ /edge/i);
		}
	}
}

sub _create_label_st {
	my $inherit_st;
	foreach my $key (keys %vlabel) {
		my $val = $vlabel{$key};
		if ($val eq "") {
			$label_st .= "CREATE VLABEL $key;\n";
		} else {
			$inherit_st .= "CREATE VLABEL $key INHERITS ($val);\n";
		}
	}
	foreach my $key (keys %elabel) {
		my $val = $elabel{$key};
		if ($val eq "") {
			$label_st .= "CREATE ELABEL $key;\n";
		} else {
			$inherit_st .= "CREATE ELABEL $key INHERITS ($val);\n";
		}
	}
	$label_st .= $inherit_st;
}

sub _get_unique_constraints {
	my $ls = shift;
	if ($ls =~ /(Vertex|Edge) +label "(\S+)"\s*$/i) {
		$last_uc_label = $2;
		$last_uc_label =~ s/(.+)\.(.+)/$2/;
		return;
	}
	if ($ls =~ / UNIQUE +USING +btree +\((\S+)\)\s*$/i) {
		my $key = $1;
		$idx_uniq_st .= "CREATE CONSTRAINT ON ";
		if ($compt eq "agens") {
			$idx_uniq_st .= "$last_uc_label ASSERT $key IS UNIQUE;\n";
		} else {
			$idx_uniq_st .= "(u1:$last_uc_label) ASSERT u1.$key IS UNIQUE;\n";
		}
	}
	return;
}

sub proc {
	my $ls = shift;
	return "" if ($ls =~ /^-+\s*$/);
	return "" if ($ls =~ /^\((\d+) rows*\)/);

	if ($compt eq "agens") {
		$ls =~ s/'/''/g;
		$ls =~ s/\\"([\},])/\\\\'$1/g;
		$ls =~ s/([^\\])(`|")/$1'/g;
		$ls =~ s/\\"/"/g;
	} else {
		$ls =~ s/(\s*\{)"(\S+)"(:\s*)/$1$2$3/g;
	}
	if ($ls =~ /^\s*(n|r)\s*$/) {
		$flag=$1;
		return "";
	}
	if ($flag eq "n") {
		if ($ls =~ /^ +(\S+)\[(\d+\.\d+)\]\{(.*)\}\s*$/) {
			my $vlabel = $1;
			my $s_id = $2;
			my $prop = $3;
			$node{$s_id} = $vlabel . "\t" . $prop;
			$changed=1;
			return "CREATE (:$vlabel {$prop});\n";
		}
	}
	if ($flag eq "r") {
		if ($ls =~ /^ +(\S+)\[(\d+\.\d+)\]\[(\d+\.\d+),(\d+\.\d+)\]\{(.*)\}\s*$/) {
			my $elabel = $1;
			my $n1_id = $3;
			my $n2_id = $4;
			my ($n1_vlabel, $n1_prop) = (split /\t/, $node{$n1_id});
			my ($n2_vlabel, $n2_prop) = (split /\t/, $node{$n2_id});
			$changed=1;
			return "MATCH (n1:$n1_vlabel {$n1_prop}), (n2:$n2_vlabel {$n2_prop}) CREATE (n1)-[:$elabel]->(n2);\n";
		}
	}
	return "";
}

sub make_graph_st {
	my $graph_name = shift;
	return "DROP GRAPH IF EXISTS $graph_name CASCADE;\nCREATE GRAPH $graph_name;\nSET GRAPH_PATH=$graph_name;";
}

sub main {
	my $graph_name;
	my ($st, $graph_st);
	my $opt;
	foreach my $arg (@ARGV) {
		if ($arg =~ /^--graph=(\S+)$/) {
			$graph_name=$1;
			next;
		}
		if ($arg =~ /^--compt=(\S+)$/) {
			$compt=$1;
			next;
		}
		if ($arg =~ /^--no-index$/) {
			$no_index=1;
			next;
		}
		if ($arg =~ /^--no-unique-constraint$/) {
			$no_unique_constraint=1;
			next;
		}
		if ($arg =~ /^(--)(dbname|host|port|username)(=\S+)$/) {
			$opt.=" " . $1 . $2 . $3;
			next;
		}
		if ($arg =~ /^(--)(no-password|password)$/) {
			$opt.=" " . $1 . $2;
			next;
		}
		if ($arg =~ /^--/ || $arg =~ /^--(h|help)$/) {
			printf("USAGE: perl $0 [--graph=GRAPH_NAME] [--compt={agens|neo4j}] [--no-index] [--no-unique-constraint] [--help]\n");
			printf("   Basic parameters:\n");
			printf("      [--compt=agens]   : Output for AgensGraph (default)\n");
			printf("      [--compt=neo4j]   : Output for Neo4j\n");
			printf("   Additional optional parameters for the AgensGraph integration:\n");
			printf("      [--dbname=DBNAME] : Database name\n");
			printf("      [--host=HOST]     : Hostname or IP\n");
			printf("      [--port=PORT]     : Port\n");
			printf("      [--username=USER] : Username\n");
			printf("      [--no-password]   : No password\n");
			printf("      [--password]      : Ask password (should happen automatically)\n");
			exit 0;
		}
	}

	if ($compt !~ /^(agens|neo4j)$/) {
		printf("Invalid parameter: --compt=$compt\n");
		exit 1;
	}
	if (!$graph_name) {
		printf("Please specify the --graph= parameter for the graph repository.\n");
		exit 1;
	}

	if ($^O eq 'MSWin32' || $^O eq 'cygwin' || $^O eq 'dos') {
		`agens --help >nul 2>&1`;
	} else {
		`agens --help >/dev/null 2>&1`;
	}
	if ($? ne 0) {
		printf("agens client is not available.\n");
		exit 1;
	}
	if ($compt eq "agens") {
		$graph_st = make_graph_st($graph_name);
		printf("%s\n", $graph_st);
	}
	$pid = open2 $out, $in, "agens -q $opt";
	die "$0: open2: $!" unless defined $pid;

	unless ($no_index) {
		$st = "\\dGi $graph_name.*;";
		print $in $st . "\n";
		while (<$out>) {
			my $ls = $_;
			last if ($ls =~ /No matching property|^\(\d+ +rows\)/i);
			_get_idx($ls);
		}
	}

	$st = "\\dGv $graph_name.*; \\dGe $graph_name.*; \\echo THE_END;";
	print $in $st . "\n";
	while (<$out>) {
		my $ls = $_;
		last if ($ls =~ /^THE_END/i);
		_get_unique_constraints($ls) unless ($no_unique_constraint);
		_get_labels($ls, $graph_name) if ($compt eq "agens");
	}

	if ($compt eq "agens") {
		_create_label_st();
		print $label_st;
	}

	$st = "SET GRAPH_PATH=$graph_name; MATCH (n) RETURN n; MATCH ()-[r]->() RETURN r; \\echo THE_END;";
	print $in $st . "\n";
	while (<$out>) {
		my $ls = $_;
		last if ($ls =~ /^THE_END/i);
		print proc($ls);
	}

	if ($changed eq 0) {
		if ($compt eq "agens") {
			printf("-- Nothing to do\n");
		} else {
			printf("// Nothing to do\n");
		}
	}

	printf("%s", $idx_uniq_st);
}

main();

