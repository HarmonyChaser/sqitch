#!/usr/bin/perl -w
# To test against a live BigQuery dataset, provide the URI in the
# SQITCH_TEST_BQ_URI environment variable. This is a standard URI::db URI:
#
#     export SQITCH_TEST_BQ_URI=db:bigquery://your-project-id/sqitch_test?location=us-central1
#
# Sqitch will connect to this dataset and create tables to run the tests,
# and will drop them when the tests complete.
# Test Plan:
# 1. Module loading - Verify BQEEngineTest helper module loads
# 2. Class Loading - Verify App::Sqitch::Engine::bigquery class loads
# 3. Config Vars - Test config_vars() returns expected configuration variables
# 4. Engine Instantiation - Create BigQuery engine instance
# 5. Key property - Test key() returns 'bigquery'
# 6. Name Property - Test name() returns 'Google BigQuery'
# 7. Client Property - Test client() returns 'bq' (or bq.exe on Windows)
# 8. Registry Property - Test registry() returns 'sqitch' as default
# 9. URI Property - Test uri() returns the target URI
# 10.-11. Destination property - Test destination() and registry_destination() return URI string (2 tests)
# 12. bq() command - Test bq() method returns correct command array
# 13. _client_opts - Engine instantiation - Create engine with test URI
# 14. _client_opts - Test _client_opts returns standard BigQuery options
# 15. can_ok - Verify _run() and _capture() methods exist
# 16-17. _run method - Test _capture() calls sqitch->capture() with correct arguments (2 tests)
# 18-19. _capture method() - Test _capture() calls sqitch->capture() with current arguments (2 tests)
# 20. Registry Initialization - Test _initialized() detects registry state before/after initialization (subtest)

use strict;
use warnings;
use Test::More;
use lib 't/lib';
use App::Sqitch;
use App::Sqitch::Target;
use URI;
use URI::db;
use TestConfig;

# Cleanup function - runs at the end of test
END {
    if ($ENV{SQITCH_TEST_BQ_URI}) {
        my $uri = URI->new($ENV{SQITCH_TEST_BQ_URI});
        my $project = $uri->host;
        my $dataset = $uri->dbname;
        my $exit_code = system("bq rm -r -f -d $project:$dataset");
        if ($exit_code != 0) {
            warn "Failed to cleanup BigQuery dataset $project:$dataset (exit code: $exit_code)\n";
        }
    }
}

# Test 1: Ensure our test helper module can be loaded.
use_ok 'BQEEngineTest';

# Test 2: Load the BigQuery engine class.
my $CLASS = 'App::Sqitch::Engine::bigquery';
require_ok $CLASS;

# Test 3: Test config_vars.
is_deeply [$CLASS->config_vars], [
    target   => 'any',
    registry => 'any',
    client   => 'any',
], 'config_vars should return these vars';

# Test 4: Instantiate engine.
my $uri = URI::db->new('db:bigquery:');
my $config = TestConfig->new('core.engine' =>'bigquery');
my $sqitch = App::Sqitch->new(config => $config);
my $target = App::Sqitch::Target->new(
    sqitch => $sqitch,
    uri    => $uri,
);
isa_ok my $bq = $CLASS->new(sqitch => $sqitch, target => $target), $CLASS;

# Test 5: Test key property.
is $bq->key, 'bigquery', 'Key should be "bigquery"';

# Test 6: Test name property.
is $bq->name, 'Google BigQuery', 'Name should be "Google BigQuery"';

# Test 7: Test client property.
my $client = 'bq' . (App::Sqitch::ISWIN ? '.exe' : '');
is $bq->client, $client, 'client should default to bq';

# Test 8: Test registry property.
is $bq->registry, 'sqitch', 'registry default should be "sqitch"';

# Test 9: Test uri property.
is $bq->uri, $uri, 'DB URI should be "db:bigquery:';

# Test 10-11: Test destination property.
is $bq->destination, $uri->as_string, 'Destination should be the URI string';
is $bq->registry_destination, $bq->destination,
    'Registry destination should be the same as destination';

# Test 12: Test bq() command.
is_deeply [$bq->bq], [$client],
    'bq command should return just the client';

# Test 13: Test set_variables.
ok $bq->set_variables(foo =>'baz', whu => 'hi there', yo => 'stellar'),
    'Set some variables';
# Note: Unlike PostgreSQL which passes variables via --set flags to psql,
# BigQuery substitutes variables directly in SQL files via _run_file
is_deeply [$bq->bq], [$client],
    'bq command should not include variables (they are substituted in SQL)';

# Test 13-14: Test _client_opts() with a test URI (no actual connection)
my $test_uri = URI::db->new('db:bigquery://test-project/test-dataset?location=test-location');
my $test_target = App::Sqitch::Target->new(
    sqitch => $sqitch,
    uri    => $test_uri,
);
isa_ok my $bq_with_uri = $CLASS->new(sqitch => $sqitch, target => $test_target), $CLASS;

