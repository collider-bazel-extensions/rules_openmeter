# rules_openmeter

[OpenMeter](https://github.com/openmeterio/openmeter) (usage metering:
CloudEvents ingest, meters, per-subject queries) as a **per-test instance**
for Bazel, so a service that sends usage events and reads meter values can
be tested against the real thing: the OpenMeter API server and its sink
worker, on Kafka, ClickHouse and Postgres, all on free 127.0.0.1 ports, all
under the test's `$TEST_TMPDIR`, all offline.

```python
load("@rules_openmeter//:defs.bzl", "openmeter_test")

openmeter_test(
    name = "usage_test",
    srcs = ["usage_test.sh"],
    meters = "meters.yaml",          # OpenMeter's `meters:` list
    tags = ["block-network"],        # loopback only; the whole stack runs offline
)
```

```bash
#!/usr/bin/env bash
set -euo pipefail
source "$OPENMETER_TESTLIB"
om_ingest --type prompt --subject alice --data '{"tokens": 5, "model": "gpt"}'
om_ingest --type prompt --subject alice --data '{"tokens": 7, "model": "gpt"}'
om_wait_value 12 tokens_total --subject alice        # waits for the sink to flush
[[ "$(om_query prompts --subject alice)" == 2 ]]
curl -s "$OPENMETER_URL/api/v1/meters/tokens_total/query?windowSize=HOUR"   # any client
```

