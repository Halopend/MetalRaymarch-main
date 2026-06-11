#!/usr/bin/env python3

import argparse
import os
import statistics
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from typing import Dict, Iterable, List, Optional, Tuple


NS_PER_MS = 1_000_000


@dataclass
class IntervalRow:
    start_ns: int
    duration_ns: int
    process_fmt: str
    thread_fmt: str
    event_type_fmt: str
    label_fmt: str
    object_label_fmt: str
    depth: int


@dataclass
class GPUIntervalRow:
    start_ns: int
    duration_ns: int
    latency_ns: int
    channel_fmt: str
    frame_fmt: str
    process_fmt: str
    label_fmt: str
    depth: int


def _fmt_to_int(text: Optional[str], default: int = 0) -> int:
    if text is None:
        return default
    try:
        return int(text)
    except ValueError:
        return default


def export_schema(trace_path: str, schema: str, run_number: int = 1) -> str:
    xpath = f'/trace-toc/run[@number="{run_number}"]/data/table[@schema="{schema}"]'

    fd, out_path = tempfile.mkstemp(prefix=f"xctrace_{schema}_", suffix=".xml")
    os.close(fd)

    cmd = [
        "xcrun",
        "xctrace",
        "export",
        "--input",
        trace_path,
        "--xpath",
        xpath,
        "--output",
        out_path,
    ]

    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if proc.returncode != 0:
        try:
            os.unlink(out_path)
        except OSError:
            pass
        raise RuntimeError(
            f"xctrace export failed for schema={schema} (code {proc.returncode})\n"
            f"stderr:\n{proc.stderr.strip()}"
        )

    return out_path


def iter_metal_application_intervals(xml_path: str) -> Iterable[IntervalRow]:
    # Streaming parse to handle big XML files.
    context = ET.iterparse(xml_path, events=("end",))

    # xctrace export uses <tag id="X" fmt="..."> then later <tag ref="X"/>.
    # Cache fmt strings by (tag, id) so we can resolve refs while streaming.
    fmt_cache: Dict[Tuple[str, str], str] = {}

    for event, elem in context:
        # Cache any element that defines an id+fmt, so later ref nodes can resolve.
        elem_id = elem.get("id")
        elem_fmt = elem.get("fmt")
        if elem_id and elem_fmt:
            fmt_cache[(elem.tag, elem_id)] = elem_fmt

        if elem.tag != "row":
            continue

        start_ns = 0
        duration_ns = 0
        process_fmt = ""
        thread_fmt = ""
        event_type_fmt = ""
        label_fmt = ""
        object_label_fmt = ""
        depth = 0

        # Children are typed nodes like <start-time>, <duration>, <process>, <formatted-label>, ...
        for child in list(elem):
            tag = child.tag
            # Resolve referenced nodes like <process ref="3"/> to their cached fmt.
            ref = child.get("ref")
            if ref and not child.get("fmt"):
                cached = fmt_cache.get((tag, ref))
                if cached is not None:
                    child.set("fmt", cached)

            if tag == "start-time":
                start_ns = _fmt_to_int(child.text)
            elif tag == "duration":
                duration_ns = _fmt_to_int(child.text)
            elif tag == "process":
                process_fmt = child.get("fmt") or ""
            elif tag == "thread":
                thread_fmt = child.get("fmt") or ""
            elif tag == "metal-event-name":
                event_type_fmt = child.get("fmt") or ""
            elif tag == "metal-nesting-level":
                depth = _fmt_to_int(child.text)
            elif tag == "formatted-label":
                label_fmt = child.get("fmt") or ""
                # Often contains a nested <metal-object-label> that is a nicer grouping key
                for sub in list(child):
                    sub_ref = sub.get("ref")
                    if sub_ref and not sub.get("fmt"):
                        cached = fmt_cache.get((sub.tag, sub_ref))
                        if cached is not None:
                            sub.set("fmt", cached)
                    if sub.tag == "metal-object-label":
                        object_label_fmt = sub.get("fmt") or (sub.text or "")
                        break

        yield IntervalRow(
            start_ns=start_ns,
            duration_ns=duration_ns,
            process_fmt=process_fmt,
            thread_fmt=thread_fmt,
            event_type_fmt=event_type_fmt,
            label_fmt=label_fmt,
            object_label_fmt=object_label_fmt,
            depth=depth,
        )

        # Clear to keep memory bounded
        elem.clear()


