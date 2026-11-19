#!/usr/bin/env python3
"""The HTTP side of testlib.sh's helpers (stdlib only). Talks to
$OPENMETER_URL. Subcommands:

  api METHOD PATH [BODY] [CONTENT_TYPE]   print the body; exit 1 unless 2xx
  status METHOD PATH [BODY] [CONTENT_TYPE] print the HTTP status code
  ingest ...                               see testlib.sh (om_ingest)
  query METER ...                          see testlib.sh (om_query)
  wait EXPECTED METER ...                  see testlib.sh (om_wait_value)
"""

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid


def die(msg, code=1):
    sys.stderr.write(msg.rstrip("\n") + "\n")
    sys.exit(code)


def base_url():
    url = os.environ.get("OPENMETER_URL")
    if not url:
        die("om: OPENMETER_URL is not set (source the openmeter env file, or run under openmeter_test)")
    return url.rstrip("/")


def request(method, path, body=None, content_type="application/json", timeout=60):
    data = None
    if body is not None:
        data = body if isinstance(body, bytes) else body.encode()
    req = urllib.request.Request(base_url() + path, data=data, method=method)
    if data is not None:
        req.add_header("Content-Type", content_type)
    req.add_header("Accept", "application/json, application/problem+json")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()
    except OSError as e:
        die(f"om: {method} {path}: {e}")


def cmd_api(args, status_only=False):
    if len(args) < 2:
        die("usage: om_api METHOD PATH [BODY] [CONTENT_TYPE]")
    method, path = args[0], args[1]
    body = args[2] if len(args) > 2 else None
    if body == "-":
        body = sys.stdin.read()
    ctype = args[3] if len(args) > 3 else "application/json"
    code, text = request(method.upper(), path, body, ctype)
    if status_only:
        print(code)
        return 0
    sys.stdout.write(text)
    if text and not text.endswith("\n"):
        sys.stdout.write("\n")
    if not 200 <= code < 300:
        sys.stderr.write(f"om_api: {method.upper()} {path}: HTTP {code}\n")
        return 1
    return 0


def parse_opts(args, spec, usage):
    """spec: {flag: (key, repeated)}; returns (opts, positionals)."""
    opts, pos = {}, []
    i = 0
    while i < len(args):
        a = args[i]
        if a.startswith("--"):
            flag, _, val = a.partition("=")
            if flag not in spec:
                die(f"{usage}\n  unknown option {flag}")
            key, kind = spec[flag]
            if kind == "bool":
                opts[key] = True
                i += 1
                continue
            if not _:
                i += 1
                if i >= len(args):
                    die(f"{usage}\n  {flag} needs a value")
                val = args[i]
            if kind == "list":
                opts.setdefault(key, []).append(val)
            else:
                opts[key] = val
        else:
            pos.append(a)
        i += 1
    return opts, pos


INGEST_USAGE = """\
usage: om_ingest [JSON | -]                       a CloudEvent (object) or a batch (array)
       om_ingest --type T --subject S [--id ID] [--time RFC3339] [--source SRC] [--data JSON]
       add --status to print the HTTP status instead of failing on a non-2xx"""


def cmd_ingest(args):
    opts, pos = parse_opts(args, {
        "--type": ("type", "one"), "--subject": ("subject", "one"), "--id": ("id", "one"),
        "--time": ("time", "one"), "--source": ("source", "one"), "--data": ("data", "one"),
        "--status": ("status", "bool"),
    }, INGEST_USAGE)
    fields = [k for k in ("type", "subject", "id", "time", "source", "data") if k in opts]
    if fields:
        if pos:
            die(INGEST_USAGE)
        if "type" not in opts or "subject" not in opts:
            die(INGEST_USAGE + "\n  --type and --subject are required")
        ev = {
            "specversion": "1.0",
            "id": opts.get("id") or str(uuid.uuid4()),
            "source": opts.get("source") or "rules_openmeter",
            "type": opts["type"],
            "subject": opts["subject"],
        }
        if "time" in opts:
            ev["time"] = opts["time"]
        if "data" in opts:
            try:
                ev["data"] = json.loads(opts["data"])
            except ValueError as e:
                die(f"om_ingest: --data is not JSON: {e}")
        body = json.dumps(ev)
    else:
        if len(pos) > 1:
            die(INGEST_USAGE)
        body = sys.stdin.read() if not pos or pos[0] == "-" else pos[0]
    stripped = body.lstrip()
    ctype = "application/cloudevents-batch+json" if stripped.startswith("[") else "application/cloudevents+json"
    code, text = request("POST", "/api/v1/events", body, ctype)
    if opts.get("status"):
        print(code)
        return 0
    if not 200 <= code < 300:
        die(f"om_ingest: HTTP {code}: {text.strip()}")
    return 0


QUERY_USAGE = """\
usage: om_query METER [--subject S]... [--from RFC3339] [--to RFC3339]
                [--window-size MINUTE|HOUR|DAY|MONTH] [--window-time-zone TZ]
                [--group-by KEY]... [--filter-group-by KEY=VALUE]...
                [--json | --tsv]
  prints one value per row (default), the rows as TSV
  (windowStart, windowEnd, subject, groupBy, value), or the raw JSON"""

