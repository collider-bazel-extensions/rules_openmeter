"""Hub repo `@<name>` and lazy per-platform repos `@<name>_<platform>`.

The hub declares `:binaries`, an alias that selects the target platform's
`@<name>_<platform>//:binaries` (an `openmeter_binaries`), so only the
platform a build needs is downloaded. Each platform repo downloads the
image layers holding `usr/local/bin/openmeter` and
`usr/local/bin/openmeter-sink-worker` by digest and extracts them: no
Docker, no rules_oci, no image unpacking beyond those two layers.

Download order for each layer (all pinned by sha256, so the result is the
same whichever answers):
  1. the `mirrors` URL templates, without credentials;
  2. the registry, without credentials: a hit in Bazel's repository cache
     (keyed by sha256) needs no network at all;
  3. the registry with an anonymous bearer token from its token endpoint
     (ghcr requires one even for public pulls), passed to rctx.download's
     `auth` for the registry URL only, so the redirect to the blob storage
     host carries no token.
The token is not content: it is never hashed and never written to the repo.
"""

load(":platforms.bzl", "BINARIES", "BLOB_URL", "PLATFORMS", "REGISTRY", "REPOSITORY", "TOKEN_URL")
load(":versions.bzl", "OPENMETER_VERSIONS")

_HUB_BUILD = """\
package(default_visibility = ["//visibility:public"])

{settings}
# The target platform's OpenMeter {version} binaries (an openmeter_binaries).
alias(
    name = "binaries",
    actual = select(
        {{
{selects}
        }},
        no_match_error = "rules_openmeter: no OpenMeter binaries for this target platform; supported: {platforms}",
    ),
)

# The binaries themselves (files), for `$(rootpath)` / data.
alias(
    name = "server",
    actual = select(
        {{
{server_selects}
        }},
        no_match_error = "rules_openmeter: no OpenMeter binaries for this target platform; supported: {platforms}",
    ),
)

alias(
    name = "sink_worker",
    actual = select(
        {{
{sink_selects}
        }},
        no_match_error = "rules_openmeter: no OpenMeter binaries for this target platform; supported: {platforms}",
    ),
)
"""

_SETTING = """\
config_setting(
    name = "_{plat}",
    constraint_values = {compat},
)
"""

_PLATFORM_BUILD = """\
load("@rules_openmeter//private:binaries.bzl", "openmeter_binaries")

package(default_visibility = ["//visibility:public"])

exports_files({binaries})

openmeter_binaries(
    name = "binaries",
    server = "usr/local/bin/openmeter",
    sink_worker = "usr/local/bin/openmeter-sink-worker",
    version = "{version}",
    platform = "{plat}",
)
"""

def _hub_impl(rctx):
    settings = []
    selects, server, sink = [], [], []
    for plat, compat in PLATFORMS.items():
        settings.append(_SETTING.format(plat = plat, compat = repr(compat)))
        selects.append('            ":_{plat}": "@{hub}_{plat}//:binaries",'.format(plat = plat, hub = rctx.attr.hub))
        server.append('            ":_{plat}": "@{hub}_{plat}//:usr/local/bin/openmeter",'.format(plat = plat, hub = rctx.attr.hub))
        sink.append('            ":_{plat}": "@{hub}_{plat}//:usr/local/bin/openmeter-sink-worker",'.format(plat = plat, hub = rctx.attr.hub))
    rctx.file("WORKSPACE", "workspace(name = \"{}\")\n".format(rctx.name))
    rctx.file("BUILD.bazel", _HUB_BUILD.format(
        settings = "\n".join(settings),
        selects = "\n".join(selects),
        server_selects = "\n".join(server),
        sink_selects = "\n".join(sink),
        version = rctx.attr.version,
        platforms = ", ".join(sorted(PLATFORMS.keys())),
    ))

_openmeter_hub = repository_rule(
    implementation = _hub_impl,
    attrs = {
        "version": attr.string(mandatory = True),
        # The hub's apparent name, which prefixes its platform repos' names.
        "hub": attr.string(mandatory = True),
    },
)

def _hex(digest):
    if not digest.startswith("sha256:") or len(digest) != 71:
        fail("rules_openmeter: {} is not a sha256:<64 hex> digest".format(repr(digest)))
    return digest[len("sha256:"):]

