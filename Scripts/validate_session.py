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
    schema = manifest.get("schema_version")
    check(schema in ("1.0", "1.1", "1.2"), "schema_version")
    check(layouts.get("schema_version") == schema, "layout schema matches manifest")
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
        width = layout.get("drawable_width_px")
        height = layout.get("drawable_height_px")
        rotation = layout.get("pattern_rotation_deg")
        valid_size = type(width) is int and type(height) is int and width > 0 and height > 0
        check(valid_size, "positive integer drawable dimensions")
        valid_rotation = type(rotation) is int and rotation in (0, 90, 180, 270)
        check(valid_rotation, "pattern_rotation_deg")
        check(isinstance(layout_id, str) and bool(layout_id), "nonempty layout_id")
        if not valid_size or not valid_rotation:
            continue
        check(layout.get("coordinate_system") == "DRAWABLE_TOP_LEFT_PIXEL_EDGES", "coordinate_system")
        w_p, h_p = (width, height) if rotation in (0, 180) else (height, width)
        check(type(layout.get("pattern_width_px")) is int and layout["pattern_width_px"] == w_p, "pattern_width_px")
        check(type(layout.get("pattern_height_px")) is int and layout["pattern_height_px"] == h_p, "pattern_height_px")

        kind = layout.get("layout_type", "OPTC" if schema in ("1.0", "1.1") else None)
        check(kind in ("OPTC", "CALIBRATION_TARGET", "FULLSCREEN_DIAGNOSTIC"), "layout_type required/known")
        if schema in ("1.0", "1.1"):
            check(kind == "OPTC", "legacy schema only supports OPTC")
        matrix = {0: [[1, 0, 0], [0, 1, 0], [0, 0, 1]],
                  90: [[0, -1, h_p], [1, 0, 0], [0, 0, 1]],
                  180: [[-1, 0, w_p], [0, -1, h_p], [0, 0, 1]],
                  270: [[0, 1, 0], [-1, 0, w_p], [0, 0, 1]]}
        value = layout.get("pattern_to_drawable")
        check(isinstance(value, list) and len(value) == 3
              and all(isinstance(row, list) and len(row) == 3
                      and all(type(n) in (int, float) for n in row) for row in value)
              and value == matrix[rotation], "pattern_to_drawable pure rotation")
        if kind != "OPTC":
            forbidden = {"layout_profile", "geometry_profile", "grid_rows", "grid_cols", "module_count",
                         "padding_count", "module_order", "sampling_inner_fraction", "modules", "padding", "dynamic_rect_px"}
            check(not forbidden.intersection(layout), "non-OPTC contains payload geometry")
            if kind == "FULLSCREEN_DIAGNOSTIC":
                check("markers" not in layout and "reference_regions" not in layout, "fullscreen has no markers/reference regions")
                check(layout.get("diagnostic_pattern") in ("WHITE", "BLACK", "CHECKERBOARD_2X2", "VSYNC_BLACK_WHITE"), "diagnostic_pattern")
                check(type(layout.get("level_low")) is int and layout["level_low"] == 0
                      and type(layout.get("level_high")) is int and layout["level_high"] == 255, "diagnostic levels")
            elif kind == "CALIBRATION_TARGET":
                markers = layout.get("markers", [])
                check(isinstance(markers, list) and [m.get("id") for m in markers] == [0, 1, 2, 3], "target four original IDs")
                protected = []
                run_cell = max(1, min(w_p, h_p) // 64)
                run_margin = (h_p - h_p * 68 // 100) // 2
                while run_cell > 1 and 9 * run_cell > run_margin:
                    run_cell //= 2
                for marker in markers:
                    cell, quiet = marker.get("cell_size_px"), marker.get("quiet_zone_px")
                    valid_cell = type(cell) is int and cell >= 2 and type(quiet) is int and quiet >= cell
                    check(valid_cell, "target cell/quiet")
                    if not valid_cell:
                        continue
                    check(cell == 3 * run_cell, "Mac target fixed 3x RUN cell")
                    check(marker.get("dictionary") == "DICT_4X4_50" and marker.get("border_bits") == 1
                          and marker.get("marker_size_bits") == 4, "target dictionary/border")
                    points = marker.get("corners_px", [])
                    check(len(points) == 4 and all(len(v) == 2 and all(type(n) is int for n in v) for v in points), "target corners")
                    xs, ys = [v[0] for v in points], [v[1] for v in points]
                    box = [min(xs), min(ys), max(xs), max(ys)]
                    check(box[2]-box[0] == 6*cell and box[3]-box[1] == 6*cell, "target black edge")
                    outer = [box[0]-quiet, box[1]-quiet, box[2]+quiet, box[3]+quiet]
                    check(inside(outer, [0, 0, width, height]), "target quiet inside drawable")
                    check(all(not intersects(outer, other) for other in protected), "target quiet nonoverlap")
                    protected.append(outer)
                refs = layout.get("reference_regions", [])
                check(isinstance(refs, list) and len(refs) > 0, "target references nonempty")
                ref_rects = []
                for index, patch in enumerate(refs):
                    check(type(patch.get("index")) is int and patch["index"] == index, "reference index")
                    rect = patch.get("rect_px")
                    check(isinstance(rect, list) and len(rect) == 4 and all(type(n) is int for n in rect), "reference rect type")
                    check(rect[0] < rect[2] and rect[1] < rect[3] and inside(rect, [0, 0, width, height]), "reference positive/inside")
                    check(type(patch.get("level")) is int and 0 <= patch["level"] <= 255, "reference code")
                    check(all(not intersects(rect, other) for other in protected + ref_rects), "reference quiet/reference nonoverlap")
                    ref_rects.append(rect)
            continue

        profile = layout.get("layout_profile")
        check(profile in ("F68", "C52"), "layout_profile")
        module_count = 68 if profile == "F68" else 52
        bw = w_p * 96 // 100
        bh = h_p * 68 // 100
        a = (w_p - bw) // 2
        c = (h_p - bh) // 2
        expected_dynamic = rotate_rect([a, c, a + bw, c + bh], rotation, w_p, h_p)
        check(layout.get("dynamic_rect_px") == expected_dynamic,
              f"dynamic_rect_px mismatch: {layout.get('dynamic_rect_px')} != {expected_dynamic}")

        shapes = {"F68": ("F68", 1, 68), "C52": ("C52", 1, 52),
                  "F68-G6x12": ("F68", 6, 12), "C52-G5x12": ("C52", 5, 12),
                  "F68-G9x8": ("F68", 9, 8), "C52-G9x6": ("C52", 9, 6)}
        extension = {"geometry_profile", "grid_rows", "grid_cols", "module_count",
                     "padding_count", "module_order", "sampling_inner_fraction", "padding"}
        present = extension.intersection(layout)
        if schema == "1.0" and not present:
            geometry, rows, cols, padding = profile, 1, module_count, []
        else:
            check(present == extension, "complete layout extension required")
            geometry = layout.get("geometry_profile")
            check(geometry in shapes, "unknown geometry_profile")
            if present != extension or geometry not in shapes:
                continue
            payload, rows, cols = shapes[geometry]
            check(profile == payload, "geometry/layout_profile mismatch")
            for field, value in (("grid_rows", rows), ("grid_cols", cols),
                                 ("module_count", module_count),
                                 ("padding_count", rows * cols - module_count)):
                check(type(layout.get(field)) is int and layout[field] == value, f"{field} mismatch/type")
            check(layout.get("module_order") == "row-major", "module_order")
            check(type(layout.get("sampling_inner_fraction")) in (int, float)
                  and layout["sampling_inner_fraction"] == 0.6, "sampling_inner_fraction")
            padding = layout["padding"]
        check(type(layout.get("level_low")) is int and type(layout.get("level_high")) is int
              and 0 <= layout["level_low"] < layout["level_high"] <= 255, "L/H code values")
        check(bw >= cols and bh >= rows, "nonzero grid cell size")

        def expected_slot(index):
            row, col = divmod(index, cols)
            return rotate_rect([a + col * bw // cols, c + row * bh // rows,
                                a + (col + 1) * bw // cols, c + (row + 1) * bh // rows],
                               rotation, w_p, h_p)

        modules = layout.get("modules")
        check(isinstance(modules, list) and len(modules) == module_count, "module count")
        if not isinstance(modules, list):
            continue
        for index, module in enumerate(modules):
            module = obj(module, "module")
            check(type(module.get("index")) is int and module["index"] == index, "module index order/type")
            rect = module.get("rect_px")
            check(isinstance(rect, list) and len(rect) == 4 and all(type(v) is int for v in rect),
                  "module rect_px type")
            expected = expected_slot(index)
            check(rect == expected, f"module {index} rect mismatch: {rect} != {expected}")
            check(inside(rect, expected_dynamic), f"module {index} outside dynamic rect")
            if index:
                previous = modules[index - 1]["rect_px"]
                check(not intersects(rect, previous), f"module {index} overlaps previous")
        check(isinstance(padding, list) and len(padding) == rows * cols - module_count, "padding count")
        for offset, item in enumerate(padding if isinstance(padding, list) else []):
            item = obj(item, "padding")
            slot = module_count + offset
            check(type(item.get("slot_index")) is int and item["slot_index"] == slot, "padding slot order")
            check(item.get("role") == "padding", "padding role")
            level = layout.get("level_low") if offset % 2 == 0 else layout.get("level_high")
            check(type(item.get("level")) is int and item["level"] == level, "padding actual level")
            rect = item.get("rect_px")
            check(isinstance(rect, list) and len(rect) == 4 and all(type(v) is int for v in rect),
                  "padding rect type")
            check(rect == expected_slot(slot), "padding placement")

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
        actual = layout_by_id.get(segment["layout_id"], {})
        for field in ("drawable_width_px", "drawable_height_px"):
            check(segment.get(field) == actual.get(field), f"segment/layout {field} mismatch")

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
    submitted_identity_by_frame = {}
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
        segment_config = next((s for s in segments if s["segment_id"] == event.get("segment_id")), {})
        check(event.get("layout_id") == segment_config.get("layout_id"), "event layout must match original segment")
        event_layout = layout_by_id.get(event.get("layout_id"), {})
        layout_kind = event_layout.get("layout_type", "OPTC")
        if layout_kind != "OPTC":
            check(event.get("frame_kind") == "CALIBRATION" and event.get("phase") == "CALIBRATION", "non-OPTC calibration identity")
        if event_layout.get("diagnostic_pattern") == "VSYNC_BLACK_WHITE":
            check(isinstance(event.get("native_frame_id"), str), "BW native_frame_id decimal string")
        check(re.fullmatch(r"0|[1-9][0-9]*", str(event.get("native_frame_id"))) is not None,
              "native_frame_id must be a decimal string")
        kind = event.get("frame_kind")
        check(kind in ("WARMUP", "SESSION_CARD", "DYNAMIC", "END_CARD", "CALIBRATION"), "frame_kind")
        if kind == "DYNAMIC":
            check(layout_kind == "OPTC", "DYNAMIC only references OPTC")
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
        identity_fields = ("segment_id", "layout_id", "frame_kind", "phase", "render_seq", "payload_n", "crc8")
        identity = tuple(event.get(field) for field in identity_fields)
        if schema == "1.2":
            native = event.get("native_frame_id")
            if event["event_type"] == "SUBMITTED":
                check(native not in submitted_identity_by_frame, "native_frame_id reused/duplicate submission")
                submitted_identity_by_frame[native] = identity
            else:
                check(submitted_identity_by_frame.get(native) == identity, "result identity differs from original submission")
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
    check(profiles.get("schema_version") == schema, "display_profile schema matches manifest")
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
    profile_by_id = {profile.get("profile_id"): profile for profile in profiles.get("profiles", [])}
    segment_by_id = {segment["segment_id"]: segment for segment in segments}
    for binding in bindings or []:
        if binding.get("status") != "COMPATIBLE":
            continue
        key = profile_by_id.get(binding.get("profile_id"), {}).get("calibration_key", {})
        segment = segment_by_id.get(binding.get("segment_id"), {})
        layout = layout_by_id.get(segment.get("layout_id"), {})
        check(layout.get("layout_type", "OPTC") == "OPTC", "non-OPTC cannot be COMPATIBLE")
        if schema in ("1.1", "1.2"):
            check(key.get("geometry_profile") == layout.get("geometry_profile"),
                  "COMPATIBLE requires a verified geometry key")
        check(key.get("pixel_format") not in (None, "UNKNOWN")
              and segment.get("pixel_format") != "UNKNOWN", "UNKNOWN pixel format cannot be COMPATIBLE")
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
    # Pre-submit failures consume an allocated identity without a display row.
    # Their existing configuration event is still evidence of generation.
    for event in configuration:
        if event.get("event_type") != "RENDER_FAILURE":
            continue
        frame_id = event.get("details", {}).get("native_frame_id")
        segment_id = event.get("segment_id")
        if frame_id is not None and segment_id is not None:
            record = per_segment.setdefault(segment_id, {"generated": set(), "submitted": set(),
                                                       "presented": set(), "unconfirmed": set()})
            record["generated"].add((segment_id, frame_id))
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
