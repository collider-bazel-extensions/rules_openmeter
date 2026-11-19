#!/usr/bin/env bash
# Consumer checks against the commit's release archive (git archive honours
# .gitattributes export-ignore, as GitHub's tag tarballs do):
#   1. a root with the README's overrides and no openmeter.version()
#      resolves, and an openmeter_test (meters file, om_ingest, om_query,
#      om_wait_value) runs offline (block-network) on the default version
#   2. a bad meters file fails the build, naming the target, the file, the
#      meter and the reason
#   3. the same version set twice in the root resolves; set twice
#      differently fails
#   4. an unsupported version without pins fails, naming openmeter.version
#   5. with the layers in Bazel's repository cache, the binaries fetch with
#      no registry at all (registry = an unresolvable host): no token, no
#      network
#   6. @rules_openmeter//... loads (tests/ and tools/ are not shipped)
# Usage: .github/consumer/check.sh <scratch dir>
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
work="$1"
src="$work/rules_openmeter"
rm -rf "$work"; mkdir -p "$src"
git -C "$repo" archive HEAD | tar -x -C "$src"
for d in tests tools; do
    if [[ -e "$src/$d" ]]; then echo "FAIL: archive contains $d/" >&2; exit 1; fi
done
default_version="$(sed -n 's/^DEFAULT_VERSION = "\(.*\)"$/\1/p' "$src/private/versions.bzl")"

# The overrides a consumer needs (the README's Installation section), with
# rules_openmeter itself from the archive instead of its tag tarball.
overrides() {
    sed -n '/^bazel_dep(name = "rules_kafka"/,/^)$/p; /^bazel_dep(name = "rules_kubectl"/,/^)$/p; /^bazel_dep(name = "rules_clickhouse"/,/^)$/p; /^bazel_dep(name = "rules_pg"/,/^)$/p' "$src/MODULE.bazel"
}

# The README shows a consumer the same overrides, line for line.
while IFS= read -r line; do
    grep -qxF -- "$line" "$src/README.md" || { echo "FAIL: the README's Installation section lacks: $line" >&2; exit 1; }
done < <(overrides)
echo "PASS: the README's overrides match MODULE.bazel's"

consumer() { # <name> <extra MODULE.bazel lines> [meters file contents]
    local c="$work/$1"
    mkdir -p "$c"
    if [[ -f "$repo/.bazelversion" ]]; then cp "$repo/.bazelversion" "$c/"; fi
    cat > "$c/MODULE.bazel" <<MOD
module(name = "consumer")
bazel_dep(name = "rules_openmeter")
local_path_override(module_name = "rules_openmeter", path = "$src")
$(overrides)
$2
MOD
    printf '%s\n' "${3:-meters:
  - slug: tokens_total
    eventType: prompt
    aggregation: SUM
    valueProperty: \$.tokens
  - slug: prompts
    eventType: prompt
    aggregation: COUNT}" > "$c/meters.yaml"
    cat > "$c/usage_test.sh" <<SH
