package App::Sqitch::Engine::bigquery;

use 5.010;
use Moo;
use App::Sqitch::X qw(hurl);
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::Plan;
use App::Sqitch::Types qw(Str ArrayRef);
use namespace::autoclean;
use JSON qw(decode_json);
use URI;
use URI::QueryParam;
use Try::Tiny;
use Data::Dumper;
use Path::Class;
use App::Sqitch::DateTime;

extends 'App::Sqitch::Engine';

our $VERSION = '0.01';
use constant MAX_LIMIT => 9223372036854775807;  # BigQuery needs a LIMIT before any OFFSET

# Required attributes
has 'key' => (
    is      => 'ro',
    isa     => Str,
    default => sub { 'bigquery'},
);

has 'name' => (
    is      => 'ro',
    isa     => Str,
    default => sub { 'Google BigQuery' },
);

sub default_client {
    return 'bq';
}

# Returns the bq command array
sub bq { return ($_[0]->client) }

# Returns standard bq CLI options
sub _client_opts {
    my $self = shift;
    my $uri = $self->target->uri;

    return (
        '--use_legacy_sql=false',
        '--format=json',
        '--quiet',
        '--nouse_cache',
        '--project_id=' . $uri->host,
        '--location=' . $uri->query_param('location'),
    );
}

sub _run {
    my $self = shift;
    my $subcommand = shift;
    my $sqitch = $self->sqitch;
    return $sqitch->run( $self->bq, $subcommand, $self->_client_opts, @_ );
}

# Execute bq command and capture output
# bq requires: bq <subcommand> options <args>
sub _capture {
    my $self = shift;
    my $subcommand = shift;
    my $sqitch = $self->sqitch;
    return $sqitch->capture( $self->bq, $subcommand, $self->_client_opts, @_ );
}

sub registry_version {
    return '1.1';
}

# Return the dataset name fro URI, dafaulting to 'sqitch'
# For BigQuery, the registry dataset contains all Sqitch tables
# 
sub registry {
    my $self = shift;
    return $self->target->registry;
}

# Checks whether the Sqitch registry has been initialized by verifying the existence of the 'changes' table
sub _initialized {
    my $self = shift;

    my $target   = $self->target;
    my $project  = $target->uri->host;
    my $dataset  = $self->registry;
    my $location = $target->uri->query_param('location');
    hurl engine => "Missing required location parameter in URI: " . $self->target->uri->as_string
      unless $location;

    my $sql = qq{
        SELECT COUNT(*) > 0 AS table_exists
        FROM `$project.$dataset.INFORMATION_SCHEMA.TABLES`
        WHERE table_name = 'changes'
    };

    my $result;
    try {
        $result = $self->_run_bq_query($sql);
        
        # Defensive check: ensure result is defined and has expected structure);
        if (ref $result eq 'ARRAY' && @$result && exists $result->[0]->{table_exists}) {
            return ($result->[0]->{table_exists} // '') eq 'true' ? 1 : 0;
        } else {
            warn "Unexpected result structure from _run_bq_query: " . Dumper($result);
            return 0;
        }
    } catch {
        return 0 if /Not\s+found:\s+Dataset/;
        hurl engine => "Error checking initialization: $_";
    };
}

# Initialize the engine
sub _initialize {
    my $self = shift;
    hurl engine => __x(
        'Sqitch registry "{registry}" already exists',
        registry => $self->registry,
    ) if $self->initialized;

    $self->_run_registry_file( file(__FILE__)->dir->file($self->key . '.sql') );
    $self->_register_release;
}

sub _run_registry_file {
    my ($self, $file) = @_;
    my $uri = $self->target->uri;
    my $project = $uri->host;
    my $dataset = $self->registry;
    my $location = $uri->query_param('location');

    hurl engine => "Missing required location parameter in URI: " . $uri->as_string
      unless defined $location;

    # Create the dataset first
    my $destination = "`$project.$dataset`";
    $self->_run_bq_exec(
        qq{CREATE SCHEMA IF NOT EXISTS $destination OPTIONS(location="$location")}
    );

    # Read the SQL file
    my $sql = scalar $file->slurp;

    # Replace :registry placeholder with actual registry name.
    # Unlike PostgreSQL's psql which supports variable substitution (e.g., :\"registry\"),
    # BigQuery's bq CLI does NOT have variable substitution, so we must do it manually in Perl.
    $sql =~ s/:registry/$dataset/g;

    # Remove SQL comments (-- style)
    $sql =~ s/--[^\n]*\n/\n/g;

    # Split into individual statements
    my @statements = split /;\s*\n/, $sql;

    for my $statement (@statements) {
        # Remove leading/trailing whitespace
        $statement =~ s/^\s+|\s+$//g;

        # Skip empty statements
        next unless $statement =~ /\S/;

        # Remove extra whitespace and newlines
        $statement =~ s/\s+/ /g;

        try {
            $self->_run_bq_exec($statement);
        } catch {
            hurl engine => "Failed to execute registry SQL: $_\nStatement: $statement";
        };
    }

    return $self
}

sub _register_release {
    my $self = shift;
    my $version = shift || $self->registry_release;
    my $sqitch  = $self->sqitch;

    my $project_id = $self->target->uri->host;
    my $dataset    = $self->registry;

    my $sql = qq{
        INSERT INTO `$project_id.$dataset.releases` (version, installer_name, installer_email)
        VALUES ($version, '${\$sqitch->user_name}', '${\$sqitch->user_email}')
    };

    $self->_run_bq_exec($sql);
    return $self;
}

# Check dataset exists
sub _dataset_exists {
    my ($self, $project_id, $location, $dataset) = @_;
    my $cmd = join ' ', $self->client, 'show', "--location=$location", "$project_id:$dataset";

    my $output = `$cmd 2>&1`;
    my $exit_code = $? >> 8;

    $self->sqitch->debug("bq show output: $output");

    if ($exit_code == 0) {
        return 1; # Dataset exists
    } else {
        return 0; # Dataset does not exist
    }
}

# Retrieves the most recent deployed change from the changes table
sub current_state {
    my $self = shift;
    my $uri        = $self->target->uri;
    my $project_id = $uri->host;
    my $dataset    = $self->registry;
    my $location   = $uri->query_param('location');

    hurl engine => "Missing required location parameter in URI: " . $uri->as_string
      unless defined $location;

    # Check if dataset exists
    return undef unless $self->_dataset_exists($project_id, $location, $dataset);

    # Get latest change with its tags in a single query
    my $sql = qq{
        SELECT c.change_id, c.change, c.committed_at, c.planner_name, c.planner_email,
               c.script_hash, c.committer_name, c.committer_email, STRING_AGG(t.tag ORDER BY t.tag) AS tags
        FROM `$project_id.$dataset.changes` c
        LEFT JOIN `$project_id.$dataset.tags` t ON c.change_id = t.change_id
        GROUP BY c.change_id, c.change, c.committed_at, c.planner_name, c.planner_email, c.script_hash, c.committer_name, c.committer_email
        ORDER BY c.committed_at DESC
        LIMIT 1
    };

    my $result;
    try {
        $result = $self->_run_bq_query($sql);
    } catch {
        hurl engine => "Failed to retrieve current state: $_";
    };
    return undef unless ref $result eq 'ARRAY' && @$result;

    my $row = $result->[0];
    my $change_id     = $row->{change_id};
    my $change        = $row->{change};
    my $committed_raw = $row->{committed_at};
    my $planner_name  = $row->{planner_name};
    my $planner_email = $row->{planner_email};
    my $tags_str      = $row->{tags};

    # Parse timestamp
    my ($year, $month, $day, $hour, $min, $sec) = 
        $committed_raw =~ /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})$/;

    unless (defined $year) {
        warn "Unable to parse committed_at: $committed_raw";
        hurl engine => "Invalid timestamp format in committed_at: $committed_raw";
    }

    my $committed_at = $self->_parse_timestamp($committed_raw)
        // hurl engine => "Invalid timestamp format in committed_at: $committed_raw";

    # Parse tags from comma-separated string
    my @tags = $tags_str ? split(/,/, $tags_str) : ();

    return {
        project       => $self->plan->project,
        change_id     => $change_id,
        change        => $change,
        committed_at  => $committed_at,
        planner_name  => $planner_name,
        planner_email => $planner_email,
        script_hash     => $row->{script_hash},
        committer_name  => $row->{committer_name},
        committer_email => $row->{committer_email},
        tags          => \@tags,
    };
}

