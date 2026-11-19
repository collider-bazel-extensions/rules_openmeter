"""Bzlmod extension: `openmeter.version()` -> the hub `@<name>` and lazy
per-platform repos `@<name>_<platform>` holding OpenMeter's binaries.

rules_openmeter's own MODULE.bazel sets `openmeter.version(version =
DEFAULT_VERSION)` for the hub `@openmeter`, which the rules use by default,
so consumers need no extension wiring. A root module's tag overrides it by
name:

    openmeter = use_extension("@rules_openmeter//:extensions.bzl", "openmeter")
    openmeter.version(version = "1.0.0-beta.237")         # pinned in private/versions.bzl

    openmeter.version(                                    # any other image tag:
        version = "1.0.0-beta.236",                       # pin it yourself
        server_layer = {"linux_amd64": "sha256:<layer with usr/local/bin/openmeter>"},
        sink_worker_layer = {"linux_amd64": "sha256:<layer with usr/local/bin/openmeter-sink-worker>"},
    )

    openmeter.version(                                    # blobs from a mirror first
        version = "1.0.0-beta.237",
        mirrors = ["https://mirror.example.com/openmeter/blobs/{digest}"],
    )

`tools/update_versions.sh <version>` prints the layer digests for a tag.
"""

load("//private:platforms.bzl", "PLATFORMS")
load("//private:repositories.bzl", "openmeter_version_repository")
load("//private:versions.bzl", "DEFAULT_VERSION", "OPENMETER_VERSIONS")

_version_tag = tag_class(attrs = {
    "name": attr.string(
        default = "openmeter",
        doc = "The hub repo's name. `openmeter` (the default) is the one the " +
              "rules use; another name makes a second hub whose " +
              "`@<name>//:binaries` you pass as `binaries = ...`.",
    ),
    "version": attr.string(
        mandatory = True,
        doc = "An OpenMeter image tag without the leading `v`, e.g. 1.0.0-beta.237.",
    ),
    "server_layer": attr.string_dict(
        doc = "Platform -> digest (sha256:<hex>) of the image layer holding " +
              "usr/local/bin/openmeter. Replaces the pin in private/versions.bzl.",
    ),
    "sink_worker_layer": attr.string_dict(
        doc = "Platform -> digest of the layer holding usr/local/bin/openmeter-sink-worker.",
    ),
    "registry": attr.string(doc = "Registry host; default ghcr.io."),
    "repository": attr.string(doc = "Image repository; default openmeterio/openmeter."),
    "mirrors": attr.string_list(
        doc = "Blob URL templates tried before the registry, without " +
              "credentials: {digest} (sha256:<hex>), {hex}, {registry}, {repository}.",
    ),
})

def _pins(tag):
    return struct(
        version = tag.version,
        server_layer = dict(tag.server_layer),
        sink_worker_layer = dict(tag.sink_worker_layer),
        registry = tag.registry,
        repository = tag.repository,
        mirrors = list(tag.mirrors),
    )

def _default_pins():
    return struct(version = DEFAULT_VERSION, server_layer = {}, sink_worker_layer = {}, registry = "", repository = "", mirrors = [])

def _tags_by_name(mod):
    repos = {}
    for tag in mod.tags.version:
        pins = _pins(tag)
        prev = repos.get(tag.name)
        if prev != None and prev != pins:
            fail("rules_openmeter: {} sets openmeter.version(name = \"{}\") twice, differently ({} and {}); set one.".format(
                "the root module" if mod.is_root else mod.name,
                tag.name,
                prev.version,
                pins.version,
            ))
        repos[tag.name] = pins
    return repos

def _impl(mctx):
    # The extension runs once for the whole build and sees every module's
    # tags; the repos it creates are global to it, so each name is created
    # once. rules_openmeter's own tags are the base and the root module's
    # override them by name (or add names); other modules' tags are
    # ignored. A root without openmeter.version() gets DEFAULT_VERSION.
    own, root = {}, {}
    for mod in mctx.modules:
        if mod.is_root:
            root = _tags_by_name(mod)
        elif mod.name == "rules_openmeter":
            own = _tags_by_name(mod)
    repos = {"openmeter": _default_pins()}
    repos.update(own)
    repos.update(root)
    for name, pins in repos.items():
        if pins.version not in OPENMETER_VERSIONS and not (pins.server_layer and pins.sink_worker_layer):
            fail(("rules_openmeter: openmeter.version(version = \"{}\") is not supported. Supported: {}. " +
                  "For another image tag, pin it yourself: openmeter.version(version = ..., " +
                  "server_layer = {{<platform>: \"sha256:...\"}}, sink_worker_layer = {{<platform>: \"sha256:...\"}}) " +
                  "(tools/update_versions.sh <version> prints them); platforms: {}.").format(
                pins.version,
                ", ".join(sorted(OPENMETER_VERSIONS.keys())),
                ", ".join(sorted(PLATFORMS.keys())),
            ))
        openmeter_version_repository(
            name = name,
            version = pins.version,
            server_layer = pins.server_layer,
            sink_worker_layer = pins.sink_worker_layer,
            registry = pins.registry,
            repository = pins.repository,
            mirrors = pins.mirrors,
        )
    return mctx.extension_metadata(reproducible = True)

openmeter = module_extension(
    implementation = _impl,
    tag_classes = {"version": _version_tag},
)
