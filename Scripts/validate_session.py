#!/usr/bin/env python3
"""Independent OPTC-1 session package checker (stdlib only).

Written from docs/cw/optc-1-contract.md and docs/cw/macos-design.md, not from
the Swift implementation. It re-implements Gray/CRC/Runner from the contract and
re-derives the layout arithmetic from the exported drawable size, so a mistake
shared by encoder and layout code would still show up here.

usage: validate_session.py <session_dir> [--allow-incomplete]

The summary/distribution section reports the observed submit -> system_present
gap. It deliberately does not impose a fixed upper bound: the contract fixes
field sources and causality, not a latency budget.
"""
import json
import re
import sys
import pathlib

FAIL = []
CHECKED = 0


def check(condition, message):
    global CHECKED
    CHECKED += 1
    if not condition:
        FAIL.append(message)


def obj(value, message):
    check(isinstance(value, dict), f"{message}: expected object, got {type(value).__name__}")
    return value if isinstance(value, dict) else {}


def load_json(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def load_jsonl(path):
    items = []
    with open(path, encoding="utf-8") as handle:
        for number, line in enumerate(handle, 1):
            check(line.endswith("\n"), f"{path.name}:{number} no trailing LF")
            text = line.strip()
            if not text:
                continue
            check(text.startswith("{") and text.endswith("}"), f"{path.name}:{number} not a JSON object")
            items.append(json.loads(text))
    return items


def crc8(payload):
    crc = 0
    for byte in (payload & 0xFF, (payload >> 8) & 0xFF):
        crc ^= byte
        for _ in range(8):
            crc = ((crc << 1) ^ 0x07) & 0xFF if crc & 0x80 else (crc << 1) & 0xFF
    return crc


def expected_modules(render_seq):
    n = render_seq % 65536
    gray = n ^ (n >> 1)
    crc = crc8(n)
    bits = [0, 1, 1, 0]
    for shift in range(15, -1, -1):
        bit = (gray >> shift) & 1
        bits += [bit, 1 - bit]
    for shift in range(7, -1, -1):
        bit = (crc >> shift) & 1
        bits += [bit, 1 - bit]
    for index in range(8):
        bit = 1 if index == n % 8 else 0
        bits += [bit, 1 - bit]
    return n, gray, crc, bits


def rotate_rect(rect, degrees, w_p, h_p):
    x0, y0, x1, y1 = rect
    points = [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]

    def mapped(point):
        x, y = point
        if degrees == 0:
            return (x, y)
        if degrees == 90:
            return (h_p - y, x)
        if degrees == 180:
            return (w_p - x, h_p - y)
        return (y, w_p - x)

    moved = [mapped(point) for point in points]
    xs = [p[0] for p in moved]
    ys = [p[1] for p in moved]
    return [min(xs), min(ys), max(xs), max(ys)]


def inside(inner, outer):
    return outer[0] <= inner[0] and outer[1] <= inner[1] and inner[2] <= outer[2] and inner[3] <= outer[3]


def intersects(a, b):
    return a[0] < b[2] and b[0] < a[2] and a[1] < b[3] and b[1] < a[3]


def validate(directory, allow_incomplete):
    manifest = obj(load_json(directory / "manifest.json"), "manifest")
    layouts = obj(load_json(directory / "layout.json"), "layout")
    profiles = obj(load_json(directory / "display_profile.json"), "display_profile")
    summary = obj(load_json(directory / "session_summary.json"), "session_summary")
    display = load_jsonl(directory / "display_events.jsonl")
    configuration = load_jsonl(directory / "configuration_events.jsonl")

    # ---- manifest ----
    check(manifest.get("schema_version") == "1.0", "schema_version")
    check(manifest.get("protocol_version") == "OPTC-1", "protocol_version")
    session_id = manifest.get("session_id", "")
    check(re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", session_id) is not None,
          "session_id is not a lowercase hyphenated UUID")
    check(manifest.get("platform") == "MACOS", "platform")
    check(manifest.get("clock_domain") == "MACOS_HOST_TIME", "clock_domain")
    check(manifest.get("presentation_drain_timeout_ns") == 2_000_000_000, "drain timeout is not 2 s")
    origin = obj(manifest.get("time_origin"), "time_origin")
    origin_ns = origin.get("raw_ns")
    check(isinstance(origin_ns, int), "time_origin.raw_ns must be an integer")
    check(origin.get("native_clock") == "MACOS_HOST_TIME", "time_origin.native_clock")
    for key in ("source_device_id", "app_id", "app_version", "app_build", "os_version", "os_build"):
        check(isinstance(manifest.get(key), str) and manifest[key] != "", f"manifest.{key} missing")

    segments = manifest.get("segments")
    check(isinstance(segments, list), "manifest.segments")
    segment_ids = []
    for segment in segments:
        segment = obj(segment, "segment")
        segment_ids.append(segment.get("segment_id"))
        check(re.fullmatch(r"0|[1-9][0-9]*", str(segment.get("segment_id"))) is not None,
              "segment_id must be a decimal string")
        check(isinstance(segment.get("layout_id"), str), "segment.layout_id")
        check(isinstance(segment.get("drawable_width_px"), int) and segment["drawable_width_px"] > 0,
              "segment.drawable_width_px")
        check(isinstance(segment.get("experiment_profile"), str), "segment.experiment_profile")
        for numerator, denominator in (("requested_refresh_num", "requested_refresh_den"),
                                       ("nominal_refresh_num", "nominal_refresh_den")):
            both = (segment.get(numerator) is None) == (segment.get(denominator) is None)
            check(both, f"segment.{numerator}/{denominator} must be both null or both set")
        check(segment.get("brightness_source") in ("SYSTEM_REPORTED", "OPERATOR_REPORTED", "UNKNOWN"),
              "segment.brightness_source")
        if segment.get("brightness_source") == "UNKNOWN":
            check(segment.get("brightness_setting") is None, "UNKNOWN brightness must be null")
        check(isinstance(segment.get("color_space"), str), "segment.color_space")
        check(isinstance(segment.get("pixel_format"), str), "segment.pixel_format")
        for nullable in ("display_mode_id", "display_rotation_deg", "reported_refresh_hz",
                         "brightness_setting", "auto_brightness_enabled", "color_mode",
                         "dimming_mode", "hdr_enabled", "true_tone_enabled",
                         "night_shift_enabled", "display_profile_id"):
            check(nullable in segment, f"segment.{nullable} must be present (explicit null allowed)")
        check(isinstance(segment.get("operator_note"), str), "segment.operator_note")
    check(len(set(segment_ids)) == len(segment_ids), "duplicate segment_id")

    # ---- layout arithmetic, re-derived from the contract ----
    layout_doc = layouts.get("layouts")
    check(isinstance(layout_doc, list), "layout.layouts")
    layout_by_id = {}
    for layout in layout_doc:
        layout = obj(layout, "layout")
        layout_id = layout.get("layout_id")
        layout_by_id[layout_id] = layout
        profile = layout.get("layout_profile")
        check(profile in ("F68", "C52"), "layout_profile")
        module_count = 68 if profile == "F68" else 52
        width = layout.get("drawable_width_px")
        height = layout.get("drawable_height_px")
        rotation = layout.get("pattern_rotation_deg")
        check(rotation in (0, 90, 180, 270), "pattern_rotation_deg")
        check(layout.get("coordinate_system") == "DRAWABLE_TOP_LEFT_PIXEL_EDGES", "coordinate_system")
        w_p, h_p = (width, height) if rotation in (0, 180) else (height, width)
        check(layout.get("pattern_width_px") == w_p, "pattern_width_px")
        check(layout.get("pattern_height_px") == h_p, "pattern_height_px")

        bw = w_p * 96 // 100
        bh = h_p * 68 // 100
        a = (w_p - bw) // 2
        c = (h_p - bh) // 2
        expected_dynamic = rotate_rect([a, c, a + bw, c + bh], rotation, w_p, h_p)
        check(layout.get("dynamic_rect_px") == expected_dynamic,
              f"dynamic_rect_px mismatch: {layout.get('dynamic_rect_px')} != {expected_dynamic}")

        modules = layout.get("modules")
        check(isinstance(modules, list) and len(modules) == module_count, "module count")
        for index, module in enumerate(modules):
            module = obj(module, "module")
            check(module.get("index") == index, "module index order")
            rect = module.get("rect_px")
            check(isinstance(rect, list) and len(rect) == 4 and all(isinstance(v, int) for v in rect),
                  "module rect_px type")
            expected = rotate_rect([a + index * bw // module_count, c,
                                    a + (index + 1) * bw // module_count, c + bh], rotation, w_p, h_p)
            check(rect == expected, f"module {index} rect mismatch: {rect} != {expected}")
            check(inside(rect, expected_dynamic), f"module {index} outside dynamic rect")
            if index:
                previous = modules[index - 1]["rect_px"]
                check(not intersects(rect, previous), f"module {index} overlaps previous")
        check(layout.get("level_low") == 32 and layout.get("level_high") == 224, "L/H defaults")

        markers = layout.get("markers")
        check(isinstance(markers, list) and len(markers) == 4, "marker count")
        for marker in markers:
            marker = obj(marker, "marker")
            check(marker.get("dictionary") == "DICT_4X4_50", "marker dictionary")
            check(marker.get("marker_size_bits") == 4, "marker_size_bits")
            check(marker.get("border_bits") == 1, "border_bits")
            cell = marker.get("cell_size_px")
            quiet = marker.get("quiet_zone_px")
            check(isinstance(cell, int) and cell >= 2, "cell_size_px")
            check(isinstance(quiet, int) and quiet >= cell, "quiet_zone_px")
            corners = marker.get("corners_px")
            check(isinstance(corners, list) and len(corners) == 4, "corners_px count")
            xs = [point[0] for point in corners]
            ys = [point[1] for point in corners]
            box = [min(xs), min(ys), max(xs), max(ys)]
            check(box[2] - box[0] == 6 * cell and box[3] - box[1] == 6 * cell, "marker size is not 6 cells")
            check(inside(box, [0, 0, width, height]), "marker outside drawable")
            check(not intersects(box, expected_dynamic), "marker overlaps dynamic area")

    for segment in segments:
        check(segment["layout_id"] in layout_by_id, "segment references unknown layout_id")

    # ---- display events ----
    required = {"event_seq", "event_type", "session_id", "segment_id", "layout_id",
                "native_frame_id", "frame_kind", "phase", "render_seq", "payload_n", "crc8",
                "recorded_raw_ns", "recorded_ns", "timestamp_status", "present_kind",
                "unconfirmed_reason", "platform_ids", "platform_timestamps",
                "target_present_raw_ns", "target_present_ns", "system_present_raw_ns",
                "system_present_ns", "submit_raw_ns", "submit_ns", "deadline_raw_ns",
                "deadline_ns", "render_complete_raw_ns", "render_complete_ns",
                "latch_raw_ns", "latch_ns"}
    status_keys = {"target_present", "system_present", "submit", "deadline", "render_complete", "latch"}
    statuses = {"VALID", "PENDING", "INVALID", "UNSUPPORTED", "NOT_APPLICABLE",
                "QUERY_FAILED", "CLOCK_DOMAIN_UNVERIFIED"}
    prefixes = sorted(status_keys)

    seqs = [event.get("event_seq") for event in display]
    check(seqs == list(range(len(display))), "display event_seq is not a contiguous prefix from 0")

    submitted_keys = set()
    last_present_by_key = {}
    deltas = []
    render_complete_valid = 0
    for event in display:
        for key in required:
            check(key in event, f"display event missing {key}")
        check(event.get("event_type") in ("SUBMITTED", "PRESENTED", "UNCONFIRMED"), "event_type")
        check(event.get("session_id") == session_id, "event session mismatch")
        check(event.get("segment_id") in segment_ids, "event segment not in manifest")
        check(event.get("layout_id") in layout_by_id, "event layout not exported")
        check(re.fullmatch(r"0|[1-9][0-9]*", str(event.get("native_frame_id"))) is not None,
              "native_frame_id must be a decimal string")
        kind = event.get("frame_kind")
        check(kind in ("WARMUP", "SESSION_CARD", "DYNAMIC", "END_CARD", "CALIBRATION"), "frame_kind")
        if kind == "DYNAMIC":
            check(isinstance(event.get("render_seq"), str), "render_seq must be a string, not a number")
            check(event.get("payload_n") is not None and event.get("crc8") is not None,
                  "DYNAMIC frame must carry payload_n and crc8")
            render_seq = int(event["render_seq"])
            payload, gray, crc, bits = expected_modules(render_seq)
            check(event["payload_n"] == payload, f"payload_n mismatch for render_seq {render_seq}")
            check(event["crc8"] == crc, f"crc8 mismatch for render_seq {render_seq}")
        else:
            check(event.get("render_seq") is None and event.get("payload_n") is None
                  and event.get("crc8") is None, "non-dynamic frame carries encoding fields")

        status = obj(event.get("timestamp_status"), "timestamp_status")
        check(set(status.keys()) == status_keys, "timestamp_status keys")
        for field in status_keys:
            check(status[field] in statuses, f"status value {status[field]}")
        for prefix in prefixes:
            raw = event[f"{prefix}_raw_ns"]
            relative = event[f"{prefix}_ns"]
            if status[prefix] == "VALID":
                check(isinstance(raw, int) and isinstance(relative, int), f"{prefix} VALID without ns")
                check(relative == raw - origin_ns, f"{prefix}_ns != raw - origin")
            else:
                check(raw is None and relative is None, f"{prefix} non-VALID with ns")
        check(isinstance(event["recorded_raw_ns"], int) and isinstance(event["recorded_ns"], int),
              "recorded always valid")
        check(event["recorded_ns"] == event["recorded_raw_ns"] - origin_ns, "recorded_ns")

        platform = obj(event.get("platform_timestamps"), "platform_timestamps")
        check(set(platform.keys()) == status_keys, "platform_timestamps keys")
        for field in status_keys:
            entry = obj(platform[field], "platform timestamp entry")
            for key in ("api", "native_value", "native_unit", "native_clock_domain", "query_error_code"):
                check(key in entry, f"platform_timestamps.{field} missing {key}")
            check(isinstance(entry["api"], str), f"platform_timestamps.{field}.api")
            check(entry["native_unit"] in (None, "NS", "SECONDS"), "native_unit")

        if status["render_complete"] == "VALID":
            entry = obj(platform["render_complete"], "render_complete platform entry")
            check(entry.get("api") == "MTLCommandBuffer.gpuEndTime",
                  "render_complete VALID must come from MTLCommandBuffer.gpuEndTime")
            check(entry.get("native_unit") == "SECONDS", "GPU end time must keep its native seconds")
            check(isinstance(entry.get("native_value"), (int, float)),
                  "GPU end time must keep the raw native value")
            render_complete_valid += 1

        ids = obj(event.get("platform_ids"), "platform_ids")
        check(set(ids.keys()) == {"surface_instance_id", "egl_frame_id", "vsync_id", "drawable_id"},
              "platform_ids keys")

        key = (event.get("segment_id"), event.get("native_frame_id"))
        if event["event_type"] == "SUBMITTED":
            submitted_keys.add(key)
            check(event.get("present_kind") is None, "SUBMITTED must not claim present_kind")
            check(event.get("unconfirmed_reason") is None, "SUBMITTED must not carry reason")
        else:
            check(key in submitted_keys, f"result event before SUBMITTED for {key}")
        if event["event_type"] == "PRESENTED":
            check(event.get("present_kind") == "SYSTEM_REPORTED", "PRESENTED present_kind")
            check(status["system_present"] == "VALID", "PRESENTED without VALID system_present")
            check(event.get("unconfirmed_reason") is None, "PRESENTED carries reason")
            submit = event.get("submit_ns")
            present = event.get("system_present_ns")
            if isinstance(submit, int) and isinstance(present, int):
                # Causality only: a real presentation cannot precede the submit
                # sample. The actual distribution is reported, not capped.
                check(present >= submit, f"system_present before submit: {present - submit} ns")
                deltas.append(present - submit)
            last_present_by_key[key] = present
        if event["event_type"] == "UNCONFIRMED":
            check(event.get("present_kind") == "UNCONFIRMED", "UNCONFIRMED present_kind")
            check(event.get("unconfirmed_reason") is not None, "UNCONFIRMED needs a reason")
            check(status["system_present"] != "VALID", "UNCONFIRMED with VALID system_present")

    # ---- configuration events ----
    config_required = {"event_seq", "event_type", "session_id", "segment_id", "recorded_raw_ns",
                       "recorded_ns", "details"}
    config_seqs = [event.get("event_seq") for event in configuration]
    check(config_seqs == list(range(len(configuration))),
          "configuration event_seq is not a contiguous prefix from 0")
    for event in configuration:
        for key in config_required:
            check(key in event, f"configuration event missing {key}")
        check(event["session_id"] == session_id, "configuration session mismatch")
        check(isinstance(event["details"], dict), "details")
        check(event["recorded_ns"] == event["recorded_raw_ns"] - origin_ns, "configuration recorded_ns")
        if event["event_type"] == "SEGMENT_STARTED":
            config = obj(event["details"]["configuration"], "segment configuration")
            check(config.get("segment_id") == event.get("segment_id"), "SEGMENT_STARTED segment mismatch")
            check(event["details"].get("reason") in ("SESSION_START", "RESUME", "CONFIGURATION_CHANGED"),
                  "segment start reason")
        if event["event_type"] == "SEGMENT_ENDED":
            check(event["details"].get("reason") in (
                "NORMAL_END", "PAUSED", "BACKGROUND", "FULLSCREEN_EXIT", "SYSTEM_SLEEP",
                "DISPLAY_CHANGED", "SURFACE_CHANGED", "CONFIGURATION_CHANGED", "LOG_OVERFLOW",
                "RENDER_FAILURE", "USER_STOP"), "segment end reason")
        if event["event_type"] == "LOG_OVERFLOW":
            details = event["details"]
            check(details.get("affected_log") in ("display_events.jsonl", "configuration_events.jsonl"),
                  "affected_log")
            check(isinstance(details.get("affected_segment_ids"), list), "affected_segment_ids")
            check(isinstance(details.get("first_lost_event_seq"), int)
                  and isinstance(details.get("last_lost_event_seq"), int), "lost range")
            check(isinstance(details.get("lost_event_count"), int) and details["lost_event_count"] > 0,
                  "lost_event_count")
    check(configuration and configuration[-1]["event_type"] == "SESSION_CLOSED",
          "SESSION_CLOSED must be the last configuration event")
    close = configuration[-1]["details"]
    check(close.get("reason") in ("NORMAL_END", "USER_STOP", "LOG_OVERFLOW", "RENDER_FAILURE"), "close reason")
    check(close.get("data_integrity") in ("COMPLETE", "INCOMPLETE"), "close integrity")
    check(isinstance(close.get("pending_frame_count"), int), "pending_frame_count")

    # ---- display_profile ----
    check(profiles.get("schema_version") == "1.0", "display_profile schema")
    check(isinstance(profiles.get("profiles"), list), "display_profile.profiles")
    bindings = profiles.get("segment_bindings")
    check(isinstance(bindings, list) and len(bindings) == len(segments), "one binding per segment")
    for binding in bindings or []:
        binding = obj(binding, "binding")
        check(binding.get("segment_id") in segment_ids, "binding segment id")
        check(binding.get("status") in ("MISSING", "IMPORTED_UNVERIFIED", "COMPATIBLE", "INCOMPATIBLE"),
              "binding status")
        check(isinstance(binding.get("mismatch_fields"), list), "mismatch_fields")
        if binding.get("status") == "MISSING":
            check(binding.get("profile_id") is None, "MISSING binding must not reference a profile")
    known_profiles = {profile.get("profile_id") for profile in profiles.get("profiles", [])}
    for binding in bindings or []:
        if binding.get("profile_id") is not None:
            check(binding["profile_id"] in known_profiles, "binding references an unexported profile")
    if allow_incomplete:
        if deltas:
            ordered = sorted(deltas)
            median = ordered[len(ordered) // 2]
            print(f"submit->system_present ns: n={len(ordered)} min={ordered[0]} p50={median} max={ordered[-1]}")
        return
    # ---- summary, only meaningful for a complete package ----
    check(summary.get("session_id") == session_id, "summary session id")
    check(summary.get("data_integrity") == "COMPLETE", "summary integrity")
    check(summary.get("lost_event_count") == 0, "summary lost count")
    check(summary.get("closed_raw_ns") == configuration[-1]["recorded_raw_ns"], "summary close time")
    check(summary.get("closed_ns") == summary.get("closed_raw_ns") - origin_ns, "summary closed_ns")
    per_segment = {}
    for event in display:
        key = (event["segment_id"], event["native_frame_id"])
        record = per_segment.setdefault(key[0], {"generated": set(), "submitted": set(),
                                                 "presented": set(), "unconfirmed": set()})
        record["generated"].add(key)
        if event["event_type"] == "SUBMITTED":
            record["submitted"].add(key)
        if event["event_type"] == "PRESENTED":
            record["presented"].add(key)
            record["unconfirmed"].discard(key)
        if event["event_type"] == "UNCONFIRMED" and key not in record["presented"]:
            record["unconfirmed"].add(key)
    summary_by_segment = {item["segment_id"]: item for item in summary.get("segments", [])}
    check(set(summary_by_segment.keys()) == set(segment_ids), "summary segment set")
    for segment_id, record in per_segment.items():
        item = summary_by_segment.get(segment_id)
        check(item is not None, f"summary missing segment {segment_id}")
        if item is None:
            continue
        check(item.get("generated") == len(record["generated"]), f"generated count for {segment_id}")
        check(item.get("submitted") == len(record["submitted"]), f"submitted count for {segment_id}")
        check(item.get("presented") == len(record["presented"]), f"presented count for {segment_id}")
        check(item.get("unconfirmed") == len(record["unconfirmed"]), f"unconfirmed count for {segment_id}")
    unconfirmed_keys = {key for key in submitted_keys if key not in last_present_by_key}
    check(close["pending_frame_count"] == len(unconfirmed_keys), "pending_frame_count mismatch")
    check(summary.get("data_integrity") == close["data_integrity"], "summary/close integrity mismatch")
    timing = summary.get("timing")
    if isinstance(timing, dict):
        for name, distribution in timing.items():
            distribution = obj(distribution, f"timing.{name}")
            check(distribution.get("count", 0) > 0, f"timing.{name}.count")
            for key in ("min", "p50", "p90", "max"):
                check(isinstance(distribution.get(key), int), f"timing.{name}.{key} must be an integer")
            check(distribution["min"] <= distribution["p50"] <= distribution["p90"] <= distribution["max"],
                  f"timing.{name} quantiles are not ordered")
    check(render_complete_valid > 0, "no VALID render_complete evidence in the session")
    if deltas:
        ordered = sorted(deltas)
        median = ordered[len(ordered) // 2]
        print(f"submit->system_present ns: n={len(ordered)} min={ordered[0]} p50={median} max={ordered[-1]}")


def main():
    args = [arg for arg in sys.argv[1:] if not arg.startswith("--")]
    allow_incomplete = "--allow-incomplete" in sys.argv[1:]
    if len(args) != 1:
        print(__doc__)
        return 2
    directory = pathlib.Path(args[0])
    names = sorted(path.name for path in directory.iterdir() if path.is_file())
    expected = sorted(["manifest.json", "layout.json", "display_events.jsonl",
                       "configuration_events.jsonl", "display_profile.json", "session_summary.json"])
    if names != expected:
        FAIL.append(f"file set mismatch: {names}")
    validate(directory, allow_incomplete)
    if FAIL:
        print(f"FAIL {len(FAIL)} of {CHECKED} checks")
        for problem in FAIL[:25]:
            print(" -", problem)
        return 1
    print(f"OK {CHECKED} checks: {directory}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
