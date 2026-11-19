"""openmeter_server + openmeter_health_check: a hermetic OpenMeter test fixture.

`openmeter_server` is a long-running executable (see launcher.py): it waits
for the Kafka, ClickHouse and Postgres servers' env files
(`$TEST_TMPDIR/<their name>.env`), writes OpenMeter's config.yaml into
`$TEST_TMPDIR/<name>/`, starts the API server and the sink worker on free
127.0.0.1 ports, and once `GET /api/v1/meters` answers and the sink worker
is consuming the namespace's events topic, writes `$TEST_TMPDIR/<name>.env`
(the OPENMETER_* variables, see the README) and runs until SIGTERM.
`openmeter_health_check` exits 0 iff that file exists; it drops into
`itest_service.health_check`.
"""

load(":binaries.bzl", "OpenMeterBinaryInfo")

OpenMeterServerInfo = provider(
    doc = "An openmeter_server target.",
    fields = {
        "binaries": "OpenMeterBinaryInfo: the binaries it runs.",
        "namespace": "string: the default namespace.",
        "meters": "File or None: the validated meters file.",
    },
)

_NAMESPACE = "abcdefghijklmnopqrstuvwxyz0123456789"

def _shell_quote(s):
    return "'" + s.replace("'", "'\\''") + "'"

def _positive_number(label, attr_name, value):
    raw = value.strip()
    digits = raw.replace(".", "", 1)
    if not raw or not digits.isdigit() or not digits.replace("0", ""):
        fail("{}: {} = {}: expected a positive number of seconds.".format(label, attr_name, repr(value)))
    return raw

def check_duration(label, attr_name, value):
    """A Go duration rules_openmeter accepts: <number><ms|s|m>, positive."""
    v = value.strip()
    for unit in ["ms", "s", "m"]:
        if v.endswith(unit):
            num = v[:-len(unit)]
            digits = num.replace(".", "", 1)
            if num and digits.isdigit() and digits.replace("0", ""):
                return v
            break
    fail("{}: {} = {}: expected a positive duration such as 250ms, 1s or 1.5s (units: ms, s, m).".format(
        label,
        attr_name,
        repr(value),
    ))

def check_namespace(label, ns):
    # The namespace becomes the Kafka topic om_<namespace>_events, which the
    # sink worker matches with ^om_([A-Za-z0-9]+(?:_[A-Za-z0-9]+)*)_events$.
    parts = ns.split("_")
    if not ns or [p for p in parts if not p] or [c for c in ns.elems() if c not in (_NAMESPACE + "_").elems()]:
        fail("{}: namespace = {}: expected lower-case letters and digits, words joined by `_` (it names the Kafka topic om_<namespace>_events).".format(
            label,
            repr(ns),
        ))

def check_log_level(label, level):
    if level not in ["debug", "info", "warn", "error"]:
        fail("{}: log_level = {}: expected debug, info, warn or error.".format(label, repr(level)))

def _validate_meters(ctx, validator):
    out = ctx.actions.declare_file(ctx.label.name + ".meters.yaml")
    ctx.actions.run_shell(
        inputs = [ctx.file.meters, ctx.file._validate],
        tools = [validator.server],
        outputs = [out],
        command = 'exec python3 -I "$@"',
        arguments = [
            ctx.file._validate.path,
            str(ctx.label),
            ctx.file.meters.path,
            validator.server.path,
            out.path,
        ],
        mnemonic = "OpenMeterMeters",
        progress_message = "Validating OpenMeter meters %{input} for %{label}",
        use_default_shell_env = True,
    )
    return out

def _openmeter_server_impl(ctx):
    om = ctx.attr.binaries[OpenMeterBinaryInfo]
    check_namespace(ctx.label, ctx.attr.namespace)
    check_log_level(ctx.label, ctx.attr.log_level)
    flush = check_duration(ctx.label, "sink_flush_interval", ctx.attr.sink_flush_interval)
    if ctx.attr.sink_min_commit_count < 1:
        fail("{}: sink_min_commit_count = {}: expected at least 1.".format(ctx.label, ctx.attr.sink_min_commit_count))
    ready = _positive_number(ctx.label, "ready_timeout", ctx.attr.ready_timeout)

    files = []
    meters = None
    meters_line = ""
    if ctx.file.meters:
        meters = _validate_meters(ctx, ctx.attr._validator[OpenMeterBinaryInfo])
        files.append(meters)
        meters_line = 'p="$(resolve {})"; opts+=(--meters "$p")'.format(_shell_quote(meters.short_path))

    wrapper = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._tmpl,
        output = wrapper,
        substitutions = {
            "__NAME__": ctx.label.name,
            "__LAUNCHER__": ctx.file._launcher.short_path,
            "__SERVER__": om.server.short_path,
            "__SINK_WORKER__": om.sink_worker.short_path,
            "__VERSION__": om.version,
            "__KAFKA__": ctx.attr.kafka.label.name,
            "__CLICKHOUSE__": ctx.attr.clickhouse.label.name,
            "__POSTGRES__": ctx.attr.postgres.label.name,
            "__METERS__": meters_line,
            "__OPTS__": " ".join([_shell_quote(o) for o in [
                "--namespace",
                ctx.attr.namespace,
                "--flush-interval",
                flush,
                "--min-commit-count",
                str(ctx.attr.sink_min_commit_count),
                "--log-level",
                ctx.attr.log_level,
                "--ready-timeout",
                ready,
            ]]),
        },
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = [wrapper, ctx.file._launcher] + files, transitive_files = om.files)
    return [
        DefaultInfo(executable = wrapper, runfiles = runfiles),
        OpenMeterServerInfo(binaries = om, namespace = ctx.attr.namespace, meters = meters),
    ]

