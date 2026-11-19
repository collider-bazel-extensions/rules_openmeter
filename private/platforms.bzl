"""Supported platforms and where OpenMeter's binaries come from.

OpenMeter's GitHub releases carry only `benthos-collector`; the server and
the workers ship only in the multi-arch image ghcr.io/openmeterio/openmeter.
Its Dockerfile builds them fully static (musl, `-extldflags -static`) and
copies each into `/usr/local/bin/` with `COPY --link`, so each binary is one
image layer holding just `usr/local/bin/<binary>`. The pins (index, manifest
and layer digests) are generated into versions.bzl by
tools/update_versions.sh.
"""

PLATFORMS = {
    "linux_amd64": ["@platforms//os:linux", "@platforms//cpu:x86_64"],
    "linux_arm64": ["@platforms//os:linux", "@platforms//cpu:arm64"],
}

# The binaries rules_openmeter extracts: the API server and the sink worker
# (metering only: no balance, billing or notification workers, no jobs).
BINARIES = ["openmeter", "openmeter-sink-worker"]

# The image repository (registry host + path).
REGISTRY = "ghcr.io"
REPOSITORY = "openmeterio/openmeter"

# Anonymous pull token (ghcr requires one even for public images). The
# token is a credential, not content: it is fetched only when a blob isn't
# already in the repository cache or a mirror, and never hashed.
TOKEN_URL = "https://{registry}/token?scope=repository:{repository}:pull&service={registry}"

# {registry}, {repository}, {digest} (sha256:<hex>).
BLOB_URL = "https://{registry}/v2/{repository}/blobs/{digest}"