- **Pinned:** OpenMeter `v1.0.0-beta.237` (the latest release), the
  `openmeter` (API server) and `openmeter-sink-worker` binaries, extracted
  from the digest-pinned image `ghcr.io/openmeterio/openmeter` (no Docker,
  no rules_oci; see [Where the binaries come from](#where-the-binaries-come-from)).
- **Backing services** from this org's rules: Kafka 4.4.0
  ([rules_kafka](https://github.com/collider-bazel-extensions/rules_kafka)
  0.2.0), ClickHouse 26.10.6.18
  ([rules_clickhouse](https://github.com/collider-bazel-extensions/rules_clickhouse)
  0.1.0), PostgreSQL 16
  ([rules_pg](https://github.com/collider-bazel-extensions/rules_pg) 0.6.1).
  No Redis/Valkey: OpenMeter doesn't need it in metering-only mode
  ([why](#metering-only-mode)).
- **Platforms:** Linux x86\_64 (tested, CI). Linux arm64 is pinned (the image
  has it) but not tested. No macOS: upstream builds Linux binaries only.
  Needs `python3` on the host (the launchers and helpers, as in the
  sibling rules).

### OpenMeter's version numbers

Every OpenMeter release since `v0.2.0` has been a `v1.0.0-beta.<n>` tag
(237 of them at the time of writing, a new one frequently). "beta" is upstream's naming,
not a pre-release of something else: there is no stable 1.0.0 to prefer.
The API used here (`/api/v1/events`, `/api/v1/meters`, the config file's
`meters:` and `sink:` keys) has been stable across recent betas, but
upstream makes no compatibility promise between betas, so this package pins
one exact tag, and `openmeter.version()` takes others with their own pins.

---

## Contents

- [Installation](#installation)
- [`openmeter_test`](#openmeter_test) and the [shell helpers](#shell-helpers)
- [Environment](#environment) (the `OPENMETER_*` variables)
- [`openmeter_server`](#openmeter_server) and [rules_itest](#rules_itest)
- [`openmeter_stack`](#openmeter_stack)
- [Meters](#meters)
- [Sink flush interval and latency](#sink-flush-interval-and-latency)
- [Metering-only mode](#metering-only-mode) (the config OpenMeter runs with)
- [Isolation and the network](#isolation-and-the-network)
- [Where the binaries come from](#where-the-binaries-come-from)
- [Versions](#versions)
- [License](#license)

---

## Installation

Bzlmod only. None of these modules is in the BCR, and `archive_override` /
`git_override` apply only in the root module, so a consumer repeats every
override below (rules_openmeter's own `MODULE.bazel` has the same ones, but
Bazel ignores them when rules_openmeter isn't the root):

```python
bazel_dep(name = "rules_openmeter", version = "0.1.0")
archive_override(
    module_name = "rules_openmeter",
    urls = ["https://github.com/collider-bazel-extensions/rules_openmeter/archive/refs/tags/v0.1.0.tar.gz"],
    strip_prefix = "rules_openmeter-0.1.0",
    integrity = "INTEGRITY_AFTER_TAG",
)

# The backing services' rules (public dependencies of rules_openmeter).
bazel_dep(name = "rules_kafka", version = "0.2.0")
archive_override(
    module_name = "rules_kafka",
    integrity = "sha256-aOwLzVL5C/TyxLSwrcotsmqxHCBXY+B+KlMU3mWT88o=",
    strip_prefix = "rules_kafka-0.2.0",
    urls = ["https://github.com/collider-bazel-extensions/rules_kafka/archive/refs/tags/v0.2.0.tar.gz"],
)

# rules_kafka depends on rules_kubectl (not in the BCR either).
bazel_dep(name = "rules_kubectl", version = "0.1.0")
git_override(
    module_name = "rules_kubectl",
    commit = "bb75b97850b08a18abcdca7af86514561a122b03",  # v0.1.0
    remote = "https://github.com/collider-bazel-extensions/rules_kubectl",
)

bazel_dep(name = "rules_clickhouse", version = "0.1.0")
archive_override(
    module_name = "rules_clickhouse",
    integrity = "sha256-fmKpkGUOsR0yAaa1Ah+6E8o8Rj+q5653muRQGxwCbqM=",
    strip_prefix = "rules_clickhouse-0.1.0",
    urls = ["https://github.com/collider-bazel-extensions/rules_clickhouse/archive/refs/tags/v0.1.0.tar.gz"],
)

bazel_dep(name = "rules_pg", version = "0.6.1")
archive_override(
    module_name = "rules_pg",
    integrity = "sha256-ODOOXdoCW2uxmoK1QTES5A/vYx8ATvgAMXWHVozreWU=",
    strip_prefix = "rules_pg-0.6.1",
    urls = ["https://github.com/collider-bazel-extensions/rules_pg/archive/refs/tags/v0.6.1.tar.gz"],
)
```

That is all the wiring: rules_openmeter's `MODULE.bazel` pins OpenMeter
`1.0.0-beta.237` as the hub `@openmeter`, which the rules use by default;
no `use_extension` is needed. If your root already depends on
rules_kubectl at another version (rules_valkey uses 0.2.0), keep one
`bazel_dep` + override for it; Bazel takes the highest version.

The release archive (the tag tarball) leaves out `tests/` and `tools/`, whose
packages load dev-only modules, so `bazel query @rules_openmeter//...` works
for consumers. `.github/consumer/check.sh` checks all of this from `git
archive HEAD`, in CI.

---

## `openmeter_test`

```python
openmeter_test(
    name = "usage_test",
    srcs = ["usage_test.sh"],
    meters = "meters.yaml",             # optional; checked at build time
    namespace = "default",              # OPENMETER_NAMESPACE; topic om_<namespace>_events
    sink_flush_interval = "250ms",      # sink.maxCommitWait (upstream default 2s)
    sink_min_commit_count = 500,        # sink.minCommitCount (upstream default)
    log_level = "info",                 # OpenMeter's; debug for the sink's per-event logs
    ready_timeout = 180,                # seconds, for OpenMeter once its services are up
    kafka_heap = "512m",                # the broker's -Xmx
    tags = ["block-network"],
)
```

`data`, `deps`, `args`, `env`, `size` (default `"large"`), `timeout` and other
`sh_test` attributes are forwarded. Each target gets its own
[`openmeter_stack`](#openmeter_stack) (Kafka, ClickHouse, Postgres,
OpenMeter), so tests are safe under `--jobs=N` and sharding. The trampoline
starts the stack, sources its env file, runs the test (not `exec`: it stops
the stack when the test ends, and stops the test if any server dies under
it), and propagates the test's exit status.

### Shell helpers

`source "$OPENMETER_TESTLIB"` (stdlib Python over `$OPENMETER_URL`; set
`OPENMETER_URL` per call for another instance):

| Helper | Does |
|---|---|
| `om_ingest JSON` / `om_ingest -` | POST a CloudEvent (a JSON object, `application/cloudevents+json`) or a batch (a JSON array, `application/cloudevents-batch+json`) to `/api/v1/events`; stdin with `-` or no argument |
| `om_ingest --type T --subject S [--id ID] [--time RFC3339] [--source SRC] [--data JSON]` | build the CloudEvent: `specversion` 1.0, a random `id`, `source` `rules_openmeter` |
| `om_ingest --status ...` | print the HTTP status instead of failing on a non-2xx (for rejection tests) |
| `om_query METER [--subject S]... [--from T] [--to T] [--window-size MINUTE\|HOUR\|DAY\|MONTH] [--window-time-zone TZ] [--group-by KEY]... [--filter-group-by K=V]...` | `GET /api/v1/meters/METER/query`; prints one value per row, rows sorted by window, subject and group. `--tsv`: `windowStart windowEnd subject groupBy value`; `--json`: the raw response |
| `om_wait_value EXPECTED METER [om_query options...]` | poll `om_query` until it prints `EXPECTED` (`$OM_WAIT_TIMEOUT` s, default 60); reports how long it took. On a timeout it prints the WARN/ERROR records from OpenMeter's logs |
| `om_api METHOD PATH [BODY\|-] [CONTENT_TYPE]` | any API call; prints the body; fails unless 2xx |
| `om_status METHOD PATH [BODY\|-] [CONTENT_TYPE]` | the same, printing only the status code |

Values print as JSON numbers do, integers without a decimal point (`12`,
`2.5`). Without `--window-size` a query returns one row per group (or none
when nothing matched, which prints nothing).

---

## Environment

The env file (`$TEST_TMPDIR/<name>.env`, sourced by `openmeter_test`; `set
-a; source` it yourself elsewhere). These names are stable:

| Variable | Value |
|---|---|
| `OPENMETER_URL` | `http://127.0.0.1:<port>`: the API |
| `OPENMETER_INGEST_URL` | `$OPENMETER_URL/api/v1/events` |
| `OPENMETER_NAMESPACE` | the default namespace (`default`) |
| `OPENMETER_HOST`, `OPENMETER_PORT` | `127.0.0.1`, the API port |
| `OPENMETER_EVENTS_TOPIC` | `om_<namespace>_events`, the Kafka topic events go through |
| `OPENMETER_VERSION` | e.g. `1.0.0-beta.237` |
| `OPENMETER_SINK_FLUSH_INTERVAL`, `OPENMETER_SINK_MIN_COMMIT_COUNT` | the sink settings it runs with |
| `OPENMETER_TELEMETRY_URL`, `OPENMETER_SINK_TELEMETRY_URL` | the API server's and the sink worker's health endpoints (`/healthz`, `/healthz/ready`) |
| `OPENMETER_SERVER_PID`, `OPENMETER_SINK_PID` | the two processes |
| `OPENMETER_STATE_DIR` | `$TEST_TMPDIR/<name>`: `config.yaml`, `server.log`, `sink-worker.log`, `tmp/` |
| `OPENMETER_CONFIG` | the generated `config.yaml` |
| `OPENMETER_SERVER_LOG`, `OPENMETER_SINK_LOG` | OpenMeter's JSON logs |
| `OPENMETER_BIN`, `OPENMETER_SINK_WORKER_BIN` | the binaries |
| `OPENMETER_KAFKA_ENV`, `OPENMETER_CLICKHOUSE_ENV`, `OPENMETER_POSTGRES_ENV` | the backing services' env files (`KAFKA_*`, `CLICKHOUSE_*`, `PG*`); source one to reach Kafka, ClickHouse or Postgres directly |
| `OPENMETER_TESTLIB` | the shell helpers (`openmeter_test` only) |

---

## `openmeter_server`

OpenMeter on its own, against a `kafka_server`, a `clickhouse_server` and a
`pg_server` you declare. It waits for their env files
(`$TEST_TMPDIR/<their name>.env`), writes `config.yaml` into
`$TEST_TMPDIR/<name>/`, starts the API server, waits for `GET
/api/v1/meters` to answer 200, starts the sink worker, waits until it is
assigned the namespace's events topic (and `/healthz/ready`), then writes
`$TEST_TMPDIR/<name>.env` and runs until SIGTERM (OpenMeter stops cleanly,
the env file is removed, exit 0). If a backing env file doesn't appear,
OpenMeter rejects its config, exits, or isn't ready within `ready_timeout`,
it exits 1 with the errors from OpenMeter's log (`configuration error:`
lines, ERROR records). If either process dies later, it stops the other and
exits 1.

| Attribute | Default | |
|---|---|---|
| `kafka`, `clickhouse`, `postgres` | (mandatory) | the servers; only their names are used, for the env file paths |
| `meters` | none | see [Meters](#meters) |
| `namespace` | `default` | lower-case letters, digits, `_` |
| `sink_flush_interval` | `250ms` | `<n>ms`, `<n>s` or `<n>m` |
| `sink_min_commit_count` | `500` | |
| `log_level` | `info` | `debug`, `info`, `warn`, `error` |
| `ready_timeout` | `180` | seconds, the backing services included |
| `binaries` | `@openmeter//:binaries` | another `openmeter.version()` hub |

Runtime flags override the defaults (the stack uses them): `--env-file`,
`--state-dir`, `--kafka-env`, `--clickhouse-env`, `--postgres-env`.

The ClickHouse database is the server's `database` (OpenMeter creates its
`om_events` table there); the Postgres database is the `pg_server`'s
(OpenMeter migrates it). Use a `postgres_schema` with any harmless file: rules_pg
requires one; rules_openmeter's own stacks use `@rules_openmeter//private:empty.sql`.

### rules_itest

```python
load("@rules_itest//:itest.bzl", "itest_service", "service_test")
load("@rules_clickhouse//:defs.bzl", "clickhouse_health_check", "clickhouse_server")
load("@rules_kafka//:defs.bzl", "kafka_server", "kafka_server_health_check")
load("@rules_pg//:defs.bzl", "pg_health_check", "pg_server", "postgres_schema")
load("@rules_openmeter//:defs.bzl", "openmeter_health_check", "openmeter_server")

kafka_server(name = "om_kafka", tags = ["manual"])
kafka_server_health_check(name = "om_kafka_health", server = ":om_kafka", tags = ["manual"])
clickhouse_server(name = "om_clickhouse", database = "openmeter", tags = ["manual"])
clickhouse_health_check(name = "om_clickhouse_health", server = ":om_clickhouse", tags = ["manual"])
postgres_schema(name = "om_pg_schema", srcs = ["@rules_openmeter//private:empty.sql"], tags = ["manual"])
pg_server(name = "om_postgres", database = "openmeter", schema = ":om_pg_schema", tags = ["manual"])
pg_health_check(name = "om_postgres_health", server = ":om_postgres", tags = ["manual"])

openmeter_server(
    name = "om",
    kafka = ":om_kafka",
    clickhouse = ":om_clickhouse",
    postgres = ":om_postgres",
    meters = "meters.yaml",
    tags = ["manual"],
)
openmeter_health_check(name = "om_health", server = ":om", tags = ["manual"])

itest_service(name = "om_kafka_svc", exe = ":om_kafka", health_check = ":om_kafka_health",
              health_check_timeout = "300s", shutdown_timeout = "60s", tags = ["manual"])
itest_service(name = "om_clickhouse_svc", exe = ":om_clickhouse", health_check = ":om_clickhouse_health",
              health_check_timeout = "300s", tags = ["manual"])
itest_service(name = "om_postgres_svc", exe = ":om_postgres", health_check = ":om_postgres_health",
              health_check_timeout = "300s", tags = ["manual"])
itest_service(
    name = "om_svc",
    exe = ":om",
    deps = [":om_kafka_svc", ":om_clickhouse_svc", ":om_postgres_svc"],
    health_check = ":om_health",
    health_check_timeout = "300s",
    shutdown_timeout = "30s",
    tags = ["manual"],
)

service_test(
    name = "usage_itest",
    services = [":om_svc"],   # alongside your own service under test
    test = ":usage_itest_bin",
    tags = ["block-network"],
)
```

The test sources `$TEST_TMPDIR/om.env`. This is `//tests:composition_test`.
`shutdown_timeout`: Kafka's clean shutdown takes a few seconds and rules_itest's
default of 1 s would SIGKILL its launcher.

Only one `pg_server` per `service_test` this way: rules_pg keeps its data
in `$TEST_TMPDIR/pgdata` whatever the server's name, so two would collide.
For two OpenMeter instances in one test use two
[`openmeter_stack`](#openmeter_stack)s (`//tests:itest_test` does).

## `openmeter_stack`

The four servers as one long-running executable: `openmeter_stack(name =
"om", meters = ...)` declares `om_kafka`, `om_clickhouse`, `om_postgres`
(+ `om_postgres_schema`) and `om_openmeter` (all `manual`) and `om`, which
starts them at once and is ready when `$TEST_TMPDIR/om.env` (the
`OPENMETER_*` variables) exists. Attributes as `openmeter_test`. Postgres
runs with `TEST_TMPDIR=$TEST_TMPDIR/om_postgres`, which keeps rules_pg's
`pgdata` apart per stack. On SIGTERM it stops OpenMeter, then the rest. If
any server exits, it stops the others and exits 1 naming it.

```python
openmeter_stack(name = "billing_om", meters = "meters.yaml", tags = ["manual"])
openmeter_health_check(name = "billing_om_health", server = ":billing_om", tags = ["manual"])
itest_service(name = "billing_om_svc", exe = ":billing_om", health_check = ":billing_om_health",
              health_check_timeout = "600s", shutdown_timeout = "90s", tags = ["manual"])
```

---

## Meters

`meters` is a YAML file whose only top-level key is `meters:`, in
OpenMeter's own config format (this version loads meters from its config
file at start-up, into the default namespace; the API's `POST
/api/v1/meters` works too):

```yaml
meters:
  - slug: tokens_total
    description: LLM tokens
    eventType: prompt
    aggregation: SUM            # SUM, COUNT, AVG, MIN, MAX, UNIQUE_COUNT, LATEST
    valueProperty: $.tokens     # not for COUNT
    groupBy:
      model: $.model
  - slug: prompts
    eventType: prompt
    aggregation: COUNT
```

It is checked when the target builds (an action, so a bad file fails `bazel
build`), and each problem names the target, the file, the line and the
meter:

```
ERROR: ... Validating OpenMeter meters meters.yaml for //:usage_test_stack_openmeter failed: ...
//:usage_test_stack_openmeter: bad meters file meters.yaml:
  meter #1 (line 2, slug 'tokens_total'): meter value property is required when the aggregation is not count
```

The check: only `meters:` at the top level (anything else would override
rules_openmeter's generated config), no tabs or document markers; per
meter, a `slug` that is a valid meter key (`^[a-z0-9]+(?:_[a-z0-9]+)*$`, at
most 64) and unique, an `aggregation` OpenMeter knows; then **OpenMeter's
own validation**: the pinned `openmeter --validate` (parses the config and
runs its `Validate()`, without connecting to anything), on the whole file
and on each meter alone, so its messages (which don't name the meter) are
attributed. The file is appended to the generated `config.yaml` unchanged.

## Sink flush interval and latency

The sink worker buffers events and writes them to ClickHouse when
`minCommitCount` events are buffered or `maxCommitWait` has passed, whichever
comes first. `sink_flush_interval` sets `sink.maxCommitWait` (default here
250ms, upstream 2s). rules_openmeter also sets `maxPollTimeout` to
min(100ms, the interval), `namespaceRefetch` and `meterRefetchInterval` to
1s (upstream 15s), and the sink's Kafka `autoOffsetReset` to `earliest` (it
may join after the first events).

Measured (`om_wait_value` reports it; on a shared 16-core machine at load
average 16-42, about 60 waits): from the ingest call returning to the value
being queryable, **0.01-0.7 s** with the 250ms default (median well under
0.3 s; many are already queryable on the first poll). From the first
`om_ingest` call to the last of five events being queryable, including
three Python helper start-ups, **0.5-1.2 s** (`//tests:e2e_test` prints
it). In one run of about 60 an event never became queryable within 60 s
(see the note in DESIGN.md's known limitations); `om_wait_value` now prints
OpenMeter's WARN/ERROR records when it times out.

Start-up, the whole stack (Kafka, ClickHouse and Postgres in parallel, then
OpenMeter): **15-28 s** on that machine, mostly the backing services
(Kafka's JVM start and `initdb`: 11-21 s). OpenMeter's own part is
**4-8 s**: the API server 2-6 s (Postgres migrations, 328 of them, run on
every start against a fresh database), the sink worker 1.2-2.3 s to its
partition assignment. The launchers log the breakdown:
`[openmeter] OpenMeter 1.0.0-beta.237 ready at http://127.0.0.1:45073 in 17.1s (backing services 12.1s, API server 3.8s, sink worker 1.2s)`.

## Metering-only mode

What runs: `openmeter` (the API server) and `openmeter-sink-worker`. Not
run: `openmeter-balance-worker`, `openmeter-billing-worker`,
`openmeter-notification-service`, `openmeter-jobs`, Svix, the
benthos collector.

What the backing services are for, at this version:

| Service | Needed for |
|---|---|
| Kafka | ingest: the API produces each event to `om_<namespace>_events`; the sink worker consumes it |
| ClickHouse | the events table `om_events` (created by the API server at start-up) and every meter query |
| Postgres | meters, namespaces, subjects, and the rest of OpenMeter's entities; the API server migrates it at start-up (`postgres.autoMigrate: migration`, embedded migrations, no separate binary) |
| Redis | **not needed**: only for `dedupe` with the `redis` driver and the `progressManager`, both off (dedupe off is upstream's default; OpenMeter also has an in-memory dedupe driver) |
| Svix | **not needed**: without `svix.apiKey` webhooks go to OpenMeter's no-op handler (it logs `svix client not configured, using noop handler`) |

The generated config (`$OPENMETER_CONFIG`; the meters file is appended):

```yaml
address: "127.0.0.1:<api port>"
environment: "test"
telemetry:
  address: "127.0.0.1:<telemetry port>"   # the sink worker gets its own
  trace: {sampler: never, exporters: {otlp: {enabled: false}}}
  metrics: {exporters: {prometheus: {enabled: false}, otlp: {enabled: false}}}
  log: {format: json, level: info, exporters: {otlp: {enabled: false}, stdout: {enabled: false}, file: {enabled: false}}}
termination: {checkInterval: 1s, gracefulShutdownTimeout: 10s, propagationTimeout: 0s}
namespace: {default: "default"}
ingest:
  kafka: {broker: "$KAFKA_BOOTSTRAP_SERVERS", brokerAddressFamily: v4, statsInterval: 0s, socketKeepAliveEnabled: false, partitions: 1}
aggregation:
  clickhouse: {address: "$CLICKHOUSE_NATIVE_ADDR", database: "$CLICKHOUSE_DATABASE", username: ..., password: ..., poolMetrics: {enabled: false}}
dedupe: {enabled: false}
sink:
  minCommitCount: 500
  maxCommitWait: "250ms"
  maxPollTimeout: "100ms"
  namespaceRefetch: 1s
  namespaceRefetchTimeout: 1s
  meterRefetchInterval: 1s
  dedupe: {enabled: false}
  kafka: {brokers: "$KAFKA_BOOTSTRAP_SERVERS", brokerAddressFamily: v4, statsInterval: 0s, autoOffsetReset: earliest}
postgres: {url: "postgres://postgres:postgres@127.0.0.1:<port>/openmeter?sslmode=disable", autoMigrate: migration}
events: {enabled: false}
portal: {enabled: false}
credits: {enabled: false}
progressManager: {enabled: false}
apps: {baseURL: "http://127.0.0.1:<api port>"}
```

Billing, entitlements and notifications have no off switch in the API server
at this version: their routes exist and the server provisions a sandbox app
and a default billing profile in Postgres at start-up, but without their
workers nothing processes them, and nothing of them talks to the network.
OpenMeter reads every environment variable as a config override (viper's
`AutomaticEnv`), so both processes run with a clean environment (`PATH`,
`HOME`, `TMPDIR`, `LANG` only): a `KAFKA_*` or `POSTGRES_*` in a test's
environment can't leak into its config.

## Isolation and the network

Every test in this repo runs with `block-network` (loopback only), the whole
stack included; `//tests:network_blocked_test` proves the sandbox has no
interface but `lo`, that connections to public addresses fail, that
ingest and query work, and that every TCP listener in the sandbox (Kafka,
ClickHouse, Postgres, OpenMeter) is on loopback (127.0.0.1, or
`::ffff:127.0.0.1` for the Kafka JVM's dual-stack sockets). The network is
needed only when Bazel fetches: the OpenMeter layers from ghcr.io (or a
mirror, or nothing with a warm repository cache), and the backing services'
own downloads.

`//tests:isolation_test` runs a stack from a read-only working directory
with a read-only `HOME` and `TMPDIR`, ingests and queries, stops it with
SIGTERM (every process gone, env file removed, exit 0), and checks no file
outside `$TEST_TMPDIR` is newer than its start. OpenMeter's own files: the
state dir. Its listeners: the API and telemetry ports (server), a telemetry
port (sink worker), all 127.0.0.1. One exception, not ours: Postgres's POSIX
dynamic shared memory segments (`/dev/shm/PostgreSQL.<n>`, rules_pg leaves
`dynamic_shared_memory_type` at its default), which exist while it runs and
are removed at its clean shutdown.

## Where the binaries come from

OpenMeter's GitHub releases carry only `benthos-collector`. The server and
the workers ship only in the multi-arch image
`ghcr.io/openmeterio/openmeter:v1.0.0-beta.237` (an OCI index with
linux/amd64 and linux/arm64). Upstream's Dockerfile builds them fully
static (musl, `-extldflags -static`, CGO for confluent-kafka-go's
librdkafka) and copies each into `/usr/local/bin/` with `COPY --link`, so
each binary is exactly one image layer holding only
`usr/local/bin/<binary>`. rules_openmeter downloads those two layers per
platform by digest and unpacks them; nothing else of the image (Alpine,
the other workers) is fetched, and nothing needs Docker or rules_oci.

| | linux/amd64 | linux/arm64 |
|---|---|---|
| index (`v1.0.0-beta.237`) | `sha256:9bf7d5575ba726442978d28f4472c76e94843ec21608494fbb50fdf8fb94a62f` | |
| manifest | `sha256:ff8caa82be82fb7ae1cea3c06a6c36f848f038dcaddedb83081891e21ff97c8b` | `sha256:0ab50e8023d5f09209952c149771d64c8d3c50e49ac082ad451466f1e4d33794` |
| `openmeter` layer | `sha256:b8e9f26e25048808cdc5a55dcc77446b9d64ccce20e17c3a9b3cc660f787c073` (88 MiB) | `sha256:a5e576ebee6943c5c299462f0e999b4a29badf3a0d95f5f9bf68374744b2abec` |
| `openmeter-sink-worker` layer | `sha256:e92dcbbc7f74e9246a41456fccafa955a10e33193ef9ede589f68c139a58c716` (68 MiB) | `sha256:08f4d10e47f59c8066b73e26ef43a88ec8c84bd4d534eb9e76c3158409391938` |

- **Content is pinned by sha256** (a layer's digest is its sha256), so a
  layer is the same wherever it comes from.
- **Lazy, per platform:** the hub `@openmeter` selects
  `@openmeter_linux_amd64` or `@openmeter_linux_arm64`; only the one a build
  needs is fetched (about 156 MiB compressed for amd64).
- **ghcr auth:** ghcr requires a bearer token even for anonymous pulls. The
  repository rule tries, in order: each `mirrors` URL without credentials;
  the registry without credentials (a hit in Bazel's repository cache,
  keyed by sha256, succeeds here with no network); then it fetches an
  anonymous token from `https://ghcr.io/token?scope=repository:openmeterio/openmeter:pull`
  (`rctx.download` + `json.decode`) and downloads with it, passed as
  `rctx.download_and_extract(auth = {<blob URL>: {"type": "pattern",
  "pattern": "Bearer <password>", ...}})`. `auth` is keyed by URL, so the
  token goes to the registry only, not to the blob storage host it
  redirects to. The token is never hashed or written to the repo, so it
  doesn't affect reproducibility. (`auth` patterns work on every Bazel with
  Bzlmod; rctx.download's `headers` would need 7.1+.)
- **Mirrors:** `openmeter.version(mirrors = ["https://mirror.example.com/v2/openmeterio/openmeter/blobs/{digest}"])`;
  placeholders `{digest}` (`sha256:<hex>`), `{hex}`, `{registry}`, `{repository}`.
- The extracted binaries are upstream's, unmodified; OpenMeter is
  Apache-2.0 (see [License](#license)).

## Versions

```python
openmeter = use_extension("@rules_openmeter//:extensions.bzl", "openmeter")
openmeter.version(version = "1.0.0-beta.237")         # a pinned version

openmeter.version(                                    # any other tag: pin it yourself
    version = "1.0.0-beta.236",
    server_layer = {"linux_amd64": "sha256:..."},
    sink_worker_layer = {"linux_amd64": "sha256:..."},
)
```

The root module's tag wins (other modules' are ignored); the same tag twice
is fine, two different ones for one `name` fail. A version not pinned in
`private/versions.bzl` without layer pins fails, naming the supported ones.
`name = "other"` makes a second hub; `use_repo(openmeter, "other")` and pass
`binaries = "@other//:binaries"`. (Naming `@openmeter//...` yourself, e.g.
`$(rootpath @openmeter//:server)`, likewise needs `use_repo(openmeter, "openmeter")`.)
(The build-time meters check always runs `@openmeter`'s binary.)

`tools/update_versions.sh <version>` (or `--latest`, from `gh release
view`) resolves a tag: the index, each platform's manifest, and the layers
holding the two binaries (from the image config's history, confirmed by
listing the layer); it downloads each layer, checks its sha256, and checks
the binary is a static ELF for the right architecture with no program
interpreter (`file`, and the ELF program headers). `--check` re-resolves
every pin and fails on any difference (CI runs it). It prints the layer
digests to pass to `openmeter.version()` for an unpinned tag too.

---

## Development

```bash
bazel test //tests/...                     # everything; block-network
tools/update_versions.sh --check           # the pins against ghcr.io
.github/consumer/check.sh /tmp/consumer    # as a dependency, from git archive
```

See DESIGN.md for the decisions and CLAUDE.md for the layout.

## License

[Apache License 2.0](LICENSE) (SPDX: `Apache-2.0`).

OpenMeter is Apache-2.0 too ([its LICENSE](https://github.com/openmeterio/openmeter/blob/main/LICENSE));
the `openmeter` and `openmeter-sink-worker` binaries these rules extract
from upstream's image are upstream's, unmodified. Kafka, ClickHouse and
PostgreSQL come through their own rules, under their own licences.

---

## Requesting a new rules package

Want Bazel rules for another tool or service?
[Request a rules package](https://github.com/collider-bazel-extensions/.github/issues/new?template=request-a-rules-package.yml).
The [organization page](https://github.com/collider-bazel-extensions) lists every package.