QUERY_SPEC = {
    "--subject": ("subject", "list"), "--from": ("from", "one"), "--to": ("to", "one"),
    "--window-size": ("windowSize", "one"), "--window-time-zone": ("windowTimeZone", "one"),
    "--group-by": ("groupBy", "list"), "--filter-group-by": ("filterGroupBy", "list"),
    "--json": ("json", "bool"), "--tsv": ("tsv", "bool"),
}


def fmt_value(v):
    if isinstance(v, float) and v.is_integer():
        return str(int(v))
    return str(v)


def run_query(args):
    opts, pos = parse_opts(args, QUERY_SPEC, QUERY_USAGE)
    if len(pos) != 1:
        die(QUERY_USAGE)
    meter = pos[0]
    params = []
    for key in ("from", "to", "windowSize", "windowTimeZone"):
        if key in opts:
            params.append((key, opts[key]))
    for s in opts.get("subject", []):
        params.append(("subject", s))
    for g in opts.get("groupBy", []):
        params.append(("groupBy", g))
    for f in opts.get("filterGroupBy", []):
        k, sep, v = f.partition("=")
        if not sep:
            die(f"om_query: --filter-group-by {f!r}: expected KEY=VALUE")
        params.append((f"filterGroupBy[{k}]", v))
    path = f"/api/v1/meters/{urllib.parse.quote(meter, safe='')}/query"
    if params:
        path += "?" + urllib.parse.urlencode(params)
    code, text = request("GET", path)
    if not 200 <= code < 300:
        return None, f"om_query: GET {path}: HTTP {code}: {text.strip()}", opts
    return json.loads(text), None, opts


def render(result, opts):
    if opts.get("json"):
        return json.dumps(result, sort_keys=True)
    rows = result.get("data") or []
    rows = sorted(rows, key=lambda r: (r.get("windowStart", ""), r.get("subject") or "",
                                       json.dumps(r.get("groupBy") or {}, sort_keys=True)))
    if opts.get("tsv"):
        return "\n".join("\t".join([
            r.get("windowStart", ""), r.get("windowEnd", ""), r.get("subject") or "",
            json.dumps(r.get("groupBy") or {}, sort_keys=True), fmt_value(r.get("value")),
        ]) for r in rows)
    return "\n".join(fmt_value(r.get("value")) for r in rows)


def cmd_query(args):
    result, err, opts = run_query(args)
    if err:
        die(err)
    out = render(result, opts)
    if out:
        print(out)
    return 0


def diagnostics():
    """WARN/ERROR records from OpenMeter's logs, to tell a slow pipeline
    from a broken one."""
    out = []
    for var, what in (("OPENMETER_SERVER_LOG", "API server"), ("OPENMETER_SINK_LOG", "sink worker")):
        path = os.environ.get(var)
        if not path:
            continue
        try:
            lines = open(path, errors="replace").read().splitlines()
        except OSError:
            continue
        picked = []
        for line in lines:
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if str(rec.get("level", "")).upper() in ("WARN", "ERROR"):
                err = rec.get("error.message") or rec.get("error") or rec.get("err") or ""
                picked.append(f"    {rec.get('ts', '')} {rec.get('level')} {rec.get('msg', '')}" + (f": {err}" if err else ""))
        out.append(f"\n  {what} ({path}): " + (f"last {min(10, len(picked))} WARN/ERROR records:\n" + "\n".join(picked[-10:]) if picked else "no WARN/ERROR records"))
    return "".join(out)


def cmd_wait(args):
    if len(args) < 2:
        die("usage: om_wait_value EXPECTED METER [om_query options...]\n"
            "  polls until om_query METER ... prints EXPECTED ($OM_WAIT_TIMEOUT seconds, default 60)")
    want, rest = args[0], args[1:]
    timeout = float(os.environ.get("OM_WAIT_TIMEOUT", "60"))
    t0 = time.monotonic()
    got, err = "", None
    while True:
        result, err, opts = run_query(rest)
        if result is not None:
            got = render(result, opts)
            if got == want:
                sys.stderr.write(f"om_wait_value: {' '.join(rest)} = {want!r} after {time.monotonic() - t0:.2f}s\n")
                return 0
        if time.monotonic() - t0 >= timeout:
            last = err if err else f"printed {got!r}"
            die(f"om_wait_value: {' '.join(rest)}: {last}, not {want!r}, after {timeout:g}s" + diagnostics())
        time.sleep(0.1)


def main(argv):
    if not argv:
        die(__doc__)
    cmd, args = argv[0], argv[1:]
    if cmd == "api":
        return cmd_api(args)
    if cmd == "status":
        return cmd_api(args, status_only=True)
    if cmd == "ingest":
        return cmd_ingest(args)
    if cmd == "query":
        return cmd_query(args)
    if cmd == "wait":
        return cmd_wait(args)
    die(f"om: unknown command {cmd!r}\n" + __doc__)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