openmeter_server = rule(
    implementation = _openmeter_server_impl,
    executable = True,
    doc = """\
Long-running OpenMeter (API server + sink worker) for tests and rules_itest
compositions, against a kafka_server, a clickhouse_server and a pg_server.
Writes `$TEST_TMPDIR/<name>.env` once `GET /api/v1/meters` answers and the
sink worker is consuming the namespace's events topic. If a backing env file
doesn't appear, OpenMeter refuses its config, exits, or isn't ready within
`ready_timeout`, it exits non-zero with the errors from OpenMeter's log.

Runtime flags (after `--` with `bazel run`, or from a wrapper) override the
defaults: `--env-file`, `--state-dir`, `--kafka-env`, `--clickhouse-env`,
`--postgres-env`.
""",
    attrs = {
        "kafka": attr.label(
            mandatory = True,
            doc = "The kafka_server (rules_kafka); its env file is " +
                  "`$TEST_TMPDIR/<its name>.env` (KAFKA_BOOTSTRAP_SERVERS).",
        ),
        "clickhouse": attr.label(
            mandatory = True,
            doc = "The clickhouse_server (rules_clickhouse); its env file is " +
                  "`$TEST_TMPDIR/<its name>.env` (CLICKHOUSE_NATIVE_ADDR, " +
                  "CLICKHOUSE_DATABASE, CLICKHOUSE_USER, CLICKHOUSE_PASSWORD).",
        ),
        "postgres": attr.label(
            mandatory = True,
            doc = "The pg_server (rules_pg); its env file is " +
                  "`$TEST_TMPDIR/<its name>.env` (PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD).",
        ),
        "meters": attr.label(
            allow_single_file = [".yaml", ".yml", ".json"],
            doc = "A YAML file whose only top-level key is `meters:` (OpenMeter's " +
                  "meter definitions, as in its config.yaml). Checked at build " +
                  "time, OpenMeter's own validation included; the server loads " +
                  "them into the namespace at start-up.",
        ),
        "namespace": attr.string(
            default = "default",
            doc = "OpenMeter's default namespace (OPENMETER_NAMESPACE); its events " +
                  "topic is om_<namespace>_events.",
        ),
        "sink_flush_interval": attr.string(
            default = "250ms",
            doc = "The longest an event waits in the sink worker's buffer before it " +
                  "is written to ClickHouse (`sink.maxCommitWait`). Default 250ms " +
                  "(upstream: 2s).",
        ),
        "sink_min_commit_count": attr.int(
            default = 500,
            doc = "Buffered events that trigger a flush before the interval " +
                  "(`sink.minCommitCount`; upstream's default).",
        ),
        "log_level": attr.string(
            default = "info",
            doc = "OpenMeter's log level (debug, info, warn, error).",
        ),
        "ready_timeout": attr.string(
            default = "180",
            doc = "Seconds to wait for the backing services' env files and for " +
                  "OpenMeter to be ready (migrations included).",
        ),
        "binaries": attr.label(
            default = Label("@openmeter//:binaries"),
            providers = [OpenMeterBinaryInfo],
            doc = "The OpenMeter binaries (an openmeter.version() hub's `:binaries`).",
        ),
        "_validator": attr.label(
            default = Label("@openmeter//:binaries"),
            cfg = "exec",
            providers = [OpenMeterBinaryInfo],
        ),
        "_validate": attr.label(default = "//private:validate_meters.py", allow_single_file = True),
        "_launcher": attr.label(default = "//private:launcher.py", allow_single_file = True),
        "_tmpl": attr.label(default = "//private:server.sh.tmpl", allow_single_file = True),
    },
)

# ---- openmeter_health_check -------------------------------------------------

def _openmeter_health_check_impl(ctx):
    wrapper = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._tmpl,
        output = wrapper,
        substitutions = {"__ENV_FILE_NAME__": ctx.attr.server.label.name + ".env"},
        is_executable = True,
    )
    return [DefaultInfo(executable = wrapper)]

openmeter_health_check = rule(
    implementation = _openmeter_health_check_impl,
    executable = True,
    doc = "Exits 0 iff the paired openmeter_server's (or openmeter_stack's) env " +
          "file exists (it is written once the API answers and the sink worker " +
          "consumes the events topic).",
    attrs = {
        "server": attr.label(
            mandatory = True,
            doc = "The openmeter_server or openmeter_stack this check pairs with.",
        ),
        "_tmpl": attr.label(default = "//private:health_check.sh.tmpl", allow_single_file = True),
    },
)