def _token(rctx, registry, repository):
    out = "_token.json"
    rctx.download(
        url = TOKEN_URL.format(registry = registry, repository = repository),
        output = out,
    )
    data = json.decode(rctx.read(out))
    rctx.delete(out)
    token = data.get("token") or data.get("access_token")
    if not token:
        fail("rules_openmeter: {}'s token endpoint returned no token".format(registry))
    return token

def _fetch_layer(rctx, digest, out_dir, state):
    sha = _hex(digest)
    for tmpl in rctx.attr.mirrors:
        url = tmpl.format(digest = digest, hex = sha, registry = rctx.attr.registry, repository = rctx.attr.repository)
        r = rctx.download_and_extract(url = url, sha256 = sha, type = "tar.gz", output = out_dir, allow_fail = True)
        if r.success:
            return
    url = BLOB_URL.format(registry = rctx.attr.registry, repository = rctx.attr.repository, digest = digest)

    # A repository-cache hit (same sha256) needs no credentials or network.
    r = rctx.download_and_extract(url = url, sha256 = sha, type = "tar.gz", output = out_dir, allow_fail = True)
    if r.success:
        return
    if not state.get("token"):
        state["token"] = _token(rctx, rctx.attr.registry, rctx.attr.repository)
    rctx.download_and_extract(
        url = url,
        sha256 = sha,
        type = "tar.gz",
        output = out_dir,
        auth = {url: {"type": "pattern", "pattern": "Bearer <password>", "password": state["token"]}},
    )

def _platform_impl(rctx):
    state = {}
    for binary in BINARIES:
        digest = rctx.attr.layers.get(binary)
        if not digest:
            fail("rules_openmeter: no layer pin for {} on {} (OpenMeter {}); set it in openmeter.version({}_layer = {{\"{}\": \"sha256:...\"}}).".format(
                binary,
                rctx.attr.platform,
                rctx.attr.version,
                "server" if binary == "openmeter" else "sink_worker",
                rctx.attr.platform,
            ))
        # Each layer holds just usr/local/bin/<binary> (COPY --link).
        _fetch_layer(rctx, digest, ".", state)
        if not rctx.path("usr/local/bin/" + binary).exists:
            fail("rules_openmeter: layer {} has no usr/local/bin/{}; the pin names the wrong layer".format(digest, binary))
    rctx.file("WORKSPACE", "workspace(name = \"{}\")\n".format(rctx.name))
    rctx.file("BUILD.bazel", _PLATFORM_BUILD.format(
        binaries = repr(["usr/local/bin/" + b for b in BINARIES]),
        version = rctx.attr.version,
        plat = rctx.attr.platform,
    ))

_openmeter_platform = repository_rule(
    implementation = _platform_impl,
    attrs = {
        "version": attr.string(mandatory = True),
        "platform": attr.string(mandatory = True),
        # binary -> layer digest (sha256:<hex>).
        "layers": attr.string_dict(mandatory = True),
        "registry": attr.string(default = REGISTRY),
        "repository": attr.string(default = REPOSITORY),
        # URL templates tried first: {digest} (sha256:<hex>), {hex},
        # {registry}, {repository}.
        "mirrors": attr.string_list(),
    },
)

def openmeter_version_repository(name, version, server_layer = {}, sink_worker_layer = {}, registry = "", repository = "", mirrors = []):
    """The hub `@<name>` and its per-platform repos for one OpenMeter version.

    Layer pins default to OPENMETER_VERSIONS[version]; `server_layer` and
    `sink_worker_layer` (platform -> sha256:<hex>) replace them.
    """
    known = OPENMETER_VERSIONS.get(version, {})
    for attr_name, pins in [("server_layer", server_layer), ("sink_worker_layer", sink_worker_layer)]:
        for plat in pins:
            if plat not in PLATFORMS:
                fail("rules_openmeter: openmeter.version({} = ...) has unknown platform '{}'. Platforms: {}".format(
                    attr_name,
                    plat,
                    ", ".join(sorted(PLATFORMS.keys())),
                ))
    _openmeter_hub(name = name, version = version, hub = name)
    for plat in PLATFORMS.keys():
        layers = {}
        for binary in BINARIES:
            pin = (server_layer if binary == "openmeter" else sink_worker_layer).get(plat) or known.get(plat, {}).get(binary)
            if pin:
                layers[binary] = pin
        _openmeter_platform(
            name = "{}_{}".format(name, plat),
            version = version,
            platform = plat,
            layers = layers,
            registry = registry or REGISTRY,
            repository = repository or REPOSITORY,
            mirrors = mirrors,
        )