#!/usr/bin/env bash
set -euo pipefail
source "\$OPENMETER_TESTLIB"
[[ "\$OPENMETER_VERSION" == "$default_version" ]]
[[ "\$OPENMETER_URL" == http://127.0.0.1:* ]]
om_ingest --type prompt --subject alice --data '{"tokens": 5}'
om_ingest --type prompt --subject alice --data '{"tokens": 7}'
om_ingest --type prompt --subject bob --data '{"tokens": 100}'
# Each value is waited for: bob's event can be in a later flush than alice's.
om_wait_value 12 tokens_total --subject alice
om_wait_value 2 prompts --subject alice
om_wait_value 100 tokens_total --subject bob
SH
    chmod +x "$c/usage_test.sh"
    cat > "$c/BUILD.bazel" <<'BUILD'
load("@rules_openmeter//:defs.bzl", "openmeter_test")

openmeter_test(
    name = "usage_test",
    srcs = ["usage_test.sh"],
    meters = "meters.yaml",
    tags = ["block-network"],
)
BUILD
    echo "$c"
}

# 1. The README's overrides, no openmeter.version(): an openmeter_test runs offline.
c="$(consumer default "")"
(cd "$c" && bazel mod deps >/dev/null)
(cd "$c" && bazel test //:usage_test --test_output=errors --sandbox_default_allow_network=false)
echo "PASS: a root with the README's overrides resolves; OpenMeter $default_version runs an openmeter_test offline"

# 2. A bad meters file fails the build clearly.
c="$(consumer badmeters "" "meters:
  - slug: tokens_total
    eventType: prompt
    aggregation: SUM")"
if (cd "$c" && bazel build //:usage_test) > "$work/badmeters.out" 2>&1; then
    echo "FAIL: a bad meters file built" >&2; exit 1
fi
grep -q "//:usage_test_stack_openmeter: bad meters file meters.yaml:" "$work/badmeters.out" &&
grep -q "meter #1 (line 2, slug 'tokens_total'): meter value property is required when the aggregation is not count" "$work/badmeters.out" || {
    cat "$work/badmeters.out" >&2; echo "FAIL: bad meters: wrong error" >&2; exit 1; }
echo "PASS: a bad meters file fails the build, naming the target, file, meter and reason"

# 3. The same version twice resolves; two different ones for one name fail.
c="$(consumer twice "openmeter = use_extension(\"@rules_openmeter//:extensions.bzl\", \"openmeter\")
openmeter.version(version = \"$default_version\")
openmeter.version(version = \"$default_version\")")"
(cd "$c" && bazel mod deps >/dev/null)
echo "PASS: repeated identical openmeter.version resolves"
c="$(consumer conflict "openmeter = use_extension(\"@rules_openmeter//:extensions.bzl\", \"openmeter\")
openmeter.version(version = \"$default_version\")
openmeter.version(version = \"0.0.1\", server_layer = {\"linux_amd64\": \"sha256:$(printf '0%.0s' {1..64})\"}, sink_worker_layer = {\"linux_amd64\": \"sha256:$(printf '0%.0s' {1..64})\"})")"
if (cd "$c" && bazel build //:usage_test) > "$work/conflict.out" 2>&1; then
    echo "FAIL: conflicting openmeter.version tags resolved" >&2; exit 1
fi
grep -q 'sets openmeter.version(name = "openmeter") twice, differently' "$work/conflict.out" || {
    cat "$work/conflict.out" >&2; echo "FAIL: conflicting tags: wrong error" >&2; exit 1; }
echo "PASS: conflicting openmeter.version tags fail clearly"

# 4. An unsupported version without pins fails, naming openmeter.version.
c="$(consumer unsupported 'openmeter = use_extension("@rules_openmeter//:extensions.bzl", "openmeter")
openmeter.version(version = "0.0.1")')"
if (cd "$c" && bazel build //:usage_test) > "$work/unsupported.out" 2>&1; then
    echo "FAIL: unsupported version resolved" >&2; exit 1
fi
grep -q 'openmeter.version(version = "0.0.1") is not supported' "$work/unsupported.out" || {
    cat "$work/unsupported.out" >&2; echo "FAIL: unsupported version: wrong error" >&2; exit 1; }
echo "PASS: unsupported version fails clearly"

# 5. Warm repository cache: no registry needed (an unresolvable host).
c="$(consumer cached 'openmeter = use_extension("@rules_openmeter//:extensions.bzl", "openmeter")
openmeter.version(version = "'"$default_version"'", registry = "registry.invalid")
use_repo(openmeter, "openmeter")')"
(cd "$c" && bazel build @openmeter//:binaries)
echo "PASS: with the layers in the repository cache, the binaries fetch with no registry (no token, no network)"

# 6. //... loads.
(cd "$work/default" && bazel query @rules_openmeter//... >/dev/null)
echo "PASS: @rules_openmeter//... loads"

for d in "$work"/*/; do [[ -f "$d/MODULE.bazel" && "$d" != "$src/" ]] && (cd "$d" && bazel shutdown) || true; done