my @expected_opts = (
    '--use_legacy_sql=false',
    '--format=json',
    '--quiet',
    '--nouse_cache',
    '--project_id=test-project',
    '--location=test-location',
);
is_deeply [$bq_with_uri->_client_opts], \@expected_opts,
    '_client_opts should return standard BigQuery options';

####################################################################
# Test 15-18: Test _run() and _capture() methods (mimics pg.t)
can_ok $CLASS, qw(_run _capture);

# Mock sqitch->run() to test _run() calls it correctly
use Test::MockModule;
my $mock_sqitch = Test::MockModule->new('App::Sqitch');
my @run_args;
$mock_sqitch->mock(run => sub {
    shift;  # Remove itself
    @run_args = @_;
});

# Test _run() with subcommand
ok $bq_with_uri->_run('query', '--some-arg', 'value'), 'Call _run with subcommand';
is_deeply \@run_args, [
    $bq_with_uri->bq,
    'query',
    $bq_with_uri->_client_opts,
    '--some-arg',
    'value'
], '_run should pass bq, subcommand, client_opts, and additional args to run()';

# Mock sqitch->capture() to test _capture() calls it correctly
my @capture_args;
$mock_sqitch->mock(capture => sub {
    shift;  # Remove itself
    @capture_args = @_;
});

# Test _capture() with subcommand
ok $bq_with_uri->_capture('query', '--another-arg', 'data'), 'Call _capture with subcommand';
is_deeply \@capture_args, [
    $bq_with_uri->bq,
    'query',
    $bq_with_uri->_client_opts,
    '--another-arg',
    'data',
], '_capture should pass bq, subcommand, client_opts, and additional args to capture()';

$mock_sqitch->unmock_all;

###############################################################################
# Test 20: Test file running (_run_file)
use File::Temp qw(tempfile);
use Path::Class qw(file);

# Create a temporary SQL file
my ($fh, $filename) = tempfile(SUFFIX => '.sql', UNLINK => 1);
print $fh "-- Test SQL file\n";
print $fh "SELECT 1 AS test;\n";
close $fh;

# Mock _run_bq_exec to capture what SQL is executed
my $executed_sql;
my $mock_bq = Test::MockModule->new($CLASS);
$mock_bq->mock(_run_bq_exec => sub {
    shift;  # Remove itself
    $executed_sql = shift;
});

# Test _run_file
ok $bq_with_uri->_run_file(file($filename)), 'Run SQL file';
like $executed_sql, qr/SELECT 1 AS test/, 'SQL from file should be executed';

# Test variable substitution
($fh, $filename) = tempfile(SUFFIX => '.sql', UNLINK => 1);
print $fh "-- Test with variable\n";
print $fh "SELECT ':project_id' AS project, ':dataset' AS dataset;\n";
close $fh;

ok $bq_with_uri->_run_file(file($filename)), 'Run SQL file with variables';
like $executed_sql, qr/SELECT 'test-project' AS project/, 'project_id variable should be substituted';
like $executed_sql, qr/'test-dataset' AS dataset/, 'dataset variable should be substituted';

$mock_bq->unmock_all;

###################################################################
# Test 25: Test DateTime formatting (_parse_timestamp)
ok my $parse_ts = $CLASS->can('_parse_timestamp'), "$CLASS->can('_parse_timestamp')";

# Test valid timestamp parsing
isa_ok my $dt = $bq->_parse_timestamp('2025-12-21 15:30:45'),
    'App::Sqitch::DateTime', 'Return value of _parse_timestamp()';
is $dt->year, 2025, 'DateTime year should be set';
is $dt->month, 12, 'DateTime month should be set';
is $dt->day, 21, 'DateTime day should be set';
is $dt->hour, 15, 'DateTime hour should be set';
is $dt->minute, 30, 'DateTime minute should be set';
is $dt->second, 45, 'DateTime second should be set';
is $dt->time_zone->name, 'UTC', 'DateTime TZ should be UTC';

# Test with different timestamp
ok $dt = $bq->_parse_timestamp('2024-01-01 00:00:00');
is $dt->year, 2024, 'DateTime year should be 2024';
is $dt->month, 1, 'DateTime month should be 1';
is $dt->day, 1, 'DateTime day should be 1';
is $dt->hour, 0, 'DateTime hour should be 0';
is $dt->minute, 0, 'DateTime minute should be 0';
is $dt->second, 0, 'DateTime second should be 0';

# Test with undef
is $bq->_parse_timestamp(undef), undef, '_parse_timestamp(undef) should return undef';

###################################################################
# Test 41: Test BigQuery SQL helpers
# Test _array_to_sql
ok my $array_to_sql = $CLASS->can('_array_to_sql'), "$CLASS->can('_array_to_sql')";
is $bq->_array_to_sql([]), '[]', 'Empty array should return []';
is $bq->_array_to_sql(['foo']), "['foo']", 'Single element array';
is $bq->_array_to_sql(['foo', 'bar']), "['foo', 'bar']", 'Two element array';
is $bq->_array_to_sql(["it's", 'test']), "['it\\'s', 'test']", 'Should escape single quotes';

# Test _parse_bq_result
ok my $parse_result = $CLASS->can('_parse_bq_result'), "$CLASS->can('_parse_bq_result')";

