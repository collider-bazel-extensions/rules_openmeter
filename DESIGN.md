# rules_openmeter design

OpenMeter as a per-test instance: the API server and the sink worker from a
pinned release, on Kafka, ClickHouse and Postgres from this org's rules, all
on loopback, all under `$TEST_TMPDIR`, offline. The structure follows
rules_clickhouse and rules_kafka (launcher, trampoline, env file, health
check), rules_argocd/rules_clickhouse for version pins.

## Decisions

| # | Decision | Why | Alternatives rejected |
|---|---|---|---|
| 1 | Binaries extracted from the digest-pinned image's layers, by a repository rule (`rctx.download_and_extract(sha256 = ...)`) | Upstream's GitHub releases have only `benthos-collector`; the server and workers exist only in `ghcr.io/openmeterio/openmeter`. Each binary is one `COPY --link` layer holding only `usr/local/bin/<binary>`, fully static (musl), so two layers per platform are all that's needed | Docker / a container runtime (not hermetic, not in CI sandboxes); rules_oci + an image pull (a heavy dependency for every consumer, and it would still need extracting); building from source (Go + CGO + musl + librdkafka toolchain) |
| 2 | Pins: index digest, per-platform manifest digest, and the two layer digests; the layers are what is downloaded | A layer digest is its sha256: content is fixed whatever serves it. Index and manifest digests record provenance; `tools/update_versions.sh --check` re-resolves the tag against all of them | Pinning only the tag (mutable); downloading the manifest at fetch time (an extra registry round trip for no extra integrity) |
| 3 | ghcr token: fetched in the repository rule only when needed (after mirrors and an unauthenticated try, which a repository-cache hit satisfies), passed with `auth = {url: {"type": "pattern", "pattern": "Bearer <password>"}}` | ghcr needs a bearer token even for anonymous pulls. The token isn't content; with sha256 pinning it can't change the result. `auth` is keyed by URL, so the token isn't sent to the blob host ghcr redirects to; it works on any Bzlmod Bazel (`headers` needs 7.1+). Trying without a token first makes a warm repository cache fully offline (the consumer check proves it with an unresolvable registry) | A credential helper (consumer setup); a token baked into the pins (expires); `headers` (sent on redirects too) |
| 4 | Hub `@openmeter` (`:binaries`, `:server`, `:sink_worker` aliases over a `select`) + lazy `@openmeter_<platform>` repos; rules take `binaries = "@openmeter//:binaries"` | Only the target platform's layers download. A label attribute is simpler than a toolchain for one consumer rule set, and a second hub is just another label | Toolchains (more machinery than one rule set needs) |
| 5 | Extension like rules_clickhouse/rules_argocd: own tag + root overrides by name; a root without tags gets DEFAULT_VERSION; unknown versions need `server_layer` + `sink_worker_layer` | The org's established shape (rules_atlas v0.5.1's fix for a tagless root included) | |
| 6 | Metering only: the API server and the sink worker; no Redis, no Svix | At this version Redis is only for the `redis` dedupe driver and the progress manager (both off; dedupe off is upstream's default). Svix is optional: without `svix.apiKey` webhooks go to a no-op handler. The balance, billing and notification workers are separate binaries we don't run | rules_valkey for Redis (an unused fourth JVM-less service and its start-up time) |
| 7 | Config: generated YAML (every address 127.0.0.1 with a free port, every exporter off, logs to files), meters file appended | OpenMeter reads meters from its config file at this version (`MeterConfigInitializer` creates them in Postgres at start-up), so no API calls are needed. Appending keeps the user's YAML byte-for-byte; the build check forbids other top-level keys | Creating meters through the API after start-up (more moving parts, no benefit at this version); merging YAML (no YAML parser in stdlib Python or Starlark) |
| 8 | OpenMeter's processes run with a clean environment | viper's `AutomaticEnv` makes every environment variable a config override (`POSTGRES_URL`, `SINK_...`): the test's environment must not leak in | Passing the environment through |
| 9 | Build-time meters check: a Python pre-check (top-level keys, slug syntax and uniqueness, aggregation enum) plus the pinned `openmeter --validate` on the whole file and on each meter alone | `--validate` is upstream's own validation without side effects (it exits before connecting), so the check is exactly what the server would reject; its messages don't name the meter, so running it per meter attributes them. Uniqueness and the aggregation enum aren't checked by upstream's `Validate()` | A hand-written schema only (drifts from upstream); checking at start-up only (a failed test 20 s later instead of a failed build) |
| 10 | Readiness: `GET /api/v1/meters` = 200, then start the sink worker, then wait for its `kafka partition assignment` log record naming `om_<namespace>_events` and `/healthz/ready` | The API is ready only after migrations, namespace provisioning (which creates the events topic) and meter loading. The sink must start after the migrations (it reads meters from Postgres) and must own the partition before the test ingests, or a test could query before the sink consumes | Health endpoints only (`/healthz/ready` is up before the partition is assigned); a canary event (pollutes the test's data) |
| 10a | Before the sink worker starts, commit offset 0 on every partition of `om_<namespace>_events` for its group (`kafka-consumer-groups --reset-offsets --to-earliest --execute` via rules_kafka's `kafka_cli`) | Root cause of lost first events (CI: 7 of 12 tokens; locally 2 of 72 runs of `no_lost_events_test`): upstream's `NewSinkKafkaConsumer` hardcodes `AutoOffsetReset = latest`, overriding `sink.kafka.autoOffsetReset`; a fresh group's "latest" is resolved after the assignment callback (which is what readiness saw), so events produced in between were skipped. A committed offset makes the start position independent of timing. Evidence: a second sink with a fresh group joining after event A, then event B, counted A once and B twice (21, not 22); before the fix the group's committed offset at ready was `-`, now `0` (`//tests:e2e_test` asserts it) | Waiting longer before ready (narrows the window, doesn't close it); a canary event (pollutes the data, and only proves one partition); patching OpenMeter (we ship upstream's binaries unmodified) |
| 11 | Sink settings: `maxCommitWait` = `sink_flush_interval` (250ms default), `maxPollTimeout` min(100ms, interval), `namespaceRefetch` and `meterRefetchInterval` 1s | Upstream's 2s flush and 15s refetches are tuned for throughput; a test wants latency. Measured ingest → queryable 0.01-0.7 s | `minCommitCount: 1` (a ClickHouse insert per event: slow for batches); exposed as `sink_min_commit_count` instead |
| 12 | `openmeter_stack` (all four servers as one executable) under `openmeter_test` | One `itest_service` for a whole stack, and two stacks per test: Postgres runs with `TEST_TMPDIR=$TEST_TMPDIR/<stack>_postgres` because rules_pg keeps its data in `$TEST_TMPDIR/pgdata` whatever the server's name | Only the per-service composition (two pg_servers in one service_test would share `pgdata`) |
| 13 | Start order: all four at once; the OpenMeter launcher waits for the three env files | Kafka (JVM) and Postgres (`initdb`) dominate start-up; starting OpenMeter's launcher alongside costs nothing | Sequential start |
| 14 | Children in their own sessions with `PR_SET_PDEATHSIG=SIGKILL`; SIGTERM stops OpenMeter first, then the backing services | A SIGKILLed launcher leaves nothing; OpenMeter's sink flushes before its Kafka and ClickHouse go | Killing process groups only |
| 15 | No public `openmeter` CLI target | Upstream has no CLI in the image beyond the servers; `@openmeter//:server` is a file label for `$(rootpath)` | |

## Flow

```
openmeter_test (sh_test) ── trampoline ──┬── stack.py ──┬── kafka_server   ($TEST_TMPDIR/<s>_kafka.env)
                                         │              ├── clickhouse_server ($TEST_TMPDIR/<s>_clickhouse.env)
                                         │              ├── pg_server  (TEST_TMPDIR=$TEST_TMPDIR/<s>_postgres)
                                         │              └── launcher.py ── waits for the 3 env files
                                         │                     ├── openmeter --config config.yaml      (migrate, topic, meters, API)
                                         │                     └── openmeter-sink-worker --config ...  (Kafka -> ClickHouse)
                                         │                  writes $TEST_TMPDIR/<s>.env
                                         └── the test (OPENMETER_* + om_* helpers)
```

## Known limitations

- Linux only (upstream builds Linux binaries); arm64 pinned, not tested.
- Each test starts its own Kafka, ClickHouse and Postgres: 15-30 s on a
  loaded machine, about 1.5 GB of memory. Share a stack across test cases
  in one script when that matters.
- Postgres's POSIX shared memory (`/dev/shm/PostgreSQL.<n>`) is outside
  `$TEST_TMPDIR` while it runs (rules_pg's configuration).
- The offsets are set for the default namespace's topic only. A namespace
  created later through the API gets a topic the sink joins with upstream's
  `latest`, so its very first events can be skipped as above.
- Billing, entitlements and notification routes can't be switched off in the
  API server at this version; they're inert without their workers.
