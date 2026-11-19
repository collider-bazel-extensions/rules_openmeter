#!/usr/bin/env bash
# Resolve OpenMeter image tags to pins and (re)generate private/versions.bzl.
#
#   tools/update_versions.sh [VERSION...]   pin these versions (default: the
#                                           ones already pinned, plus the
#                                           latest GitHub release with
#                                           --latest); rewrites versions.bzl
#   tools/update_versions.sh --check        re-resolve every pinned version
#                                           and fail on any difference
#   tools/update_versions.sh --latest       add the latest release (gh release view)
#
# For each version (image tag v<VERSION> of ghcr.io/openmeterio/openmeter):
#   - the OCI index digest, and per platform (linux/amd64, linux/arm64) the
#     image manifest digest;
#   - the layer holding usr/local/bin/openmeter and the one holding
#     usr/local/bin/openmeter-sink-worker, found from the image config's
#     history (`COPY /usr/local/bin/<binary> /usr/local/bin/`) and confirmed
#     by listing the layer;
#   - each layer is downloaded, its sha256 checked against its digest, and
#     the binary in it checked to be a static ELF of the right architecture
#     with no program interpreter (`file`, and the ELF program headers).
# Needs curl, python3, file; anonymous ghcr token, no Docker.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 -I - "$repo" "$@" <<'PY'
import hashlib, io, json, os, re, struct, subprocess, sys, tarfile, tempfile, urllib.request

REPO_ROOT = sys.argv[1]
ARGS = sys.argv[2:]
REGISTRY, REPOSITORY = "ghcr.io", "openmeterio/openmeter"
PLATFORMS = {"linux_amd64": ("linux", "amd64", 0x3E), "linux_arm64": ("linux", "arm64", 0xB7)}
BINARIES = ["openmeter", "openmeter-sink-worker"]
VERSIONS_BZL = os.path.join(REPO_ROOT, "private", "versions.bzl")
INDEX_TYPES = "application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json"
MANIFEST_TYPES = "application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"

def log(m): print(m, file=sys.stderr, flush=True)

_token = None
def token():
    global _token
    if _token is None:
        url = f"https://{REGISTRY}/token?scope=repository:{REPOSITORY}:pull&service={REGISTRY}"
        _token = json.load(urllib.request.urlopen(url, timeout=60))["token"]
    return _token

def get(path, accept=None, stream=False):
    req = urllib.request.Request(f"https://{REGISTRY}/v2/{REPOSITORY}/{path}")
    req.add_header("Authorization", "Bearer " + token())
    if accept:
        req.add_header("Accept", accept)
    r = urllib.request.urlopen(req, timeout=600)
    return r if stream else (r.headers, r.read())

def sha256(b): return "sha256:" + hashlib.sha256(b).hexdigest()

def elf_check(data, machine, name):
    """A static executable: ELF, the right e_machine, no PT_INTERP, no PT_DYNAMIC."""
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        raise SystemExit(f"{name}: not a 64-bit little-endian ELF")
    e_type, e_machine = struct.unpack_from("<HH", data, 16)
    if e_machine != machine:
        raise SystemExit(f"{name}: e_machine {e_machine:#x}, expected {machine:#x}")
    if e_type != 2:
        raise SystemExit(f"{name}: ELF type {e_type}, expected ET_EXEC (a static, non-PIE executable)")
    phoff, = struct.unpack_from("<Q", data, 32)
    phentsize, phnum = struct.unpack_from("<HH", data, 54)
    for i in range(phnum):
        p_type, = struct.unpack_from("<I", data, phoff + i * phentsize)
        if p_type == 3:
            raise SystemExit(f"{name}: has a program interpreter (PT_INTERP): dynamically linked")
        if p_type == 2:
            raise SystemExit(f"{name}: has a PT_DYNAMIC segment: dynamically linked")

