#!/usr/bin/env python3
"""Frames built by pymavlink, for the Swift codec to be checked against.

pymavlink is the reference: it is what ArduPilot's own tools and the
desktop MavGCS speak. Each message the app knows is filled with values
that differ in every byte -- a field read from the wrong offset, or with
the wrong width or sign, cannot come out right by accident -- and packed
the ways that matter:

  v2          every field set, extensions included
  v2_trimmed  the back half of the fields zero, so MAVLink 2's truncation
              cuts the payload short and the reader has to pad it out
  v1          MAVLink 1, which carries no extensions at all
  v2_signed   a signed frame, whose 13 trailing bytes the reader must
              step over rather than read as the start of the next frame

Written to MavlinkCore/Tests/MavlinkCoreTests/Vectors/frames.json.

    ~/MavGCS/.venv/bin/python tools/make_test_vectors.py
"""

import importlib.util
import json
import os

os.environ["MAVLINK20"] = "1"

import pymavlink  # noqa: E402
from pymavlink.dialects.v20 import ardupilotmega as mav2  # noqa: E402
from pymavlink.dialects.v10 import ardupilotmega as mav1  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "MavlinkCore", "Tests", "MavlinkCoreTests", "Vectors", "frames.json")

# The generator's own list, so the two cannot drift apart.
_spec = importlib.util.spec_from_file_location(
    "generate_mavlink", os.path.join(ROOT, "tools", "generate_mavlink.py"))
_generator = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_generator)
MESSAGES = _generator.MESSAGES

SYSTEM, COMPONENT = 7, 42

WIDTH = {"uint8_t": 1, "int8_t": 1, "uint16_t": 2, "int16_t": 2,
         "uint32_t": 4, "int32_t": 4, "uint64_t": 8, "int64_t": 8}


def layout(cls):
    """(name, type, array length) for every field, in wire order.

    pymavlink keeps field types in declaration order and array lengths in
    wire order, so the two have to be lined up by name.
    """
    return [
        (name, cls.fieldtypes[cls.fieldnames.index(name)], cls.array_lengths[i])
        for i, name in enumerate(cls.ordered_fieldnames)
    ]


def value_for(ftype, index, salt):
    """Something distinctive in every byte, for field [index] of a message."""
    if ftype in ("float", "double"):
        # A multiple of 1/4, so exactly representable and compared exactly.
        return -1234.5 + index * 97.25 + salt * 0.5
    width = WIDTH[ftype]
    raw = 0
    for b in range(width):
        raw |= ((0x11 * (index + 1) + 0x07 * b + salt * 0x1D) & 0xFF) << (8 * b)
    raw = raw or 1  # never zero, which reads as "not sent"
    if ftype.startswith("int") and raw >= 1 << (8 * width - 1):
        raw -= 1 << (8 * width)
    return raw


def fill(cls, zero_from=None, salt=0):
    """Field values for [cls], zero from wire position [zero_from] onward."""
    values = {}
    for i, (name, ftype, length) in enumerate(layout(cls)):
        zero = zero_from is not None and i >= zero_from
        if name == "mavlink_version":
            values[name] = 3  # fixed by the protocol, whatever the sender says
        elif ftype == "char":
            text = "" if zero else ("MavGCS iOS %s" % cls.msgname)[:length or 1]
            values[name] = text
        elif length:
            values[name] = [0 if zero else value_for(ftype, i * 16 + k, salt) for k in range(length)]
        else:
            values[name] = (0.0 if ftype in ("float", "double") else 0) if zero else value_for(ftype, i, salt)
    return values


def packed(module, name, values, signed=False):
    cls = getattr(module, "MAVLink_%s_message" % name.lower())
    args = []
    for field in cls.fieldnames:
        value = values[field]
        # pymavlink's constructors take text as bytes.
        args.append(value.encode("ascii") if isinstance(value, str) else value)
    msg = cls(*args)
    link = module.MAVLink(None, srcSystem=SYSTEM, srcComponent=COMPONENT)
    link.seq = 0
    if signed:
        link.signing.secret_key = bytes(range(32))
        link.signing.link_id = 3
        link.signing.timestamp = 123456789
        link.signing.sign_outgoing = True
    return bytes(msg.pack(link)).hex()


def as_text(value):
    """Every value as text, so a 64-bit integer survives JSON exactly."""
    if isinstance(value, list):
        return [as_text(v) for v in value]
    if isinstance(value, float):
        return repr(value)
    return str(value)


def texts(values):
    return {k: as_text(v) for k, v in values.items()}


def main():
    vectors = []
    for name in MESSAGES:
        cls2 = getattr(mav2, "MAVLink_%s_message" % name.lower())
        full = fill(cls2)
        # Half the wire fields zeroed: in every message here that reaches
        # back past the extensions into the base fields.
        trimmed = fill(cls2, zero_from=max(1, len(cls2.ordered_fieldnames) // 2), salt=1)
        entry = {
            "name": name,
            "id": cls2.id,
            "system": SYSTEM,
            "component": COMPONENT,
            "fields": texts(full),
            "v2": packed(mav2, name, full),
            "v2_signed": packed(mav2, name, full, signed=True),
            "fields_trimmed": texts(trimmed),
            "v2_trimmed": packed(mav2, name, trimmed),
        }
        cls1 = getattr(mav1, "MAVLink_%s_message" % name.lower(), None)
        if cls1 is not None:
            v1_values = {k: full[k] for k in cls1.fieldnames}
            entry["fields_v1"] = texts(v1_values)
            entry["v1"] = packed(mav1, name, v1_values)
        vectors.append(entry)

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f:
        json.dump({"pymavlink": pymavlink.__version__, "vectors": vectors}, f, indent=1)
    print("Wrote %d vectors to %s" % (len(vectors), OUT))


if __name__ == "__main__":
    main()
