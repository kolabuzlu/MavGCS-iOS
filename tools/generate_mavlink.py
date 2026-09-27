#!/usr/bin/env python3
"""Write the MAVLink messages and enums the app speaks, as Swift.

Read from pymavlink's own copy of the message definitions, through
pymavlink's own parser, rather than typed out by hand. A message is a
list of byte offsets and a checksum seed, and a single one of either
being wrong produces a frame that looks fine and is silently thrown
away at the other end -- the failure the Android build spent a week
finding when a trailing zero cost every command it sent over ELRS.
The parser already knows how MAVLink orders fields on the wire, where
the extensions begin, and what CRC_EXTRA each message mixes in, so
none of that is decided here.

Only the messages in MESSAGES are generated. Adding one is a line in
that list and a re-run; the output is committed, so building the app
never needs Python.

    ~/MavGCS/.venv/bin/python tools/generate_mavlink.py

Any Python with pymavlink installed will do. The desktop project's
virtualenv has one.
"""

import os
import re
import sys

try:
    import pymavlink
    from pymavlink.generator import mavparse
except ImportError:
    sys.exit("pymavlink is not installed. Run this with ~/MavGCS/.venv/bin/python")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "MavlinkCore", "Sources", "MavlinkCore", "Generated")

# ArduPilot's dialect, which includes common, which includes standard and
# minimal. Parsing from the top of the tree is what makes ArduPilot's own
# additions to shared enums (MAV_CMD above all) arrive with them.
DIALECT = "ardupilotmega.xml"

MESSAGES = [
    # What the app reads.
    "HEARTBEAT",
    "SYS_STATUS",
    "GPS_RAW_INT",
    "SCALED_PRESSURE",
    "ATTITUDE",
    "GLOBAL_POSITION_INT",
    "RC_CHANNELS",
    "VFR_HUD",
    "COMMAND_ACK",
    "NAV_CONTROLLER_OUTPUT",
    "MISSION_CURRENT",
    "PARAM_VALUE",
    "STATUSTEXT",
    "HOME_POSITION",
    "BATTERY_STATUS",
    "TERRAIN_REPORT",
    "DISTANCE_SENSOR",
    "WIND",
    "RANGEFINDER",
    "EKF_STATUS_REPORT",
    "VIBRATION",
    # What the app sends.
    "COMMAND_LONG",
    "COMMAND_INT",
    "PARAM_SET",
    "REQUEST_DATA_STREAM",
]

ENUMS = [
    "MAV_TYPE",
    "MAV_AUTOPILOT",
    "MAV_STATE",
    "MAV_MODE_FLAG",
    "MAV_CMD",
    "MAV_RESULT",
    "MAV_FRAME",
    "MAV_SEVERITY",
    "GPS_FIX_TYPE",
    "MAV_PARAM_TYPE",
    "MAV_SENSOR_ORIENTATION",
    "MAV_SYS_STATUS_SENSOR",
    "EKF_STATUS_FLAGS",
]

SWIFT_TYPES = {
    "uint8_t": "UInt8",
    "int8_t": "Int8",
    "uint16_t": "UInt16",
    "int16_t": "Int16",
    "uint32_t": "UInt32",
    "int32_t": "Int32",
    "uint64_t": "UInt64",
    "int64_t": "Int64",
    "float": "Float",
    "double": "Double",
    "char": "UInt8",
}

# The reader and writer method for each wire type. See Payload.swift.
ACCESSORS = {
    "uint8_t": "u8",
    "int8_t": "i8",
    "uint16_t": "u16",
    "int16_t": "i16",
    "uint32_t": "u32",
    "int32_t": "i32",
    "uint64_t": "u64",
    "int64_t": "i64",
    "float": "f32",
    "double": "f64",
    "char": "u8",
}

SWIFT_KEYWORDS = {
    "associatedtype", "class", "deinit", "enum", "extension", "fileprivate",
    "func", "import", "init", "inout", "internal", "let", "open", "operator",
    "private", "protocol", "public", "rethrows", "static", "struct",
    "subscript", "typealias", "var", "break", "case", "continue", "default",
    "defer", "do", "else", "fallthrough", "for", "guard", "if", "in",
    "repeat", "return", "switch", "where", "while", "as", "catch", "false",
    "is", "nil", "super", "self", "Self", "throw", "throws", "true", "try",
}


def load_tree(name, base, seen):
    """Parse [name] and everything it includes, each file once."""
    if name in seen:
        return []
    seen.add(name)
    xml = mavparse.MAVXML(os.path.join(base, name), mavparse.PROTOCOL_2_0)
    parsed = [xml]
    for include in xml.include:
        parsed += load_tree(include, base, seen)
    return parsed