def resolve(version, verify=True):
    tag = "v" + version
    log(f"== {tag}")
    headers, body = get(f"manifests/{tag}", INDEX_TYPES)
    index = json.loads(body)
    index_digest = headers.get("Docker-Content-Digest") or sha256(body)
    if sha256(body) != index_digest:
        raise SystemExit(f"{tag}: index digest header {index_digest} != sha256 of the body")
    if "manifests" not in index:
        raise SystemExit(f"{tag}: not a multi-platform index")
    pins = {"tag": tag, "index": index_digest}
    for plat, (os_, arch, machine) in PLATFORMS.items():
        ms = [m for m in index["manifests"] if m.get("platform", {}).get("os") == os_ and m["platform"].get("architecture") == arch]
        if len(ms) != 1:
            raise SystemExit(f"{tag}: {len(ms)} manifests for {os_}/{arch}")
        mdigest = ms[0]["digest"]
        _, mbody = get(f"manifests/{mdigest}", MANIFEST_TYPES)
        if sha256(mbody) != mdigest:
            raise SystemExit(f"{tag} {plat}: manifest sha256 mismatch")
        manifest = json.loads(mbody)
        _, cbody = get(f"blobs/{manifest['config']['digest']}")
        if sha256(cbody) != manifest["config"]["digest"]:
            raise SystemExit(f"{tag} {plat}: config sha256 mismatch")
        config = json.loads(cbody)
        layers = manifest["layers"]
        history = [h for h in config.get("history", []) if not h.get("empty_layer")]
        if len(history) != len(layers):
            raise SystemExit(f"{tag} {plat}: {len(history)} non-empty history entries for {len(layers)} layers")
        plat_pins = {"manifest": mdigest}
        for binary in BINARIES:
            hits = [i for i, h in enumerate(history)
                    if re.search(r"COPY (?:--\S+ )*/usr/local/bin/%s /usr/local/bin/" % re.escape(binary), h.get("created_by", ""))]
            if len(hits) != 1:
                raise SystemExit(f"{tag} {plat}: {len(hits)} layers copy /usr/local/bin/{binary}")
            ldigest = layers[hits[0]]["digest"]
            plat_pins[binary] = ldigest
            if verify:
                log(f"   {plat} {binary}: {ldigest} ({layers[hits[0]]['size'] // 1048576} MiB)")
                blob = get(f"blobs/{ldigest}", stream=True).read()
                if sha256(blob) != ldigest:
                    raise SystemExit(f"{tag} {plat}: layer {ldigest}: sha256 mismatch")
                with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as t:
                    names = [m.name for m in t.getmembers() if m.isfile()]
                    if names != [f"usr/local/bin/{binary}"]:
                        raise SystemExit(f"{tag} {plat}: layer {ldigest} holds {names}, expected just usr/local/bin/{binary}")
                    data = t.extractfile(f"usr/local/bin/{binary}").read()
                elf_check(data, machine, f"{tag} {plat} {binary}")
                with tempfile.NamedTemporaryFile() as f:
                    f.write(data); f.flush()
                    desc = subprocess.run(["file", "-b", f.name], capture_output=True, text=True).stdout.strip()
                if "statically linked" not in desc:
                    raise SystemExit(f"{tag} {plat} {binary}: `file` says: {desc}")
                log(f"   ok: static ({desc.split(',')[0]}, {desc.split(',')[1].strip()}; no interpreter)")
        pins[plat] = plat_pins
    return pins

def read_pins():
    text = open(VERSIONS_BZL).read()
    default = re.search(r'^DEFAULT_VERSION = "([^"]+)"', text, re.M).group(1)
    body = text[re.search(r"^OPENMETER_VERSIONS = ", text, re.M).end():]
    # The dict literal is JSON-compatible apart from trailing commas.
    pins = json.loads(re.sub(r",(\s*[}\]])", r"\1", body))
    return default, pins

def render(default, pins):
    head = open(VERSIONS_BZL).read()
    head = head[: re.search(r"^DEFAULT_VERSION = ", head, re.M).start()]
    out = [head + f'DEFAULT_VERSION = "{default}"\n\nOPENMETER_VERSIONS = {{\n']
    for v in sorted(pins, key=lambda s: [int(x) if x.isdigit() else x for x in re.split(r"[.-]", s)], reverse=True):
        p = pins[v]
        out.append(f'    "{v}": {{\n        "tag": "{p["tag"]}",\n        "index": "{p["index"]}",\n')
        for plat in PLATFORMS:
            out.append(f'        "{plat}": {{\n')
            for k in ["manifest"] + BINARIES:
                out.append(f'            "{k}": "{p[plat][k]}",\n')
            out.append("        },\n")
        out.append("    },\n")
    out.append("}\n")
    return "".join(out)

def latest():
    r = subprocess.run(["gh", "release", "view", "-R", "openmeterio/openmeter", "--json", "tagName", "-q", ".tagName"],
                       capture_output=True, text=True, check=True)
    return r.stdout.strip().lstrip("v")

default, pins = read_pins()
if "--check" in ARGS:
    bad = 0
    for v, p in pins.items():
        got = resolve(v)
        if got != p:
            bad += 1
            log(f"FAIL: {v}: pinned\n{json.dumps(p, indent=2)}\nresolves to\n{json.dumps(got, indent=2)}")
        else:
            log(f"ok: {v} matches its pins")
    if bad:
        sys.exit(1)
    log("PASS: every pin matches the registry; every binary is static")
    sys.exit(0)

versions = [a for a in ARGS if not a.startswith("--")]
if "--latest" in ARGS:
    versions.append(latest())
if not versions:
    versions = list(pins)
for v in versions:
    pins[v.lstrip("v")] = resolve(v.lstrip("v"))
if "--latest" in ARGS:
    default = versions[-1].lstrip("v")
open(VERSIONS_BZL, "w").write(render(default, pins))
log(f"wrote {VERSIONS_BZL} (default {default})")
PY