# Returns an iterator over the deployed changes of a project, newest first.
sub current_changes {
    my ($self, $project) = @_;
    my $project_id = $self->target->uri->host;
    my $dataset    = $self->registry;
    $project = $self->plan->project unless defined $project;
    my $q_project  = $self->_quote($project);

    my $sql = qq{
        SELECT c.change_id, c.script_hash, c.change,
               c.committer_name, c.committer_email,
               FORMAT_TIMESTAMP('%Y-%m-%d %H:%M:%S', c.committed_at) AS committed_at,
               c.planner_name, c.planner_email,
               FORMAT_TIMESTAMP('%Y-%m-%d %H:%M:%S', c.planned_at) AS planned_at
          FROM `$project_id.$dataset.changes` c
         WHERE c.project = $q_project
         ORDER BY c.committed_at DESC
    };

    my $rows  = $self->_run_bq_query($sql);
    my $index = 0;

    return sub {
        return if $index >= @$rows;
        my $row = $rows->[$index++];
        $row->{committed_at} = $self->_parse_timestamp($row->{committed_at});
        $row->{planned_at}   = $self->_parse_timestamp($row->{planned_at});
        return $row;
    };
}

# Returns the names of the projects registered in the database, sorted.
sub registered_projects {
    my $self = shift;
    my $project_id = $self->target->uri->host;
    my $dataset    = $self->registry;

    my $rows = $self->_run_bq_query(
        "SELECT project FROM `$project_id.$dataset.projects` ORDER BY project"
    );
    return map { $_->{project} } @$rows;
}

sub project {
    my $self = shift;
    return $self->plan->project;
}

# Checks which changes have already been deployed by querying the changes table
sub are_deployed_changes {
    my ($self, @changes) = @_;
    return unless @changes;

    my $uri        = $self->target->uri;
    my $project_id = $uri->host;
    my $dataset    = $self->registry;
    my $changes_table = "`$project_id.$dataset.changes`";
    
    # Extract change IDs
    my @ids = map { $_->id } @changes;
    my $in_clause = join(",", map {"'$_'"} @ids);

    my $sql = qq{
        SELECT change_id
        FROM $changes_table
        WHERE change_id IN ($in_clause)
    };

    my $results = $self->_run_bq_query($sql);
    $self->sqitch->debug("Found deployed change_ids: " . join(", ", map { $_->{change_id} } @$results));

    my %seen = map { $_->{change_id} => 1 } @$results;
    return map { $_->id } grep { $seen{ $_->id } } @changes;
}