# Test with array format (new format)
my $array_data = [
    { id => 1, name => 'foo' },
    { id => 2, name => 'bar' },
];
is_deeply $bq->_parse_bq_result($array_data), $array_data,
    '_parse_bq_result should return array data as-is';

# Test with old format (rows/schema)
my $old_format = {
    schema => {
        fields => [
            { name => 'id' },
            { name => 'name' },
        ],
    },
    rows => [
        { f => [ { v => 1 }, { v => 'foo' } ] },
        { f => [ { v => 2 }, { v => 'bar' } ] },
    ],
};
my $expected = [
    { id => 1, name => 'foo' },
    { id => 2, name => 'bar' },
];
is_deeply $bq->_parse_bq_result($old_format), $expected,
    '_parse_bq_result should convert old format to array';

# Test with undef
is_deeply $bq->_parse_bq_result(undef), [], '_parse_bq_result(undef) should return []';

##############################################################################
# Test 50: Test _run_registry_file
RUNREG: {
    # Mock _run_bq_exec to capture executed SQL
    my @executed_sql;
    my $mock_engine = Test::MockModule->new($CLASS);
    $mock_engine->mock(_run_bq_exec => sub {
        shift;
        push @executed_sql, shift;
    });

    # Find the BigQuery registry SQL file
    my $ddl = file($INC{'App/Sqitch/Engine/bigquery.pm'})->dir->file('bigquery.sql');
    ok -e $ddl, 'bigquery.sql should exist';

    # Test _run_registry_file
    ok $bq_with_uri->_run_registry_file($ddl), '_run_registry_file should succeed';

    # Verify SQL statements were executed
    ok @executed_sql > 0, 'Should have executed SQL statements';

    # Check that registry placeholder was replaced
    my $all_sql = join("\n", @executed_sql);
    unlike $all_sql, qr/:registry/, 'Should not contain :registry placeholder';
    like $all_sql, qr/sqitch/, 'Should contain the default registry dataset name';

    # Check for expected table creations
    like $all_sql, qr/CREATE TABLE.*releases*/i, 'Should create releases table';
    like $all_sql, qr/CREATE TABLE.*projects*/i, 'Should create projects table';
    like $all_sql, qr/CREATE TABLE.*changes*/i, 'Should create changes table';
    like $all_sql, qr/CREATE TABLE.*tags*/i, 'Should create tags table';
    like $all_sql, qr/CREATE TABLE.*dependencies*/i, 'Should create dependencies table';
    like $all_sql, qr/CREATE TABLE.*events*/i, 'Should create events table';

    $mock_engine->unmock_all;
}

################################################################################
# Test 61: Test config settings override defaults
CONFIG: {
    my $config2 = TestConfig->new(
        'core.engine'       => 'bigquery',
        'engine.bigquery.client'   => '/custom/path/to/bq',
        'engine.bigquery.target'   => 'db:bigquery://custom-project/custom-dataset?location=custom-location',
        'engine.bigquery.registry' => 'custom_registry',
    );
    my $sqitch2 = App::Sqitch->new(config => $config2);
    my $target2 = App::Sqitch::Target->new(sqitch => $sqitch2);
    ok my $bq2 = $CLASS->new(sqitch => $sqitch2, target => $target2),
        'Create bigquery with config';

    is $bq2->client, '/custom/path/to/bq', 'client should be as configured';
    is $bq2->uri->as_string, 'db:bigquery://custom-project/custom-dataset?location=custom-location',
        'uri should be configured';
    is $bq2->registry, 'custom_registry', 'registry should be as configured';
    is_deeply [$bq2->bq], ['/custom/path/to/bq'],
        'bq command should use configured client';

    my @custom_opts = $bq2->_client_opts;
    is $custom_opts[4], '--project_id=custom-project', 'Should use configured project';
    is $custom_opts[5], '--location=custom-location', 'Should use configured location';
}

##############################################################################
# Test 62: Test _initialized() method
subtest '_initialized method' => sub {
    plan skip_all => 'Set SQITCH_TEST_BQ_URI to enable BigQuery tests'
        unless $ENV{SQITCH_TEST_BQ_URI};

    # Cleanup any leftover from previous test runs
    my $uri = URI->new($ENV{SQITCH_TEST_BQ_URI});
    my $project = $uri->host;
    my $dataset = $uri->dbname;
    system("bq rm -r -f -d $project:$dataset 2>/dev/null");

    plan tests => 2;

    my $sqitch = App::Sqitch->new;
    my $target = App::Sqitch::Target->new(
            sqitch => $sqitch,
            uri    => $uri,
    );
    my $engine = $CLASS->new(
        target => $target,
        sqitch => $sqitch,
    );

    # Test 3a: Should return 0 if registry doesn't exist
    my $initialized = $engine->_initialized;
    ok(!$initialized, '_initialized returns false when registry does not exist');

    # Test 3b: After initialization, should return 1
    $engine->initialize;
    $initialized = $engine->_initialized;
    ok($initialized, '_initialized returns true after initialization');
};

done_testing;