def iter_metal_gpu_intervals(xml_path: str) -> Iterable[GPUIntervalRow]:
    context = ET.iterparse(xml_path, events=("end",))
    fmt_cache: Dict[Tuple[str, str], str] = {}

    for _event, elem in context:
        elem_id = elem.get("id")
        elem_fmt = elem.get("fmt")
        if elem_id and elem_fmt:
            fmt_cache[(elem.tag, elem_id)] = elem_fmt

        if elem.tag != "row":
            continue

        start_ns = 0
        duration_ns = 0
        latency_ns = 0
        channel_fmt = ""
        frame_fmt = ""
        process_fmt = ""
        label_fmt = ""
        depth = 0

        duration_seen = 0
        formatted_label_seen = 0

        for child in list(elem):
            tag = child.tag
            ref = child.get("ref")
            if ref and not child.get("fmt"):
                cached = fmt_cache.get((tag, ref))
                if cached is not None:
                    child.set("fmt", cached)

            if tag == "start-time":
                start_ns = _fmt_to_int(child.text)
            elif tag == "duration":
                # metal-gpu-intervals has TWO duration columns: (1) Duration, (2) CPU→GPU Latency.
                duration_seen += 1
                if duration_seen == 1:
                    duration_ns = _fmt_to_int(child.text)
                elif duration_seen == 2:
                    latency_ns = _fmt_to_int(child.text)
            elif tag == "gpu-channel-name":
                channel_fmt = child.get("fmt") or ""
            elif tag == "gpu-frame-number":
                frame_fmt = child.get("fmt") or ""
            elif tag == "process":
                process_fmt = child.get("fmt") or ""
            elif tag == "formatted-label":
                formatted_label_seen += 1
                # metal-gpu-intervals has TWO formatted-label columns:
                # (1) event label, (2) IOSurface accesses. Keep the first as the primary label.
                if formatted_label_seen == 1:
                    label_fmt = child.get("fmt") or ""
            elif tag == "metal-nesting-level":
                depth = _fmt_to_int(child.text)

        yield GPUIntervalRow(
            start_ns=start_ns,
            duration_ns=duration_ns,
            latency_ns=latency_ns,
            channel_fmt=channel_fmt,
            frame_fmt=frame_fmt,
            process_fmt=process_fmt,
            label_fmt=label_fmt,
            depth=depth,
        )

        elem.clear()


def percentile(values: List[float], p: float) -> float:
    if not values:
        return 0.0
    values_sorted = sorted(values)
    if len(values_sorted) == 1:
        return values_sorted[0]
    k = (len(values_sorted) - 1) * p
    f = int(k)
    c = min(f + 1, len(values_sorted) - 1)
    if f == c:
        return values_sorted[f]
    d0 = values_sorted[f] * (c - k)
    d1 = values_sorted[c] * (k - f)
    return d0 + d1


def summarize_metal_application_intervals(
    xml_path: str,
    process_contains: Optional[str],
    label_contains: Optional[str],
    min_ms: float,
    top_n: int,
) -> None:
    groups: Dict[Tuple[str, str, int], List[float]] = {}
    worst: List[Tuple[float, IntervalRow]] = []

    total_rows = 0
    kept_rows = 0

    for row in iter_metal_application_intervals(xml_path):
        total_rows += 1
        if process_contains and process_contains not in row.process_fmt:
            continue
        ms = row.duration_ns / NS_PER_MS
        if ms < min_ms:
            continue

        if label_contains:
            label_for_filter = row.object_label_fmt or row.label_fmt
            if label_contains not in label_for_filter:
                continue
        kept_rows += 1

        key_label = row.object_label_fmt or row.label_fmt or "(unknown)"
        key = (row.event_type_fmt or "", key_label, row.depth)
        groups.setdefault(key, []).append(ms)

        worst.append((ms, row))

    print(f"Rows: {total_rows} (filtered: {kept_rows})")

    # Group summary
    def group_key(item):
        (_k, values) = item
        return (max(values), statistics.fmean(values), len(values))

    sorted_groups = sorted(groups.items(), key=group_key, reverse=True)
    print("\nTop groups by max duration:")
    for (etype, label, depth), values in sorted_groups[:top_n]:
        values_sorted = sorted(values)
        print(
            f"- max={values_sorted[-1]:8.2f}ms  p95={percentile(values_sorted, 0.95):8.2f}ms  "
            f"avg={statistics.fmean(values_sorted):8.2f}ms  n={len(values_sorted):5d}  "
            f"depth={depth:2d}  type={etype:10s}  label={label}"
        )

    # Worst individual events
    worst.sort(key=lambda x: x[0], reverse=True)
    print("\nWorst individual intervals:")
    for ms, row in worst[:top_n]:
        label = row.object_label_fmt or row.label_fmt
        print(
            f"- {ms:8.2f}ms  type={row.event_type_fmt:10s} depth={row.depth:2d}  "
            f"label={label}  thread={row.thread_fmt}"
        )


