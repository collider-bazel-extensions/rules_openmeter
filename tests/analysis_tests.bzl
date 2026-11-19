"""Analysis tests: providers, the meters validation action, executables,
and the attribute checks (each failing at analysis time with a clear message)."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//:defs.bzl", "OpenMeterBinaryInfo", "OpenMeterServerInfo", "openmeter_health_check", "openmeter_server")
load("//private:versions.bzl", "DEFAULT_VERSION")

# ---- providers + actions ----------------------------------------------------------

def _server_impl(ctx):
    env = analysistest.begin(ctx)
    t = analysistest.target_under_test(env)
    info = t[OpenMeterServerInfo]
    asserts.equals(env, "billing_ns", info.namespace)
    asserts.true(env, info.meters != None, "meters file")
    asserts.equals(env, "a_server.meters.yaml", info.meters.basename)
    asserts.equals(env, DEFAULT_VERSION, info.binaries.version)
    asserts.equals(env, "openmeter", info.binaries.server.basename)
    asserts.equals(env, "openmeter-sink-worker", info.binaries.sink_worker.basename)
    mnemonics = [a.mnemonic for a in analysistest.target_actions(env)]
    asserts.true(env, "OpenMeterMeters" in mnemonics, "meters validation action: " + str(mnemonics))
    exe = t[DefaultInfo].files_to_run.executable
    asserts.equals(env, "a_server.sh", exe.basename)
    runfiles = [f.basename for f in t[DefaultInfo].default_runfiles.files.to_list()]
    for want in ["launcher.py", "openmeter", "openmeter-sink-worker", "a_server.meters.yaml"]:
        asserts.true(env, want in runfiles, "runfiles have " + want + ": " + str(runfiles))
    return analysistest.end(env)

server_test = analysistest.make(_server_impl)

def _no_meters_impl(ctx):
    env = analysistest.begin(ctx)
    t = analysistest.target_under_test(env)
    asserts.equals(env, None, t[OpenMeterServerInfo].meters)
    mnemonics = [a.mnemonic for a in analysistest.target_actions(env)]
    asserts.false(env, "OpenMeterMeters" in mnemonics, "no validation action without meters")
    return analysistest.end(env)

no_meters_test = analysistest.make(_no_meters_impl)

def _binaries_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[OpenMeterBinaryInfo]
    asserts.equals(env, DEFAULT_VERSION, info.version)
    asserts.equals(env, "linux_amd64", info.platform)
    asserts.equals(env, 2, len(info.files.to_list()))
    return analysistest.end(env)

binaries_test = analysistest.make(_binaries_impl)

def _health_impl(ctx):
    env = analysistest.begin(ctx)
    t = analysistest.target_under_test(env)
    asserts.equals(env, "a_health.sh", t[DefaultInfo].files_to_run.executable.basename)
    return analysistest.end(env)

health_test = analysistest.make(_health_impl)

# ---- failures -------------------------------------------------------------------

def _fails_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.message)
    return analysistest.end(env)

fails_test = analysistest.make(
    _fails_impl,
    expect_failure = True,
    attrs = {"message": attr.string(mandatory = True)},
)

_BAD = {
    "bad_namespace": (dict(namespace = "Billing-NS"), "namespace = \"Billing-NS\": expected lower-case letters and digits"),
    "empty_namespace_word": (dict(namespace = "a__b"), "namespace = \"a__b\""),
    "bad_flush": (dict(sink_flush_interval = "1 second"), "sink_flush_interval = \"1 second\": expected a positive duration"),
    "zero_flush": (dict(sink_flush_interval = "0s"), "sink_flush_interval = \"0s\""),
    "bad_unit": (dict(sink_flush_interval = "1h"), "sink_flush_interval = \"1h\""),
    "bad_min_commit": (dict(sink_min_commit_count = 0), "sink_min_commit_count = 0: expected at least 1"),
    "bad_log_level": (dict(log_level = "trace"), "log_level = \"trace\": expected debug, info, warn or error"),
    "bad_timeout": (dict(ready_timeout = "-5"), "ready_timeout = \"-5\": expected a positive number of seconds"),
}

def analysis_test_suite(name):
    """The analysis tests, as one test_suite."""
    common = dict(kafka = ":dummy", clickhouse = ":dummy", postgres = ":dummy", tags = ["manual"])
    native.filegroup(name = "dummy", tags = ["manual"])
    openmeter_server(
        name = "a_server",
        meters = "//tests/testdata:meters.yaml",
        namespace = "billing_ns",
        **common
    )
    openmeter_server(name = "a_server_no_meters", **common)
    openmeter_health_check(name = "a_health", server = ":a_server", tags = ["manual"])
    tests = []
    server_test(name = "server_provider_test", target_under_test = ":a_server")
    no_meters_test(name = "server_no_meters_test", target_under_test = ":a_server_no_meters")
    binaries_test(name = "binaries_provider_test", target_under_test = "@openmeter//:binaries")
    health_test(name = "health_check_test", target_under_test = ":a_health")
    tests += ["server_provider_test", "server_no_meters_test", "binaries_provider_test", "health_check_test"]
    for bad, (attrs, msg) in _BAD.items():
        openmeter_server(name = "bad_" + bad, **dict(common, **attrs))
        fails_test(name = bad + "_test", target_under_test = ":bad_" + bad, message = msg)
        tests.append(bad + "_test")
    native.test_suite(name = name, tests = [":" + t for t in tests])
