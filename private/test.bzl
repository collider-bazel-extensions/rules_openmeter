"""openmeter_test: an sh_test with an auto-launched OpenMeter stack.

Each target gets its own stack (openmeter_stack: Kafka, ClickHouse,
Postgres and OpenMeter, each on its own free loopback ports with its data
under the test's $TEST_TMPDIR), so tests are safe under `--jobs=N`.

The trampoline (openmeter_test_trampoline.sh) starts the stack, waits for
its env file, sources it (the OPENMETER_* variables), exports
OPENMETER_TESTLIB and runs the test with the target's args. It runs the
test rather than exec'ing it, so it can stop the stack when the test ends,
and stops the test if the stack dies under it.
"""

load("@rules_shell//shell:sh_binary.bzl", "sh_binary")
load("@rules_shell//shell:sh_test.bzl", "sh_test")
load(":stack.bzl", "openmeter_stack")

def openmeter_test(
        name,
        srcs,
        meters = None,
        namespace = "default",
        sink_flush_interval = "250ms",
        sink_min_commit_count = 500,
        log_level = "info",
        ready_timeout = 180,
        kafka_heap = "512m",
        binaries = None,
        deps = None,
        data = None,
        args = None,
        size = "large",
        timeout = None,
        tags = None,
        **kwargs):
    """sh_test against an auto-launched OpenMeter stack.

    Args:
      name: target name.
      srcs: the test script (one file).
      meters: a YAML file with a top-level `meters:` list, checked at build
        time and loaded at start-up.
      namespace: OpenMeter's default namespace (OPENMETER_NAMESPACE).
      sink_flush_interval: the sink worker's `maxCommitWait` (default 250ms).
      sink_min_commit_count: the sink worker's `minCommitCount` (default 500).
      log_level: OpenMeter's log level.
      ready_timeout: seconds for OpenMeter to be ready once started.
      kafka_heap: the Kafka broker's -Xmx (default 512m).
      binaries: an openmeter.version() hub's `:binaries` (default @openmeter).
      deps: forwarded to the inner sh_binary.
      data: runfiles for the test (on the inner sh_binary and the sh_test,
        so `args` may use $(rootpath) on them).
      args: arguments for the test script.
      size: sh_test size. Default "large": four servers start (about 20-60 s
        on a loaded machine), and OpenMeter migrates Postgres.
      timeout: sh_test timeout.
      tags: tags for the sh_test (helper targets also get "manual").
      **kwargs: forwarded to sh_test (env, env_inherit, flaky, shard_count, ...).
    """
    tags = tags or []
    stack_name = name + "_stack"
    openmeter_stack(
        name = stack_name,
        meters = meters,
        namespace = namespace,
        sink_flush_interval = sink_flush_interval,
        sink_min_commit_count = sink_min_commit_count,
        log_level = log_level,
        ready_timeout = ready_timeout,
        kafka_heap = kafka_heap,
        binaries = binaries,
        tags = tags + ["manual"],
        testonly = True,
    )

    inner_name = name + "_inner"
    sh_binary(
        name = inner_name,
        srcs = srcs,
        deps = deps,
        data = data,
        tags = tags + ["manual"],
        testonly = True,
    )

    sh_test(
        name = name,
        srcs = [Label("//private:openmeter_test_trampoline.sh")],
        args = [
            "$(rootpath :{})".format(stack_name),
            "$(rootpath :{})".format(inner_name),
            stack_name,
            "$(rootpath {})".format(Label("//private:testlib.sh")),
        ] + (args or []),
        # `data` here too, so `args` can use $(rootpath) on it.
        data = [
            ":" + stack_name,
            ":" + inner_name,
            Label("//private:testlib.sh"),
            Label("//private:om.py"),
        ] + (data or []),
        size = size,
        timeout = timeout,
        tags = tags,
        **kwargs
    )
