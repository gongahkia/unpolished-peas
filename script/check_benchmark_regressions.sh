#!/bin/sh
set -eu

root="$(git rev-parse --show-toplevel)"
thresholds="${BENCHMARK_THRESHOLDS:-$root/contracts/benchmark_regression_thresholds.json}"
results_dir="${BENCHMARK_RESULTS_DIR:-}"

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

[ -f "$thresholds" ] || fail "missing benchmark regression thresholds"
if [ -z "$results_dir" ]; then
    results_dir="$(mktemp -d)"
    trap 'rm -rf "$results_dir"' EXIT
    zig build benchmark-authoritative -Doptimize=ReleaseFast > "$results_dir/authoritative.json"
    zig build benchmark-sharded-p2p -Doptimize=ReleaseFast > "$results_dir/sharded.json"
    zig build benchmark-topology-faults -Doptimize=ReleaseFast > "$results_dir/topology_faults.json"
    zig build benchmark-throughput -Doptimize=ReleaseFast > "$results_dir/throughput.json"
    zig build benchmark-memory -Doptimize=ReleaseFast > "$results_dir/memory.json"
fi

python3 - "$thresholds" "$results_dir" <<'PY'
import json
import pathlib
import sys

thresholds_path = pathlib.Path(sys.argv[1])
results_dir = pathlib.Path(sys.argv[2])

try:
    thresholds = json.loads(thresholds_path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as error:
    raise SystemExit(f"invalid benchmark regression thresholds: {error}")

if thresholds.get("schema_version") != 1:
    raise SystemExit("unsupported benchmark regression threshold schema")

def load(name):
    path = results_dir / f"{name}.json"
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"invalid {name} benchmark result: {error}")
    if value.get("schema_version") != 1:
        raise SystemExit(f"unsupported {name} benchmark result schema")
    return value

def integer(record, field):
    value = record.get(field)
    if isinstance(value, bool) or not isinstance(value, int):
        raise SystemExit(f"missing integer benchmark field: {field}")
    return value

def exact(name, record, limits, field):
    actual = integer(record, field)
    expected = integer(limits, field)
    if actual != expected:
        raise SystemExit(f"{name} regression: {field} expected {expected}, found {actual}")

def minimum(name, record, limits, field):
    actual = integer(record, field)
    expected = integer(limits, f"{field}_min")
    if actual < expected:
        raise SystemExit(f"{name} regression: {field} minimum {expected}, found {actual}")

def maximum(name, record, limits, field):
    actual = integer(record, field)
    expected = integer(limits, f"{field}_max")
    if actual > expected:
        raise SystemExit(f"{name} regression: {field} maximum {expected}, found {actual}")

authoritative = load("authoritative")
limits = thresholds["authoritative"]
for field in ("peers", "route_operations", "lost_messages", "recovered_messages", "fanout_messages", "checksum"):
    exact("authoritative", authoritative, limits, field)
maximum("authoritative", authoritative, limits, "virtual_latency_ns")
maximum("authoritative", authoritative, limits, "peak_tracked_bytes")
if integer(authoritative, "lost_messages") != integer(authoritative, "recovered_messages"):
    raise SystemExit("authoritative regression: lost messages are not recovered")

sharded = load("sharded")
limits = thresholds["sharded"]
for field in ("peers", "groups", "shard_memberships", "candidate_checks", "signals", "checksum"):
    exact("sharded", sharded, limits, field)
for field in ("direct_routes", "relay_routes"):
    minimum("sharded", sharded, limits, field)
maximum("sharded", sharded, limits, "peak_tracked_bytes")

topology_faults = load("topology_faults")
limits = thresholds["topology_faults"]
for field in ("packets", "delayed_authoritative", "delayed_p2p", "lost_authoritative", "lost_p2p", "reordered_authoritative", "reordered_p2p", "partitioned_authoritative", "partitioned_p2p", "relay_authoritative", "relay_p2p", "relay_fallbacks", "checksum"):
    exact("topology faults", topology_faults, limits, field)

throughput = load("throughput")
limits = thresholds["throughput"]
for field in ("payload_admitted_bytes", "throughput_bytes_per_second"):
    minimum("throughput", throughput, limits, field)
for field in ("paced_bytes", "pacing_deferrals", "congestion_window_bytes", "congestion_loss_events", "queue_saturations", "bandwidth_limited_bytes", "checksum"):
    exact("throughput", throughput, limits, field)
maximum("throughput", throughput, limits, "compressed_wire_bytes")

memory = load("memory")
limits = thresholds["memory"]
for field in ("peers", "groups", "routes_per_group", "checksum"):
    exact("memory", memory, limits, field)
for field in ("peer_total_bytes", "group_total_bytes", "route_total_bytes", "capture_bytes", "replay_bytes", "reassembly_bytes"):
    maximum("memory", memory, limits, field)
PY
