"""openmeter_stack: a whole OpenMeter stack (Kafka, ClickHouse, Postgres,
OpenMeter) as one long-running executable.

The macro declares the four servers (`<name>_kafka`, `<name>_clickhouse`,
`<name>_postgres`, `<name>_openmeter`, all tagged manual) and `<name>`, which
runs them together (stack.py) and is ready when `$TEST_TMPDIR/<name>.env`
(the OPENMETER_* variables) exists. openmeter_test runs one; in a rules_itest
composition it is one itest_service with openmeter_health_check(server =
":<name>"), and two stacks can share a service_test.
"""

load("@rules_clickhouse//:defs.bzl", "clickhouse_server")
load("@rules_kafka//:defs.bzl", "kafka_server")
load("@rules_pg//:defs.bzl", "pg_server", "postgres_schema")
load(":server.bzl", "openmeter_server")

def _shell_quote(s):
    return "'" + s.replace("'", "'\\''") + "'"

def _runner_impl(ctx):
    wrapper = ctx.actions.declare_file(ctx.label.name + ".sh")
    exes = {
        "__KAFKA__": ctx.executable.kafka,
        "__CLICKHOUSE__": ctx.executable.clickhouse,
        "__POSTGRES__": ctx.executable.postgres,
        "__OPENMETER__": ctx.executable.openmeter,
    }
    subs = {k: v.short_path for k, v in exes.items()}
    subs.update({
        "__NAME__": ctx.label.name,
        "__STACK__": ctx.file._stack.short_path,
        "__KAFKA_NAME__": ctx.attr.kafka.label.name,
        "__CLICKHOUSE_NAME__": ctx.attr.clickhouse.label.name,
        "__POSTGRES_NAME__": ctx.attr.postgres.label.name,
        "__READY_TIMEOUT__": _shell_quote(ctx.attr.ready_timeout),
    })
    ctx.actions.expand_template(
        template = ctx.file._tmpl,
        output = wrapper,
        substitutions = subs,
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = [wrapper, ctx.file._stack])
    for attr in [ctx.attr.kafka, ctx.attr.clickhouse, ctx.attr.postgres, ctx.attr.openmeter]:
        runfiles = runfiles.merge(attr[DefaultInfo].default_runfiles)
    return [DefaultInfo(executable = wrapper, runfiles = runfiles)]

openmeter_stack_runner = rule(
    implementation = _runner_impl,
    executable = True,
    doc = "Runs a kafka_server, clickhouse_server, pg_server and openmeter_server together (see openmeter_stack).",
    attrs = {
        "kafka": attr.label(mandatory = True, executable = True, cfg = "target"),
        "clickhouse": attr.label(mandatory = True, executable = True, cfg = "target"),
        "postgres": attr.label(mandatory = True, executable = True, cfg = "target"),
        "openmeter": attr.label(mandatory = True, executable = True, cfg = "target"),
        "ready_timeout": attr.string(default = "600"),
        "_stack": attr.label(default = "//private:stack.py", allow_single_file = True),
        "_tmpl": attr.label(default = "//private:stack.sh.tmpl", allow_single_file = True),
    },
)

def openmeter_stack(
        name,
        meters = None,
        namespace = "default",
        sink_flush_interval = "250ms",
        sink_min_commit_count = 500,
        log_level = "info",
        ready_timeout = 180,
        kafka_heap = "512m",
        binaries = None,
        tags = None,
        testonly = None,
        visibility = None,
        **kwargs):
    """A whole OpenMeter stack as one long-running executable `<name>`.

    Args:
      name: the stack's name; its env file is `$TEST_TMPDIR/<name>.env`.
      meters: a YAML file with a top-level `meters:` list (see openmeter_server).
      namespace: OpenMeter's default namespace.
      sink_flush_interval: the sink worker's `maxCommitWait` (default 250ms).
      sink_min_commit_count: the sink worker's `minCommitCount` (default 500).
      log_level: OpenMeter's log level.
      ready_timeout: seconds for OpenMeter to be ready once started (its
        backing services included).
      kafka_heap: the Kafka broker's -Xmx.
      binaries: an openmeter.version() hub's `:binaries` (default @openmeter).
      tags: tags for `<name>` (the servers also get "manual").
      testonly: forwarded.
      visibility: forwarded to `<name>`.
      **kwargs: forwarded to `<name>`.
    """
    tags = tags or []
    inner_tags = tags + ["manual"]
    common = dict(tags = inner_tags, testonly = testonly, visibility = ["//visibility:private"])
    kafka_server(
        name = name + "_kafka",
        heap = kafka_heap,
        **common
    )
    clickhouse_server(
        name = name + "_clickhouse",
        database = "openmeter",
        **common
    )
    postgres_schema(
        name = name + "_postgres_schema",
        # OpenMeter migrates Postgres itself; rules_pg wants a schema.
        srcs = [Label("//private:empty.sql")],
        **common
    )
    pg_server(
        name = name + "_postgres",
        schema = ":" + name + "_postgres_schema",
        database = "openmeter",
        **common
    )
    server_kwargs = {}
    if binaries:
        server_kwargs["binaries"] = binaries
    openmeter_server(
        name = name + "_openmeter",
        kafka = ":" + name + "_kafka",
        clickhouse = ":" + name + "_clickhouse",
        postgres = ":" + name + "_postgres",
        meters = meters,
        namespace = namespace,
        sink_flush_interval = sink_flush_interval,
        sink_min_commit_count = sink_min_commit_count,
        log_level = log_level,
        ready_timeout = str(ready_timeout),
        **dict(common, **server_kwargs)
    )
    openmeter_stack_runner(
        name = name,
        kafka = ":" + name + "_kafka",
        clickhouse = ":" + name + "_clickhouse",
        postgres = ":" + name + "_postgres",
        openmeter = ":" + name + "_openmeter",
        tags = tags,
        testonly = testonly,
        visibility = visibility,
        **kwargs
    )