# Returns true if the change is recorded in the registry's changes table.
sub is_deployed_change {
    my ($self, $change) = @_;
    my $project_id = $self->target->uri->host;
    my $dataset    = $self->registry;
    my $change_id  = $change->id;

    my $sql = qq{
        SELECT EXISTS(
            SELECT 1
              FROM `$project_id.$dataset.changes`
             WHERE change_id = '$change_id'
        ) AS change_exists
    };

    my $result = $self->_run_bq_query($sql);
    return ($result->[0]{change_exists} // '') eq 'true' ? 1 : 0;
}

# load_changes
# Loads all deployed changes from the changes table and returns them as Change objects.
sub load_changes {
    my $self = shift;
    my $project = $self->target->uri->host;
    my $dataset = $self->registry;

    my $sql = qq{
        SELECT change_id, change, project, note, committed_at, committer_name, committer_email, planned_at,
        planner_name, planner_email, script_hash
        FROM `$project.$dataset.changes`
        ORDER BY committed_at
    };

    my $rows = $self->_run_bq_query($sql);

    return map {
        App::Sqitch::Plan::Change->new(
            name            => $_->{change},
            id              => $_->{change_id},
            project         => $_->{project},
            note            => $_->{note},
            timestamp       => $self->_parse_timestamp($_->{committed_at}),
            committer_name  => $_->{committer_name},
            committer_email => $_->{committer_email},
            planner_name    => $_->{planner_name},
            planner_email   => $_->{planner_email},
            planned_at      => $self->_parse_timestamp($_->{planned_at}),
            script_hash     => $_->{script_hash},
            plan            => $self->plan,
        )
    } @$rows;
}

# load_change
# Loads a single deployed change by ID
sub load_change {
    my ($self, $change_id) = @_;
    my $project = $self->target->uri->host;
    my $dataset = $self->registry;

    my $sql = qq{
        SELECT change_id, change, project, note, committed_at,
               committer_name, committer_email, planned_at,
               planner_name, planner_email, script_hash
        FROM `$project.$dataset.changes`
        WHERE change_id = '$change_id'
        LIMIT 1
    };

    my $rows = $self->_run_bq_query($sql);

    unless (@$rows) {
        return;
    }

    my $row = $rows->[0];

    # Parse timestamps
    my $committed_at = $self->_parse_timestamp($row->{committed_at});
    my $planned_at   = $self->_parse_timestamp($row->{planned_at});

    return App::Sqitch::Plan::Change->new(
        name            => $row->{change},
        id              => $row->{change_id},
        project         => $row->{project},
        note            => $row->{note},
        timestamp       => $committed_at,
        committer_name  => $row->{committer_name},
        committer_email => $row->{committer_email},
        planner_name    => $row->{planner_name},
        planner_email   => $row->{planner_email},
        planned_at      => $planned_at,
        script_hash     => $row->{script_hash},
        plan            => $self->plan,
    );
}

# Returns a Change object for a given change ID by delegating to load_change().
# This is used by Sqitch to resolve deployed change IDs to full change metadta.
sub change_for_id {
    my ($self, $change_id) = @_;
    return $self->load_change($change_id);
}

# Returns a list of deployed changes as hashrefs of deployment.
sub deployed_changes {
    my $self = shift;

    my $project_id = $self->target->uri->host;
    my $dataset    = $self->registry;
    my $project    = $self->plan->project;

    # Query to get changes with their tags
    # Use STRING_AGG with space delimiter as PostgreSQL uses.
    my $sql = qq{
        SELECT c.change_id AS id, c.change AS name, c.project, c.note, 
               c.planned_at AS timestamp, c.planner_name, c.planner_email,
               c.script_hash,
               STRING_AGG(t.tag, ' ' ORDER BY t.tag) AS tags
        FROM `$project_id.$dataset.changes` c
        LEFT JOIN `$project_id.$dataset.tags` t 
            ON c.change_id = t.change_id
        WHERE c.project = '$project'
        GROUP BY c.change_id, c.change, c.project, c.note, c.planned_at,
                 c.planner_name, c.planner_email, c.committed_at, c.script_hash
        ORDER BY c.committed_at ASC
    };

    my $rows = $self->_run_bq_query($sql);

    # Return a hashrefs with proper tag arrays
    return map {
        # split the space-separated tags string into an array ILike PostgreSQL does)
        my $tags = $_->{tags} ? [ split / / => $_->{tags} ] : [];
        +{
            id            => $_->{id},
            name          => $_->{name},
            project       => $_->{project},
            note          => $_->{note},
            timestamp     => $self->_parse_timestamp($_->{timestamp}),
            planner_name  => $_->{planner_name},
            planner_email => $_->{planner_email},
            script_hash   => $_->{script_hash},
            tags          => $tags,
        }
    } @$rows
}

# Returns all changes deployed since a given change (exclusive)
# Used by revert to determine which changes need to be reverted
sub deployed_changes_since {
    my ($self, $change) = @_;

    my $project_id = $self->target->uri->host;
    my $dataset    = $self->registry;
    my $project    = $self->plan->project;

    my $change_id  = ref $change ? $change->id : $change;

    # Get all changes deployed after the target change
    my $sql = qq{
        SELECT c.change_id AS id, c.change AS name, c.project, c.note, 
               c.planned_at AS timestamp, c.planner_name, c.planner_email,
               c.script_hash
        FROM `$project_id.$dataset.changes` c
        WHERE c.project = '$project'
          AND c.committed_at > (
              SELECT committed_at 
              FROM `$project_id.$dataset.changes` 
              WHERE change_id = '$change_id' AND project = '$project'
          )
        ORDER BY c.committed_at ASC
    };

    my $rows = $self->_run_bq_query($sql);

    # Return as hashrefs with tags
    return map {
        +{
            id            => $_->{id},
            name          => $_->{name},
            project       => $_->{project},
            note          => $_->{note},
            timestamp     => $self->_parse_timestamp($_->{timestamp}),
            planner_name  => $_->{planner_name},
            planner_email => $_->{planner_email},
            script_hash   => $_->{script_hash},
            tags          => [], # Tags not retrieved here
        }
    } @$rows;
}

# Returns the ID of the most recently deployed change.
sub latest_change_id {
    my ($self, $offset) = @_;
    my $project_id = $self->target->uri->host;
    my $dataset    = $self->registry;
    my $project    = $self->plan->project;
    $offset ||= 0;

    my $sql = qq{
        SELECT change_id
        FROM `$project_id.$dataset.changes`
        WHERE project = '$project'
        ORDER BY committed_at DESC
        LIMIT 1 OFFSET $offset
    };

    my $rows = $self->_run_bq_query($sql);
    return $rows->[0]->{change_id} if @$rows;
    return undef;
}

# Returns the ID of the earliest deployed change.
# Used by Sqitch log command to determine starting point.
sub earliest_change_id {
    my ($self, $offset, $project) = @_;

    my $project_id = $self->target->uri->host;
    my $dataset = $self->registry;
    $project  ||= $self->plan->project;

    my $offset_clause = defined $offset ? "OFFSET $offset" : '';

    my $sql = qq{
        SELECT change_id
        FROM `$project_id.$dataset.changes`
        WHERE project = '$project'
        ORDER BY committed_at ASC
        LIMIT 1
        $offset_clause
    };

    my $result = $self->_run_bq_query($sql);
    return $result->[0]->{change_id} if @$result;
    return undef;
}

# Searches the events table with various filters and returns an iterator
# Used by sqitch log command to display deployment history
sub search_events {
    my ($self, %p) = @_;

    my $project_id = $self->target->uri->host;
    my $dataset    = $self->registry;

    # Determine order direction
    my $dir = 'DESC';
    if (my $d = delete $p{direction}) {
        $dir = $d =~ /^ASC/i ? 'ASC'
             : $d =~ /^DESC/i ? 'DESC'
             :hurl 'Search direction must be either "ASC" or "DESC"';
    }

    # Build WHERE clauses
    my @wheres;

    # Regexp filters (BigQuery uses REGEXP_CONTAINS)
    for my $spec (
        [ committer => 'e.committer_name' ],
        [ planner   => 'e.planner_name' ],
        [ change    => 'e.change' ],
        [ project   => 'e.project' ],
    ) {
        my $regex = delete $p{$spec->[0]} // next;
        # Escape single quotes in regex
        $regex =~ s/'/''/g;
        push @wheres => "REGEXP_CONTAINS($spec->[1], r'$regex')";
    }

    # Event type filter
    if (my $events = delete $p{event}) {
        my @event_list = ref $events eq 'ARRAY' ? @$events : ($events);
        my $in_clause = join(',', map { "'$_'" } @event_list);
        push @wheres => "e.event IN ($in_clause)";
    }

    # Assemble WHERE clause
    my $where = @wheres
        ? "\n         WHERE " . join("\n               AND ", @wheres)
        : '';

    # Handle LIMIT and OFFSET (BigQuery allows OFFSET only after LIMIT)
    $p{limit} = MAX_LIMIT if defined $p{offset} && !defined $p{limit};

    my $limits = '';
    $limits .= "\n         LIMIT $p{limit}"   if defined $p{limit};
    $limits .= "\n         OFFSET $p{offset}" if defined $p{offset};
    delete @p{qw(limit offset)};

    hurl 'Invalid parameters passed to search_events: '
        . join ', ', sort keys %p if %p;

    # Execute query
    my $sql = qq{
        SELECT e.event, e.project, e.change_id, e.change, e.note,
               e.requires, e.conflicts, e.tags,
               e.committer_name, e.committer_email,
               FORMAT_TIMESTAMP('%Y-%m-%d %H:%M:%S', e.committed_at) AS committed_at,
               e.planner_name, e.planner_email,
               FORMAT_TIMESTAMP('%Y-%m-%d %H:%M:%S', e.planned_at) AS planned_at
        FROM `$project_id.$dataset.events` e$where
        ORDER BY e.committed_at $dir$limits
    };

    my $results = $self->_run_bq_query($sql);
    my $index = 0;

    # Return iterator function
    return sub {
        return undef if $index >= @$results;
        my $row = $results->[$index++];

        # Parse timestamps
        $row->{committed_at} = $self->_parse_timestamp($row->{committed_at});
        $row->{planned_at}   = $self->_parse_timestamp($row->{planned_at});

        # Array are already parsed by BigQuery JSON output
        # But ensure they're array refs
        for my $col (qw(tags requires conflicts)) {
            $row->{$col} = [] unless ref $row->{$col} eq 'ARRAY';
        }

        return $row;
    };
}

# Run a deploy script
sub deploy_change {
    my ($self, $change) = @_;
    my $sqitch = $self->sqitch;

    $sqitch->info(
        "  + ", $change->format_name_with_tags,
        '.' x ($self->max_name_length - length $change->format_name_with_tags), ' '
    );

    $self->begin_work($change);

    return try {
        my $file = $change->deploy_file;
        hurl deploy => "Deploy script $file does not exist" unless -e $file;
        $self->_run_file($file) unless $self->log_only;
    
        try {
            $self->verify_change($change) if $self->with_verify;

            $self->log_deploy_change($change);  # <-- This calls registry_change()
            $sqitch->info('ok');
        } catch {
            $sqitch->vent(eval { $_->message } // $_);
            $self->rollback_work($change);
            try {
                $self->begin_work($change);
                $self->run_revert($change->revert_file) unless $self->log_only;
            } catch {
                $sqitch->vent(eval { $_->message } // $_);
            };
            hurl private => 'Deploy failed';
        };
    } finally {
        $self->finish_work($change);
    } catch {
        $self->log_fail_change($change);
        $sqitch->info('not ok');
        die $_;
    };
}

# Logs a successfully deployed change by registering it in the BigQuery registry.
sub log_deploy_change {
    my ($self, $change) = @_;

    $self->registry_change($change);
    $self->log_new_tags($change);

    # Log the deploy event
    return $self->_log_event('deploy', $change);
 }

# Executes a SQL file using the BigQuery CLI.
sub run_file {
    my ($self, $file) = @_;
    $self->_run_file($file);
}

# Logs a failed change deployment.
sub log_fail_change {
    my ($self, $change) = @_;
    return $self->_log_event('fail', $change);
}

# Returns a list of changes that depend on a specified change, by querying the dependencies table in the BigQuery datase defined by the engine's configuration.
sub changes_requiring_change {
    my ($self, $change) = @_;
    my $change_id = $change->id;

    # Build fully qualified table name
    # Extract project and dataset from the target URI
    my $project_id = $self->target->uri->host;
    my $dataset    = $self->registry;
    my $table      = "$project_id.$dataset.dependencies";

    # Construct the SQL query
    my $sql = qq{
        SELECT change_id
        FROM `$table`
        WHERE dependency_id = '$change_id'
        ORDER BY change_id
    };

    # Run the query
    my $results = $self->_run_bq_query($sql);

    # Parse results into Change objects
    my @changes;
    for my $row (@$results) {
        push @changes, App::Sqitch::Plan::Change->new(
            id   => $row->{change_id},
            plan => $self->plan,
        );
    }

    return @changes;
}

# Removes a deployed change from the Sqitch registry by deleting its record from the changes table.
sub log_revert_change {
    my ($self, $change) = @_;
    my $project  = $self->target->uri->host;
    my $dataset  = $self->registry;
    my $location = $self->target->uri->query_param('location');

    hurl engine => "Missing required location parameter in URI: " . $self->target->uri->as_string
        unless defined $location;
    my $change_id  = $change->id;

    # Retrieve and delete tags associated with the change
    my $tags_sql = qq{
        SELECT tag FROM `$project.$dataset.tags`
        WHERE change_id = '$change_id'
        ORDER BY tag
    };
    my $tags_result = $self->_run_bq_query($tags_sql);
    my @deleted_tags = map { $_->{tag} } @$tags_result;

    # Retrieve and delete dependencies
    my $deps_sql = qq{
        SELECT type, dependency FROM `$project.$dataset.dependencies`
        WHERE change_id = '$change_id'
        ORDER BY dependency
    };
    my $deps_result = $self->_run_bq_query($deps_sql);

    my @requires = map { $_->{dependency} }
                   grep { $_->{type} eq 'require' } @$deps_result;
    my @conflicts = map { $_->{dependency} }
                    grep { $_->{type} eq 'conflict' } @$deps_result;

    # Delete tags, dependencies and change record
    # BigQuery doesn't support foreign key cascades, so we must explicitly delete related records
    my $sql = qq{
        DELETE FROM `$project.$dataset.tags`
        WHERE change_id = '$change_id';

        DELETE FROM `$project.$dataset.dependencies`
        WHERE change_id = '$change_id';

        DELETE FROM `$project.$dataset.changes`
        WHERE change_id = '$change_id';
    };

    try {
        $self->_run_bq_exec($sql);
        $self->sqitch->info("Reverted change: " . $change->name);
    } catch {
        warn "log_revert_change(): Failed to remove change from registry:\nChange: " . $change->name . "\nError: $_";
        hurl engine => "Failed to revert change '$change_id': $_";
    };

    # Log the revert event
    return $self->_log_event('revert', $change, \@deleted_tags, \@requires, \@conflicts);
}

# Run a revert script
sub revert_change {
    my ($self, $change) = @_;
    $self->_run_file($change->revert_file) unless $self->log_only;
    $self->log_revert_change($change);
}

# Run a verify script
sub verify_change {
    my ($self, $change) = @_;
    $self->_run_file($change->verify_file);
}

# Helper to run a SQL file using bq CLI
sub _run_file {
    my ($self, $file) = @_;
 
    # Read the SQL file content
    my $sql = $file->slurp(iomode => '<:encoding(UTF-8)');

    # Perform variable substitution (like PostgreSQL's psql --set)
    # BigQuery's bq CLI does not support variable substitution, so we do it manually
    my $uri = $self->target->uri;
    my $project_id = $uri->host;
    my $dataset    = $uri->dbname;

    # Replace standard Sqitch variables
    $sql =~ s/:project_id\b/$project_id/g;
    $sql =~ s/:dataset\b/$dataset/g;

    # Replace user-defined variables from sqitch.conf
    if (my %vars = $self->variables) {
        for my $var (sort keys %vars) {
            my $val = $vars{$var};
            $sql =~ s/:$var\b/$val/g;
        }   
    }

    # Remove SQL comments (-- style) but preserve the SQL
    $sql =~ s/--[^\n]*//g;

    # Trim leading/trailing whitespace
    $sql =~ s/^\s+|\s+$//g;

    # skip if file is empty after removing comments
    return if $sql !~ /\S/;

    # Execute the SQL using _run_bq_exec
    $self->_run_bq_exec($sql);
}

sub register_project {
    my $self    = shift;
    my $sqitch  = $self->sqitch;
    my $plan    = $self->plan;
    my $proj    = $plan->project;
    my $uri     = $plan->uri;
    my $uri_str = $uri ? $uri->as_string : undef;

    my $project_id = $self->target->uri->host;
    my $dataset    = $self->registry;
    my $projects_table = "`$project_id.$dataset.projects`";

    $self->sqitch->debug("Registering project $proj" . ($uri_str ? ", URI: $uri_str" : " (no URI)"));

    # Check if project already exists
    my $check_sql = qq{
        SELECT EXISTS(
            SELECT 1 FROM $projects_table 
            WHERE project = '$proj'
        ) AS project_exists
    };

    my $result = $self->_run_bq_query($check_sql);
    my $exists = $result->[0]->{project_exists};

    if ($exists && lc($exists) eq 'true') {
        # Project exists - check if URI matches
        my $uri_sql = qq{
            SELECT uri FROM $projects_table 
            WHERE project = '$proj'
            LIMIT 1
        };
        my $uri_result = $self->_run_bq_query($uri_sql);
        my $reg_uri = $uri_result->[0]->{uri};
    
        if ( defined $uri_str && !defined $reg_uri ) {
            hurl engine => __x(
                'Cannot register "{project}" with URI {uri}: already exists with NULL URI',
                project => $proj,
                uri     => $uri_str,
            );
        } elsif ( !defined $uri_str && defined $reg_uri ) {
            hurl engine => __x(
                'Cannot register "{project}" with URI {uri}: already exists with URI {uri}',
                project => $proj,
                uri     => $uri_str,
            );
        } elsif ( defined $uri_str && defined $reg_uri ) {
            hurl engine => __x(
                'Cannot register "{project}" with URI {uri}: already exists with URI {reg_uri}',
                project => $proj,
                uri     => $uri_str,
                reg_uri => $reg_uri,
            ) if $uri_str ne $reg_uri;
        }
        # If both are undef or URIs match, we're good - no action needed
        return $self;
    }

    # Project doesn't exist - check if URI is already used by another project
    if ( defined $uri_str ) {
        my $uri_check_sql = qq{
            SELECT project FROM $projects_table 
            WHERE uri = '$uri_str'
            LIMIT 1
        };
        my $uri_check_result = $self->_run_bq_query($uri_check_sql);

        if (@$uri_check_result) {
            hurl engine => __x(
                'Cannot register "{project}" with URI {uri}: project "{reg_proj}" already using that URI',
                project => $proj,
                uri     => $uri_str,
                reg_proj => $uri_check_result->[0]->{project},
            );
        }
    }

    # Insert the project
    my $user  = $sqitch->user_name;
    my $email = $sqitch->user_email;

    my ($q_proj, $q_uri, $q_user, $q_email) =
        map { $self->_quote($_) } $proj, $uri_str, $user, $email;

    my $sql = qq{
        INSERT INTO $projects_table (
            project, uri, creator_name, creator_email, created_at
        ) VALUES (
            $q_proj, $q_uri, $q_user, $q_email, CURRENT_TIMESTAMP()
        )
    };

    try {
        $self ->_run_bq_exec($sql);
        $self->sqitch->info("Registered project $proj");
    } catch {
        hurl engine => "Failed to register project $_";
    };

    return $self;
}

# Registers a deployed change in the BigQuery registry
sub registry_change {
    my ($self, $change) = @_;

    my $project_id  = $self->target->uri->host;
    my $dataset     = $self->registry;
    my $destination = "`$project_id.$dataset.changes`";

    my $change_id       = $change->id;
    my $change_name     = $change->name;
    my $project         = $self->project;
    my $note            = $change->note;
    my $planner_name    = $change->planner_name;
    my $planner_email   = $change->planner_email;
    my $committer_name  = $self->sqitch->user_name;
    my $committer_email = $self->sqitch->user_email;

    # Use script_hash from Change object
    # Plan::Change calculates this using Digest::SHA with raw binary mode
    my $script_hash = $change->script_hash;
    $_ = $self->_quote($_) for $change_name, $project, $note, $committer_name, $committer_email, $planner_name, $planner_email;

    $self->sqitch->debug("Registering change: $change_name ($change_id)");

    try {
        my $sql = qq{
            INSERT INTO $destination (
                change_id, script_hash, change, project, note, committed_at, committer_name, committer_email, planned_at, planner_name, planner_email
            ) VALUES (
                '$change_id', '$script_hash', $change_name, $project, $note, CURRENT_TIMESTAMP(), $committer_name, $committer_email, CURRENT_TIMESTAMP(), $planner_name, $planner_email
            )
        };

        $self->_run_bq_exec($sql);
    } catch {
        warn "register_change: failed to register change: $_";
        hurl engine => "Failed to register change: $_";
    };

    # Register dependencies (requires and conflicts)
    my $deps_table = "`$project_id.$dataset.dependencies`";

    # Insert required dependencies
    for my $req ($change->requires) {
        my $dep_id = $req->id || '';
        my $dep_name = $req->as_string;

        try {
            my $sql = qq{
                INSERT INTO $deps_table (
                    change_id, type, dependency, dependency_id
                ) VALUES (
                    '$change_id', 'require', '$dep_name', '$dep_id'
                )
            };
            $self->_run_bq_exec($sql);
        } catch {
            warn "register_change: failed to register dependency (require): $_";
            hurl engine => "Failed to register dependency: $_";
        };
    }

    # Insert conflict dependencies
    for my $conf ($change->conflicts) {
        my $dep_id = $conf->id || '';
        my $dep_name = $conf->as_string;

        try {
            my $sql = qq{
                INSERT INTO $deps_table (
                    change_id, type, dependency, dependency_id
                ) VALUES (
                    '$change_id', 'conflict', '$dep_name', '$dep_id'
                )
            };
            $self->_run_bq_exec($sql);
        } catch {
            warn "register_change: Failed to register dependency (conflict): $_";
            hurl engine => "Failed to register dependency: $_";
        };
    }

    return $self;
}

# Get a change by name
sub get_change {
    my ($self, $name) = @_;
    my $project = $self->target->uri->host;
    my $dataset = $self->registry;

    my $sql = qq{
        SELECT change_id, change, project, note, committed_at,
               committer_name, committer_email, planned_at,
               planner_name, planner_email, script_hash
        FROM `$project.$dataset.changes`
        WHERE change = '$name'
        ORDER BY committed_at DESC
        LIMIT 1
    };

    my $rows = $self->_run_bq_query($sql);
    return unless @$rows;

    my $row = $rows->[0];
    return App::Sqitch::Plan::Change->new(
        name           => $row->{change},
        id             => $row->{change_id},
        project        => $row->{project},
        note           => $row->{note},
        timestamp      => $self->_parse_timestamp($row->{committed_at}),
        committer_name => $row->{committer_name},
        committer_email=> $row->{committer_email},
        planner_name   => $row->{planner_name},
        planner_email  => $row->{planner_email},
        planned_at     => $self->_parse_timestamp($row->{planned_at}),
        script_hash    => $row->{script_hash},
        plan           => $self->plan,
    );
}

# Throw an error when a change doesn't exist
sub fail_on_no_change {
    my ($self, $change) = @_;
    hurl engine => __x(
        'Change "{change}" does not exist',
        change=> $change->name,
    );
}

# _parse_timestamp
# Parses a BigQuery timestamp string into an App::Sqitch::DateTime object
sub _parse_timestamp {
    my ($self, $timestamp_str) = @_;

    return undef unless defined $timestamp_str;

    # Parse timestamp manually (assuming format "2025-08-09 17:55:49")
    my ($year, $month, $day, $hour, $minute, $second) =
        $timestamp_str =~ /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})(?:\.\d+)?$/;

    unless (defined $year) {
        warn "Unable to parse timestamp: $timestamp_str";
        return undef;
    }

    return App::Sqitch::DateTime->new(
        year      => $year,
        month     => $month,
        day       => $day,
        hour      => $hour,
        minute    => $minute,
        second    => $second,
        time_zone => 'UTC',
    );
}

# _parse_bq_result
# Normalizes BigQuery JSON output to a consistent format.
# Handles both old format (with rows/schema) and new format (flat array of objects).
sub _parse_bq_result {
    my ($self, $data) = @_;

    return [] unless $data;

    # If it's already an array of hashrefs (new format), return as-is
    if (ref $data eq 'ARRAY') {
        return $data;
    }

    # Handle old bq CLI JSON format with nested rows and schema structure
    if (ref $data eq 'HASH' && $data->{rows} && $data->{schema}) {
        my @results;
        my @field_names = map { $_->{name} } @{$data->{schema}{fields}};

        for my $row (@{$data->{rows}}) {
            my %record;
            for my $i (00..$#field_names) {
		$record{$field_names[$i]} = $row->{f}[$i]{v};
            }
            push @results, \%record;
        }
        return \@results;
    }

    # Handle edge case: single object (convert to array)
    if (ref $data eq 'HASH' && !$data->{rows}) {
        return [$data];
    }

    # Unknown format
    warn "_parse_bq_result(): Unknown BigQuery result format: " . ref($data);
    return [];
}

# _run_bq_query
# executes a BigQuery SELECT and returns parsed JSON
sub _run_bq_query {
   my ($self, $sql) = @_;

    # Escape single quotes for shell0safe SQL string
    $sql =~ s/'/'\\''/g;

    # Build bq CLI command string for shell execution
    my $project  = $self->target->uri->host;
    my $location = $self->target->uri->query_param('location');

    # Build the full command as a string (shell execution)
    my $cmd = join(' ',
        $self->client,
        'query',
        '--use_legacy_sql=false',
        '--format=json',
        '--quiet',
        '--nouse_cache',
        "--project_id=$project",
        "--location=$location",
        "'$sql'"
    );

    $self->sqitch->debug("Running: $cmd");

    # Execute using shell
    my $output = `$cmd 2>&1`;
    my $exit_code = $? >> 8;

    $self->sqitch->debug("Raw Output: $output");

    if ($exit_code != 0) {
        hurl engine => "Failed to run SQL:\n$sql\n$output";
    }

    # Remove BOM if present
    $output =~ s/^\x{FEFF}//;

    # Trim whitespace
    $output =~ s/^\s+|\s+$//g;

    # Parse JSON output
    my $data;
    try {
        $data = decode_json($output);
    } catch {
        warn "_run_bq_query(): Failed to decode JSON. Raw output:\n$output\n";
        hurl engine => "Invalid JSON returned from bq.";
    };

    return $self->_parse_bq_result($data);
}

# change_id_for - Used by the rever command to find the change ID for a given tag or change name.
sub change_id_for {
    my ($self, %p) = @_;

    my $project_id = $self->target->uri->host;
    my $dataset    = $self->registry;
    my $project    = $p{project} || $self->plan->project;

    # If we have a cange_id, just return it if it exists
    if (defined $p{change_id}) {
        my $sql = qq{
            SELECT change_id FROM `$project_id.$dataset.changes`
            WHERE change_id = '$p{change_id}' AND project = '$project'
            LIMIT 1
        };
        my $result = $self->_run_bq_query($sql);
        return $result->[0]{change_id} if @$result;
    }

    # If we have atag, look it up
    if (defined $p{tag}) {
        my $sql = qq{
            SELECT change_id FROM `$project_id.$dataset.tags`
            WHERE tag = '$p{tag}' AND project = '$project'
            LIMIT 1
        };
        my $result = $self->_run_bq_query($sql);
        if (@$result) {
            return $result->[0]{change_id};
        }
    }

    # If we have a change name, look up its change_id (but not if it's empty)
    if (defined $p{change} && $p{change} ne '') {
        my $sql = qq{
            SELECT change_id FROM `$project_id.$dataset.changes`
            WHERE change = '$p{change}' AND project = '$project'
            ORDER BY committed_at DESC LIMIT 1
        };
        my $result = $self->_run_bq_query($sql);
        return $result->[0]{change_id} if @$result;
    }

    # If we get here, we couldn't find the change ID
    return undef;
}

# Return a change at a given offset from a change ID
# Offset 0 = the change itself, positive = later changes, negative = earlier changes
sub change_offset_from_id {
    my ($self, $change_id, $offset) = @_;

    my $project_id = $self->target->uri->host;
    my $dataset    = $self->registry;
    my $project    = $self->plan->project;

    # Get all changes ordered by committed_at
    my $sql = qq{
        SELECT change_id, change, committed_at
        FROM `$project_id.$dataset.changes`
        WHERE project = '$project'
        ORDER BY committed_at
    };

    my $changes = $self->_run_bq_query($sql);

    # Find the index of the target change
    my $target_idx = -1;
    for my $i (0..$#{$changes}) {
        if ($changes->[$i]{change_id} eq $change_id) {
            $target_idx = $i;
            last;
        }
    }

    return undef if $target_idx == -1;  # Change not found

    # Calculate the offset index
    my $offset_idx = $target_idx + $offset;

    # Check bounds
    return undef if $offset_idx < 0 || $offset_idx > $#{$changes};

    # Return the change at the ofset
    return $self->load_change($changes->[$offset_idx]{change_id});
}

# Returns the tag-qualified name of a change (e.g., "create_users@v1.0" or "create_users@HEAD")
sub name_for_change_id {
    my ($self, $change_id) = @_;

    my $change = $self->load_change($change_id);
    return undef unless $change;

    my $change_name = $change->name;

    # Get tags for this change
    my $project_id = $self->target->uri->host;
    my $dataset    = $self->registry;
    my $project    = $self->plan->project;

    my $sql = qq{
        SELECT tag
        FROM `$project_id.$dataset.tags`
        WHERE change_id = '$change_id' AND project = '$project'
        ORDER BY committed_at DESC
        LIMIT 1
    };

    my $result = $self->_run_bq_query($sql);

    if (@$result && $result->[0]{tag}) {
        # Return change name with tag
        return $change_name . '@' . $result->[0]{tag};
    } else {
        # Return change name with @HEAD
        return $change_name . '@HEAD';
    }
}

# Like change_offset_from_id() but returns just the change ID instead of the full object
sub change_id_offset_from_id {
    my ($self, $change_id, $offset) = @_;

    my $project_id = $self->target->uri->host;
    my $dataset    = $self->registry;
    my $project    = $self->plan->project;

    # Get all changes ordered by committed_at
    my $sql = qq{
        SELECT change_id
        FROM `$project_id.$dataset.changes`
        WHERE project = '$project'
        ORDER BY committed_at
    };

    my $changes = $self->_run_bq_query($sql);

    # Find the index of the target change
    my $target_idx = -1;
    for my $i (0..$#{$changes}) {
        if ($changes->[$i]{change_id} eq $change_id) {
            $target_idx = $i;
            last;
        }
    }

    return undef if $target_idx == -1;  # Change not found

    # Calculate the offset index
    my $offset_idx = $target_idx + $offset;

    # Check bounds
    return undef if $offset_idx < 0 || $offset_idx > $#{$changes};

    # Return just the change ID at the ofset
    return $changes->[$offset_idx]{change_id};
}

# Returns the tags associated with the current deployed change
sub current_tags {
    my ($self, $project) = @_;

    my $project_id = $self->target->uri->host;
    my $dataset    = $self->registry;
    $project       = $self->plan->project;

    # Get the most recent change
    my $state = $self->current_state;
    return [] unless $state;

    my $change_id = $state->{change_id};

    # Query tags for this change
    my $sql = qq{
        SELECT tag
        FROM `$project_id.$dataset.tags`
        WHERE change_id = '$change_id' AND project = '$project'
        ORDER BY committed_at
    };

    my $result = $self->_run_bq_query($sql);
    return [ map { $_->{tag} } @$result ];
}

# Check if a tag is deployed
sub is_deployed_tag {
    my ($self, $tag) = @_;

    my $project_id = $self->target->uri->host;
    my $dataset    = $self->registry;
    my $project    = $self->plan->project;

    my $tag_name = ref $tag ? $tag->name : $tag;

    my $sql = qq{
        SELECT COUNT(*) > 0 AS tag_exists
        FROM `$project_id.$dataset.tags`
        WHERE tag = '$tag_name' AND project = '$project'
    };

    my $result = $self->_run_bq_query($sql);
    return $result->[0]{tag_exists} eq 'true' ? 1: 0;
}

# Internal method to deploy a single tag
sub _deploy_tag {
    my ($self, $tag, $change_id) = @_;

    my $project_id = $self->target->uri->host;
    my $dataset    = $self->registry;
    my $tags_table = "`$project_id.$dataset.tags`";
    my $project    = $self->plan->project;
    my $user       = $self->sqitch->user_name;
    my $email      = $self->sqitch->user_email;

    my $tag_id        = $tag->id;
    my $tag_name      = $tag->name;
    my $note          = $tag->note;
    my $planned_at    = $tag->timestamp;
    my $planner       = $tag->planner_name;
    my $planner_email = $tag->planner_email;

    $self->sqitch->debug("Deploying tag $tag_name");

    my $sql = qq{
        INSERT INTO $tags_table (
            tag_id, tag, project, change_id, note, committed_at,
            committer_name, committer_email, planned_at, planner_name, planner_email
        ) VALUES (
            '$tag_id', '$tag_name', '$project', '$change_id', '$note', CURRENT_TIMESTAMP(),
            '$user', '$email', '$planned_at', '$planner', '$planner_email'
        )
    };

    try {
        $self->_run_bq_exec($sql);
        $self->sqitch->info("Tagged $tag_name");
    } catch {
        hurl engine => "Error deploying tag $tag_name: $_";
    };
}

# Save tags in the database when they're deployed
sub log_new_tags {
    my ($self, $change) = @_;

    # Get tags directly from the change object (like pg.pm does)
    my @tags = $change->tags or return $self;

    my $project_id = $self->target->uri->host;
    my $dataset    = $self->registry;
    my $tags_table = "`$project_id.$dataset.tags`";
    my $project    = $self->plan->project;
    my $user       = $self->sqitch->user_name;
    my $email      = $self->sqitch->user_email;

    # Build multi-row INSERT with all tags at once
    my @values;
    for my $tag (@tags) {
        my $tag_id = $tag->id;
        my $tag_name = $tag->name;
        my $change_id = $change->id;
        my $note = $tag->note;
        my $planned_at = $tag->timestamp;
        my $planner = $tag->planner_name;
        my $planner_email = $tag->planner_email;

        my ($q_name, $q_project, $q_note, $q_user, $q_email, $q_planner, $q_planner_email) =
            map { $self->_quote($_) } $tag_name, $project, $note, $user, $email, $planner, $planner_email;

        push @values, qq{('$tag_id', $q_name, $q_project, '$change_id', $q_note, CURRENT_TIMESTAMP(), $q_user, $q_email, '$planned_at', $q_planner, $q_planner_email)};
    }

    my $sql = qq{
        INSERT INTO $tags_table (
            tag_id, tag, project, change_id, note, committed_at,
            committer_name, committer_email, planned_at, planner_name, planner_email
        )
        SELECT * FROM UNNEST([
            STRUCT<tag_id STRING, tag STRING, project STRING, change_id STRING, note STRING,
                    committed_at TIMESTAMP, committer_name STRING, committer_email STRING,
                    planned_at TIMESTAMP, planner_name STRING, planner_email STRING>
    } . join(",", @values) . qq{
        ]) AS new_tag
        WHERE NOT EXISTS (
            SELECT 1 FROM $tags_table t
            WHERE t.tag_id = new_tag.tag_id AND t.project = '$project'
        )
    };

    try {
        $self->_run_bq_exec($sql);
    } catch {
        hurl engine => "Error adding tags: $_";
    };

    return $self;
}

sub _update_script_hashes {
    my $self = shift;
    my $plan = $self->plan;
    my $proj = $plan->project;

    my $project_id = $self->target->uri->host;
    my $dataset    = $self->registry;
    my $changes_table = "`$project_id.$dataset.changes`";

    # Update script hashes for all changes in the plan
    # This is called when upgrading from old registry format where
    # script_hash was stored as change_id (legacy from v0.998)
    for my $change ($plan->changes) {
        my $change_id = $change->id;
        my $script_hash = $change->script_hash;

        # Update hash if it's currently set to changed_id (old format)
        my $sql = qq{
            UPDATE $changes_table
            SET script_hash = '$script_hash'
            WHERE change_id = '$change_id' AND script_hash = '$change_id'
        };

        $self->_run_bq_exec($sql);
    }

    # Set script_hash to NULL for any remaining changes where hash equals change_id
    my $sql = qq{
        UPDATE $changes_table
        SET script_hash = NULL
        WHERE project = '$proj' AND script_hash = change_id
    };

    $self->_run_bq_exec($sql);

    return $self;
}

# _log_tags_param
# Returns an array reference of tag names for a change
sub _log_tags_param {
    my ($self, $change) = @_;
    return [ map { $_->format_name } $change->tags ];
}

# _log_requires_param
# Returns an array reference of required change names
sub _log_requires_param {
    my ($self, $change) = @_;
    return [ map { $_->as_string } $change->requires ];    
}

# _log_conflicts_param
# Returns an array reference of conflicting change names
sub _log_conflicts_param {
    my ($self, $change) = @_;
    return [ map { $_->as_string } $change->conflicts ];
}

# _array_to_sql
# Converts a Perl array reference to BigQuery array literal syntax
sub _array_to_sql {
    my ($self, $array_ref) = @_;
    return '[]' unless $array_ref && @$array_ref;

    # Escape single quotes in array elements
    my @escaped = map { $self->_quote($_) } @$array_ref;

    return '[' . join(', ', @escaped) . ']';
}

sub _quote {
    my ($self, $value) = @_;
    return 'NULL' unless defined $value;
    $value =~ s/\\/\\\\/g;
    $value =~ s/'/\\'/g;
    $value =~ s/\n/\\n/g;
    return "'$value'";
}

# _log_event
# Core event logger - inserts an event record into the events table
# This provides a complete audit trail of all deployment activities
sub _log_event {
    my ($self, $event, $change, $tags, $requires, $conflicts) = @_;

    my $project_id = $self->target->uri->host;
    my $dataset    = $self->registry;
    my $sqitch     = $self->sqitch;

    # Format arrays for BigQuery
    my $tags_array = $tags || $self->_log_tags_param($change);
    my $req_array  = $requires || $self->_log_requires_param($change);
    my $conf_array = $conflicts || $self->_log_conflicts_param($change);

    # Convert arrays to BigQuery array literals
    my $tags_sql = $self->_array_to_sql($tags_array);
    my $req_sql  = $self->_array_to_sql($req_array);
    my $conf_sql = $self->_array_to_sql($conf_array);

    # Escape single quotes in text fields
    my $change_id      = $change->id;
    my $change_name    = $change->name;
    my $project        = $change->project;
    my $note           = $change->note;
    my $committer_name = $sqitch->user_name;
    my $committer_email= $sqitch->user_email;
    my $planner_name   = $change->planner_name;
    my $planner_email  = $change->planner_email;

    # Escape quotes in all string fields
    $_ = $self->_quote($_) for $change_name, $project, $note, $committer_name, $committer_email, $planner_name, $planner_email;

    # Escape quotes for BigQuery - remove timezone offset
    # BigQuery TIMESTAMP() expects: 'YYYY-MM-DD HH:MM:SS' (no timezone)
    my $planned_at_str = $change->timestamp->as_string(format => 'iso');
    $planned_at_str =~ s/\s+[+-]\d{4}$//;  # Remove timezone offset like ' +0000'

    my $sql = qq{
        INSERT INTO `$project_id.$dataset.events` (
            event, change_id, change, project, note,
            requires, conflicts, tags,
            committed_at, committer_name, committer_email,
            planned_at, planner_name, planner_email
        ) VALUES (
            '$event', '$change_id', $change_name, $project, $note,
            $req_sql, $conf_sql, $tags_sql,
            CURRENT_TIMESTAMP(), $committer_name, $committer_email,
            TIMESTAMP('$planned_at_str'), $planner_name, $planner_email
            )
        };

    $self->_run_bq_exec($sql);
    return $self;
}

# _run_bq_exec
# Executes a BigQuery DDL statement that returns no output.
sub _run_bq_exec {
    my ($self, $sql) = @_;

    # Escape single quotes for shell-safe SQL string
    $sql =~ s/'/'\\''/g;

    # Build bq CLI command string (shell execution)
    my $project  = $self->target->uri->host;
    my $location = $self->target->uri->query_param('location');

    # Build the full command as string (shell execution)
    my $cmd = join(' ',
        $self->client,
        'query',
        '--use_legacy_sql=false',
        '--quiet',
        '--nouse_cache',
        "--project_id=$project",
        "--location=$location",
        "'$sql'"
    );

    $self->sqitch->debug("Running: $cmd");

    # Execute using shell
    my $output = `$cmd 2>&1`;
    my $exit_code = $? >> 8;

    $self->sqitch->debug("Raw Output: $output");

    if ($exit_code != 0) {
        hurl engine => "Failed to run SQL:\n$sql\n$output";
    }

    return 1;
}


1;

__END__

=head1 Name

App::Sqitch::Engine::bigquery - Sqitch Google BigQuery Engine

=head1 Synopsis

   my $bigquery = App::Sqitch::Engine->load( engine => 'bigquery' );

=head1 Description

App::Sqitch::Engine::bigquery provides the Google BigQuery storage engine for
Sqitch. It uses the C<bq> command-line tool to manage database schema changes
in BigQuery datasets.

=head1 Interface

=head2 Instance Methods

=head3 C<initialized>

  $bigquery->initialize unless $bigquery->initialized;

Returns true if the BigQuery dataset has been initialized for Sqitch (i.e., the
registry tables exist), and false if it has not.

=head3 C<initialize>

  $bigquery->initialize;

Initializes a BigQuery dataset for Sqitch by creating the registry schema and
tables. The registry includes tables for tracking changes, tags, dependencies,
events, projects, and releases.

=head2 Target URI format

The BigQuery engine requires a specific URI format:

  db:bigquery://PROJECT_ID/DATASET?location=LOCATION

Where:

=over

=item * C<PROJECT_ID> - Your Google Cloud project ID (required)

=item * C<DATASET> - The BigQuery dataset for your application objects. It is
available to change scripts as C<:dataset>, and it is not the Sqitch registry.

=item * C<location> - The BigQuery location/Region (required query parameter)

=back

Example:

  sqitch init myproject --engine bigquery \
    --target db:bigquery://my-gcp-project/my_app?location=us-central1

=head2 Registry Schema

The registry lives in its own dataset, named by the C<registry> setting. It
defaults to C<sqitch> and is created on the first deploy, in the location given
in the target URI. To use another name:

  sqitch config engine.bigquery.registry my_registry

The BigQuery registry consists of the following tables:

=over

=item * C<releases> - Tracks Sqitch registry versions

=item * C<projects> - Tracks Sqitch projects

=item * C<changes> - Records deployed changes

=item * C<tags> - Records tags applied to changes

=item * C<dependencies> - Tracks change dependencies

=item * C<events> - Logs deployment events

=back

=head2 Authentication

The BigQuery engine relies on C<bq> command-line tool for authentication.
Ensure you are authenticated before using Sqitch:

  gcloud auth login
  gcloud config set project YOUR_PROJECT_ID

Alternatively, use a service account:

  export GOOGLE_APPLICATION_CREDENTIALS=/path/to/service-account-key.json

=head2 Permissions

The service account or user must have the following BigQuery permissions:

=over

=item * C<bigquery.dataset.create> - To create the registry dataset

=item * C<bigquery.dataset.get> - To check if dataset exists

=item * C<bigquery.tables.create> - To create registry tables

=item * C<bigquery.tables.get> - To query table metadata

=item * C<bigquery.tables.getData> - To read from registry tables

=item * C<bigquery.tables.updateData> - To insert/update/delete registry data

=item * C<bigquery.jobs.create> - To execute queries

=back

=head2 Optimizations

The BigQuery engine includes several optimizations to reduce API calls:

=over

=item * C<current_state()> - Uses a single query with LEFT JOIN to fetch the
latest change and its tags together

=item * C<log_new_tags()> - Uses multi-row INSERT with UNNEST to add all tags
in a single query instead of one query per tag

=item * C<deployed_changes()> - Uses STRING_AGG to aggregate tags in a single
query

=back

=head2 Limitations

=over

=item * BigQuery does not support transactions, so C<begin_work>, C<finish_work>,
and C<rollback_work> are no-ops

=item * The C<bq> CLI does not support variable substitution like PostgreSQL's
C<psql>, so the engine replaces C<:registry> in the registry script, and
C<:project_id>, C<:dataset> and any variables you set in change scripts, by
itself

=item * Each script is passed to C<bq query> as a command-line argument, which
limits the size of a single script

=item * Because there are no transactions, a deploy that fails partway can leave
a change registered even though it did not finish. Check the registry with
C<sqitch status> and revert the change if needed

=item * Every statement runs as a separate C<bq> call, so deploys are slower
than on engines that keep a database connection open

=back

=head1 Example Usage

Initialize a new Sqitch project for BigQuery:

  sqitch init myapp --engine bigquery \
    --target db:bigquery://my-project/my_app?location=us-central1

Add a change:

  sqitch add create_users -n "Create users table"

Deploy changes:

  sqitch deploy

Check status:

  sqitch status

Revert changes:

  sqitch revert

Tag a release:

  sqitch tag v1.0 -n "First release"

=head1 See Also

=over

=item * L<sqitch> - Sqitch command-line client

=item * L<sqitch-target> - Manage target databases

=item * L<sqitch-deploy> - Deploy changes to a database

=item * L<sqitch-revert> - Revert changes from a database

=item * L<sqitch-verify> - Verify changes in a database

=item * L<sqitch::App::Sqitch::Engine> - Sqitch engine base class

=item * L<https://cloud.google.com/bigquery/docs> - BigQuery documentation

=back

=head1 Author

Ricardo Maurino
Based on the Sqitch engine framework by David E. Wheeler.

=head1 License

Copyright (c) 2012-2025 David E. Wheeler, 2012-2021 iovation Inc.
Copyright (c) 2026 Ricardo Maurino

Permission is hereby granted, free of charge, to any person obtaining a copy 
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

=cut