def camel(snake, upper_first=False):
    parts = [p for p in snake.lower().split("_") if p]
    if not parts:
        return snake
    head = parts[0] if not upper_first else parts[0].capitalize()
    text = head + "".join(p.capitalize() for p in parts[1:])
    return text


def identifier(name):
    if name in SWIFT_KEYWORDS:
        return "`%s`" % name
    if name[0].isdigit():
        return "_" + name
    return name


def doc(text, indent):
    """A description from the XML as a Swift doc comment."""
    text = re.sub(r"\s+", " ", (text or "").strip())
    if not text:
        return ""
    words = text.split(" ")
    lines, line = [], ""
    for word in words:
        if line and len(line) + 1 + len(word) > 76:
            lines.append(line)
            line = word
        else:
            line = (line + " " + word) if line else word
    if line:
        lines.append(line)
    return "".join("%s/// %s\n" % (indent, l) for l in lines)


def field_type(field):
    base = SWIFT_TYPES[field.type]
    if field.type == "char" and field.array_length:
        return "String"
    if field.array_length:
        return "[%s]" % base
    return base


def default_value(field):
    if field.type == "char" and field.array_length:
        return '""'
    if field.array_length:
        return "Array(repeating: 0, count: %d)" % field.array_length
    return "0"


def read_expr(field):
    acc = ACCESSORS[field.type]
    if field.type == "char" and field.array_length:
        return "reader.string(at: %d, length: %d)" % (field.wire_offset, field.array_length)
    if field.array_length:
        return "(0..<%d).map { reader.%s(at: %d + $0 * %d) }" % (
            field.array_length, acc, field.wire_offset, field.type_length)
    return "reader.%s(at: %d)" % (acc, field.wire_offset)


def write_stmt(field, name):
    acc = ACCESSORS[field.type]
    if field.type == "char" and field.array_length:
        return "writer.string(%s, at: %d, length: %d)" % (name, field.wire_offset, field.array_length)
    if field.array_length:
        # Short arrays are zero-filled by the writer; long ones are cut to
        # the field, never allowed to run into the next one.
        return "for (i, value) in %s.prefix(%d).enumerated() { writer.%s(value, at: %d + i * %d) }" % (
            name, field.array_length, acc, field.wire_offset, field.type_length)
    return "writer.%s(%s, at: %d)" % (acc, name, field.wire_offset)


def generate_message(msg):
    name = camel(msg.name, upper_first=True)
    fields = msg.ordered_fields
    out = []
    out.append(doc(msg.description, ""))
    out.append("public struct %s: MavlinkMessage, Equatable {\n" % name)
    out.append("    public static let messageId: UInt32 = %d\n" % msg.id)
    out.append('    public static let messageName = "%s"\n' % msg.name)
    out.append("    public static let crcExtra: UInt8 = %d\n" % msg.crc_extra)
    out.append("    /// Payload length without extensions, which is all MAVLink 1 carries.\n")
    out.append("    public static let minLength = %d\n" % msg.wire_min_length)
    out.append("    /// Payload length with every extension field present.\n")
    out.append("    public static let maxLength = %d\n" % msg.wire_length)
    out.append("\n")
    for f in fields:
        if f.omit_arg:
            continue
        comment = f.description or ""
        extras = []
        if f.units:
            extras.append("Units: %s." % f.units.strip("[]"))
        if f.enum:
            extras.append("%s: %s." % ("Bitmask of" if f.display == "bitmask" else "Values from", f.enum))
        if extras:
            comment = comment.strip()
            if comment and comment[-1] not in ".!?:":
                comment += "."
            comment = (comment + " " + " ".join(extras)).strip()
        out.append(doc(comment, "    "))
        out.append("    public var %s: %s\n" % (identifier(camel(f.name)), field_type(f)))
    out.append("\n")

    args = [f for f in fields if not f.omit_arg]
    # Declaration order for the initialiser, which is how the XML and every
    # other binding present a message; wire order is an encoding detail.
    ordered_args = sorted(args, key=lambda f: msg.fields.index(f) if f in msg.fields else 0)
    params = ",\n".join(
        "        %s: %s = %s" % (identifier(camel(f.name)), field_type(f), default_value(f))
        for f in ordered_args
    )
    out.append("    public init(\n%s\n    ) {\n" % params)
    for f in ordered_args:
        n = camel(f.name)
        out.append("        self.%s = %s\n" % (n, identifier(n)))
    out.append("    }\n\n")

    out.append("    public init(from reader: PayloadReader) {\n")
    for f in args:
        out.append("        %s = %s\n" % (identifier(camel(f.name)), read_expr(f)))
    out.append("    }\n\n")

    out.append("    public func write(to writer: inout PayloadWriter) {\n")
    for f in fields:
        if f.omit_arg:
            # The one fixed field MAVLink has: HEARTBEAT's mavlink_version.
            out.append("        writer.%s(%s, at: %d)\n" % (ACCESSORS[f.type], f.const_value, f.wire_offset))
            continue
        out.append("        %s\n" % write_stmt(f, "self." + camel(f.name)))
    out.append("    }\n")
    out.append("}\n")
    return "".join(out)


