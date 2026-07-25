# Research Tools

These tools are original, read-only utilities used to inspect the supported
AM Infinity hardware families. They are intentionally not members of the
Infinity Hub app target.

The `.97` tools restrict their initial `IOHIDManager` match to:

```text
VID 0x0E8D
PID 0x0703 or 0x0880
Primary usage 0xFF13 / 0x01
```

They use non-exclusive HID access and do not open pointer, keyboard, or
consumer-control endpoints.

The original 8K probe independently restricts its match to:

```text
VID 0x3151
PID 0x5007
Primary usage 0xFFFF / 0x0002
No input or output reports, 64-byte feature report
```

## Battery probe

Source: `battery-probe/main.swift`

It independently checks the receiver and wired Mouse, then prints raw and
parsed battery responses. When the receiver is present it also tries the
remote Mouse firmware query.

Build and run:

```sh
xcrun swiftc \
  -framework IOKit \
  Tools/battery-probe/main.swift \
  -o /tmp/infinity-battery-probe

/tmp/infinity-battery-probe
```

## HID inspector

Source: `hid-inspector/main.swift`

It lists the protocol endpoints, report sizes, descriptors, power-related
registry properties, and relevant vendor feature elements.

Build and run:

```sh
xcrun swiftc \
  -framework IOKit \
  Tools/hid-inspector/main.swift \
  -o /tmp/infinity-hid-inspector

/tmp/infinity-hid-inspector
```

## Original Infinity 8K battery probe

Source: `original-battery-probe/main.swift`

It verifies the exact product name, report sizes, and feature-only interface
before allowing the single official `F7` status getter request. It prints the
raw response and the Mouse battery, Mouse online flag, and Receiver battery.

Build and run:

```sh
xcrun swiftc \
  -framework IOKit \
  Tools/original-battery-probe/main.swift \
  -o /tmp/original-infinity-battery-probe

/tmp/original-infinity-battery-probe
```

## Safety

Do not broaden the HID match to all interfaces in a production app. Do not
change these tools to issue configuration writes without first adding explicit
command allowlists, value validation, and read-back verification.