def summarize_metal_gpu_intervals(
    xml_path: str,
    process_contains: Optional[str],
    label_contains: Optional[str],
    min_ms: float,
    top_n: int,
) -> None:
    groups: Dict[Tuple[str, str], List[float]] = {}
    latency_groups: Dict[Tuple[str, str], List[float]] = {}
    worst: List[Tuple[float, GPUIntervalRow]] = []

    total_rows = 0
    kept_rows = 0

    for row in iter_metal_gpu_intervals(xml_path):
        total_rows += 1
        if process_contains and process_contains not in row.process_fmt:
            continue
        ms = row.duration_ns / NS_PER_MS
        if ms < min_ms:
            continue

        if label_contains and label_contains not in (row.label_fmt or ""):
            continue
        kept_rows += 1

        label = row.label_fmt or "(unknown)"
        key = (row.channel_fmt or "", label)
        groups.setdefault(key, []).append(ms)

        latency_ms = row.latency_ns / NS_PER_MS
        if latency_ms > 0:
            latency_groups.setdefault(key, []).append(latency_ms)

        worst.append((ms, row))

    print(f"Rows: {total_rows} (filtered: {kept_rows})")

    def group_key(item):
        (_k, values) = item
        return (max(values), statistics.fmean(values), len(values))

    sorted_groups = sorted(groups.items(), key=group_key, reverse=True)
    print("\nTop GPU groups by max duration:")
    for (channel, label), values in sorted_groups[:top_n]:
        values_sorted = sorted(values)
        p95 = percentile(values_sorted, 0.95)
        avg = statistics.fmean(values_sorted)

        lat = latency_groups.get((channel, label), [])
        lat_note = ""
        if lat:
            lat_sorted = sorted(lat)
            lat_note = f"  latency(p95)={percentile(lat_sorted, 0.95):.2f}ms"

        print(
            f"- max={values_sorted[-1]:8.2f}ms  p95={p95:8.2f}ms  avg={avg:8.2f}ms  n={len(values_sorted):5d}  channel={channel:8s}  label={label}{lat_note}"
        )

    worst.sort(key=lambda x: x[0], reverse=True)
    print("\nWorst individual GPU intervals:")
    for ms, row in worst[:top_n]:
        print(
            f"- {ms:8.2f}ms  channel={row.channel_fmt:8s} depth={row.depth:2d} frame={row.frame_fmt:10s}  label={row.label_fmt}"
        )


def main() -> int:
    ap = argparse.ArgumentParser(description="Summarize Xcode Instruments .trace performance data")
    ap.add_argument("trace", help="Path to .trace bundle")
    ap.add_argument("--run", type=int, default=1, help="Run number within trace (default: 1)")
    ap.add_argument(
        "--schema",
        default="metal-application-intervals",
        help="Schema to export and summarize (default: metal-application-intervals)",
    )
    ap.add_argument(
        "--process-contains",
        default="MetalRaymarch",
        help="Only include rows whose process fmt contains this string (default: MetalRaymarch)",
    )
    ap.add_argument("--min-ms", type=float, default=0.05, help="Ignore intervals shorter than this (ms)")
    ap.add_argument("--top", type=int, default=20, help="How many items to print")
    ap.add_argument(
        "--label-contains",
        default=None,
        help="Only include rows whose label contains this substring (useful to focus on a pass)",
    )

    args = ap.parse_args()

    trace_path = args.trace
    if not os.path.exists(trace_path):
        print(f"Trace not found: {trace_path}", file=sys.stderr)
        return 2

    xml_path = export_schema(trace_path=trace_path, schema=args.schema, run_number=args.run)
    try:
        if args.schema == "metal-application-intervals":
            summarize_metal_application_intervals(
                xml_path=xml_path,
                process_contains=args.process_contains,
                label_contains=args.label_contains,
                min_ms=args.min_ms,
                top_n=args.top,
            )
        elif args.schema == "metal-gpu-intervals":
            summarize_metal_gpu_intervals(
                xml_path=xml_path,
                process_contains=args.process_contains,
                label_contains=args.label_contains,
                min_ms=args.min_ms,
                top_n=args.top,
            )
        else:
            print(
                "Schema supported for now: metal-application-intervals, metal-gpu-intervals "
                f"(got {args.schema})"
            )
            return 3
    finally:
        try:
            os.unlink(xml_path)
        except OSError:
            pass

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