def enum_prefix(enum):
    """The part every entry's name starts with, to be dropped from Swift."""
    wanted = enum.name + "_"
    names = [e.name for e in enum.entry if not e.end_marker]
    if names and all(n.startswith(wanted) for n in names):
        return wanted
    # MAV_SENSOR_ORIENTATION's entries are MAV_SENSOR_ROTATION_..., so the
    # enum's own name is not the prefix. The longest shared run of words is.
    split = [n.split("_") for n in names]
    common = []
    for parts in zip(*split):
        if len(set(parts)) != 1:
            break
        common.append(parts[0])
    # Never the whole name of any entry.
    while common and any(len(s) <= len(common) for s in split):
        common.pop()
    return "_".join(common) + "_" if common else ""


def generate_enum(enum):
    entries = [e for e in enum.entry if not e.end_marker]
    top = max((e.value for e in entries), default=0)
    raw = "UInt8" if top <= 0xFF else "UInt16" if top <= 0xFFFF else "UInt32"
    prefix = enum_prefix(enum)
    name = camel(enum.name, upper_first=True)
    out = []
    out.append(doc(enum.description, ""))
    out.append("public enum %s {\n" % name)
    used = set()
    for e in entries:
        short = e.name[len(prefix):] if e.name.startswith(prefix) else e.name
        member = identifier(camel(short))
        if member in used:
            continue
        used.add(member)
        out.append(doc(e.description, "    "))
        out.append("    public static let %s: %s = %d\n" % (member, raw, e.value))
    out.append("\n    /// The name the definitions give a value, or nil for one they do not.\n")
    out.append("    public static func name(_ value: some BinaryInteger) -> String? {\n")
    out.append("        names[UInt32(truncatingIfNeeded: value)]\n")
    out.append("    }\n\n")
    out.append("    private static let names: [UInt32: String] = [\n")
    seen = set()
    for e in entries:
        if e.value in seen:
            continue
        seen.add(e.value)
        out.append('        %d: "%s",\n' % (e.value, e.name))
    out.append("    ]\n")
    out.append("}\n")
    return "".join(out)


def header():
    return (
        "// Generated by tools/generate_mavlink.py from pymavlink %s's\n"
        "// message definitions (%s and everything it includes).\n"
        "// Do not edit by hand: change the script's lists and run it again.\n\n"
        % (pymavlink.__version__, DIALECT)
    )


def main():
    base = os.path.join(os.path.dirname(pymavlink.__file__), "message_definitions", "v1.0")
    tree = load_tree(DIALECT, base, set())

    messages = {}
    enums = {}
    for xml in tree:
        for msg in xml.message:
            messages.setdefault(msg.name, msg)
        for enum in xml.enum:
            if enum.name in enums:
                # An enum extended by a later file: ArduPilot adds its own
                # commands to MAV_CMD, for one. Merge, first definition wins.
                have = {e.name for e in enums[enum.name].entry}
                enums[enum.name].entry += [e for e in enum.entry if e.name not in have]
            else:
                enums[enum.name] = enum

    missing = [n for n in MESSAGES + ENUMS if n not in messages and n not in enums]
    if missing:
        sys.exit("Not in the definitions: " + ", ".join(missing))

    os.makedirs(OUT_DIR, exist_ok=True)

    body = [header(), "// swiftlint:disable all\n\n"]
    for n in MESSAGES:
        body.append(generate_message(messages[n]))
        body.append("\n")
    body.append("/// Every message this app can decode, by id.\n")
    body.append("public enum MavlinkRegistry {\n")
    body.append("    public static let types: [UInt32: any MavlinkMessage.Type] = [\n")
    for n in MESSAGES:
        body.append("        %d: %s.self,\n" % (messages[n].id, camel(n, upper_first=True)))
    body.append("    ]\n}\n")
    with open(os.path.join(OUT_DIR, "Messages.swift"), "w") as f:
        f.write("".join(body).replace("\n\n\n", "\n\n"))

    body = [header(), "// swiftlint:disable all\n\n"]
    for n in ENUMS:
        body.append(generate_enum(enums[n]))
        body.append("\n")
    with open(os.path.join(OUT_DIR, "Enums.swift"), "w") as f:
        f.write("".join(body).rstrip("\n") + "\n")

    print("Wrote %d messages and %d enums to %s" % (len(MESSAGES), len(ENUMS), OUT_DIR))


if __name__ == "__main__":
    main()
