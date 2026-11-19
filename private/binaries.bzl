"""openmeter_binaries: OpenMeter's server and sink worker for one platform."""

OpenMeterBinaryInfo = provider(
    doc = "OpenMeter's binaries for one platform, extracted from the pinned image.",
    fields = {
        "server": "File: usr/local/bin/openmeter (the API server).",
        "sink_worker": "File: usr/local/bin/openmeter-sink-worker.",
        "version": "string: the OpenMeter version, e.g. 1.0.0-beta.237.",
        "platform": "string: e.g. linux_amd64.",
        "files": "depset: both binaries.",
    },
)

def _impl(ctx):
    files = depset([ctx.file.server, ctx.file.sink_worker])
    return [
        DefaultInfo(files = files),
        OpenMeterBinaryInfo(
            server = ctx.file.server,
            sink_worker = ctx.file.sink_worker,
            version = ctx.attr.version,
            platform = ctx.attr.platform,
            files = files,
        ),
    ]

openmeter_binaries = rule(
    implementation = _impl,
    doc = "Declared in the generated `@<hub>_<platform>` repos; `@openmeter//:binaries` selects one.",
    attrs = {
        "server": attr.label(mandatory = True, allow_single_file = True),
        "sink_worker": attr.label(mandatory = True, allow_single_file = True),
        "version": attr.string(mandatory = True),
        "platform": attr.string(mandatory = True),
    },
    provides = [OpenMeterBinaryInfo],
)
