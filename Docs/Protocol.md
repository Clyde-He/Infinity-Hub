# AM Infinity HID Protocol Notes

This document records the protocol knowledge used by Infinity Hub and the
additional commands identified while studying Angry Miao's macOS driver.

The original installer, packaged binaries, and decompiled vendor source are
intentionally not part of this project. This file is a clean-room engineering
summary plus observations made against the owner's hardware.

## Confidence labels

- **Verified**: exercised successfully against the relevant physical hardware.
- **Observed**: seen in a real response, but not every semantic value has been
  exercised.
- **Driver-derived**: present in Angry Miao's driver, but not yet exercised by
  this project.
- **Unknown**: the byte or behavior exists, but its meaning is not established.

## AM Infinity .97

### USB and HID identity

| Property | Receiver / Base | Wired mouse |
| --- | --- | --- |
| Vendor ID | `0x0E8D` | `0x0E8D` |
| Product ID | `0x0703` | `0x0880` |
| Product | `AM Infinity .97` | `AM Infinity .97` |
| Protocol usage page | `0xFF13` | `0xFF13` |
| Protocol usage | `0x01` | `0x01` |
| Transport exposed to macOS | USB | USB |

The receiver and wired mouse may be enumerated simultaneously. A client must
therefore model Mouse and Base independently instead of choosing one global
connection mode.

Always include VID, PID, primary usage page, and primary usage in the initial
`IOHIDManager` match. Opening every HID interface first and filtering later can
touch keyboard or consumer-control endpoints and trigger macOS Input
Monitoring / Keystroke Receiving permission.

### RACE transport

The verified protocol interface uses:

- Output report ID: `0x06`
- Input report ID: `0x07`
- Buffer length used by hidapi and this project: 62 bytes

An output packet is framed as:

| Offset | Meaning |
| --- | --- |
| `0` | Output report ID, `0x06` |
| `1` | Command length |
| `2` | Target: `0x00` local, `0x80` remote mouse through receiver |
| `3...` | Command beginning with `05 5A` |
| remainder | Zero padding to 62 bytes |

For a command shaped like:

```text
05 5A <length> 00 <race-id-high> <race-id-low> ...
```

the two bytes at command offsets 4 and 5 identify the response.

A normal response body begins with `05 5B`. The receiver may concatenate that
body behind an unsolicited `05 5D` event, so parsers must scan the complete
input report for a matching `05 5B ... raceID` body rather than assume a fixed
offset.

### Verified queries

| Function | Command | Target | Status |
| --- | --- | --- | --- |
| Mouse battery through receiver | `05 5A 02 00 CF 30` | remote `0x80` | Verified |
| Wired mouse battery | `05 5A 02 00 CF 30` | local `0x00` | Verified |
| Base battery | `05 5A 02 00 0F 30` | local receiver | Verified |
| Mouse firmware through receiver | `05 5A 03 00 07 1C 00` | remote `0x80` | Verified, returned `v1.7.6` |
| Receiver firmware | `05 5A 03 00 07 1C 00` | local receiver | Driver-derived |

### Battery response

Relative to the beginning of the matching `05 5B` body:

| Offset | Meaning | Confidence |
| --- | --- | --- |
| `0` | `0x05` | Verified |
| `1` | `0x5B` response marker | Verified |
| `2` | Response payload length | Observed |
| `4...5` | Race ID | Verified |
| `7` | Charging status | Observed |
| `8` | Battery level, integer percent | Verified |
| `9` | Health byte | Unknown; device returns `0xFF` |
| `10` | Exists flag | Verified; `1` when present |

Observed charging status values:

| Value | Interpretation | Evidence |
| --- | --- | --- |
| `0` | Running on battery / not charging | Observed on wireless mouse |
| `1` | Charging / externally powered | Verified on wired mouse and Base |
| `2` | Charged / externally powered | Observed on Base at 100% |

`health == 0xFF` must be treated as unsupported or unknown, not as 255%.

### Bluetooth Battery Service

In Bluetooth mode the `.97` does not expose the USB RACE protocol interface.
It enumerates as `AM Infinity .97` over Bluetooth Low Energy and exposes the
standard Battery Service:

| Property | Value |
| --- | --- |
| Service UUID | `180F` |
| Battery Level characteristic | `2A19` |
| Value | One unsigned byte, `0...100` percent |

Before reading battery data, Infinity Hub verifies the read-only Device
Information Service `180A`:

| Characteristic | Verified value |
| --- | --- |
| Model Number `2A24` | `ab162x` |
| PnP ID `2A50` | vendor source `1`, vendor `0x0148`, product `0x0000` |

The user-editable Bluetooth name is not part of the matcher. After successful
verification the app remembers the CoreBluetooth peripheral identifier, but
revalidates Model and PnP ID on each connection. Only then does it discover
`180F / 2A19` and perform a read. A verified live read returned `93%`. macOS
already publishes this source natively, so the app uses the value only in its
menu-bar panel and does not create a duplicate power source.

## Original AM Infinity 8K

The original receiver is a separate hardware family and does not use the
`.97` RACE transport.

### USB and HID identity

| Property | Value |
| --- | --- |
| Vendor ID | `0x3151` |
| Receiver Product ID | `0x5007` |
| USB product | `AM INFINITY 8K MOUSE` |
| Protocol usage page / usage | `0xFFFF / 0x0002` |
| Input report size | `0` |
| Output report size | `0` |
| Feature report size | `64` |
| Feature report ID | `0` |

The feature-only report descriptor verified on hardware is:

```text
06 FF FF 09 02 A1 01 09 02 15 80 25 7F 95 40 75 08 B1 02 C0
```

The same USB device also exposes Mouse and Consumer Control interfaces. They
are not protocol interfaces and must never be opened by Infinity Hub.

### Verified official battery sequence

`F7` remains the receiver status getter. Its request is:

```text
F7 00 00 00 00 00 00 00 ... 00
```

The official Mouse battery getter is transported through the receiver mailbox:

1. Open the exact `0x3151:0x5007 + 0xFFFF/0x0002` interface non-exclusively.
2. Verify that it has no input/output reports, has a 64-byte Feature report,
   and matches the known descriptor.
3. Send `F6 05`, then poll `F7` byte `5` for send-ready.
4. Send `FE 40`.
5. Send `D6 00 00 00 00 00 00 29` followed by 56 zero bytes.
6. Poll `F7` byte `0` for read-ready.
7. Send `FC` and parse the returned `D6` response.

Every request is exactly 64 bytes. Steps using a response perform Feature
Set, wait 10 ms, then Feature Get. Polls are bounded, and the production
allowlist contains only these five exact read-only request payloads.

The verified response fields are:

| Offset | Meaning | Confidence |
| --- | --- | --- |
| `0` | Mailbox read flag | Driver-derived / observed |
| `2` | Mouse battery percent | Verified |
| `4` | Mouse online flag: `0` online, non-zero offline | Verified |
| `5` | Mailbox send-ready flag | Driver-derived / observed |
| `10` | Receiver/Base battery percent | Verified |

One verified live response was:

```text
00 00 64 01 00 01 02 00 00 01 63 00 ... 00
```

It represented Mouse `100%`, Mouse online, and Receiver `99%`. This profile
does not expose charging status, battery health, or a separate Base exists
flag, so the app must not infer those values.

The verified `FC` response begins with `D6` and parses:

| Offset | Meaning |
| --- | --- |
| `1` | Battery status |
| `2` | Battery enabled flag |
| `3` | Mouse battery percent |

A repeated live response was `D6 00 01 64 00 00 00 29 ...`, representing
status `0`, enabled `1`, and Mouse `100%`.

## AM Infinity .97 driver-derived configuration commands

The following command families exist in Angry Miao's driver. Unless marked
Verified above, they are not yet enabled in Infinity Hub and their valid
ranges still need controlled read/write/read-back testing.

### Identity and profile

| Function | Read | Write | Notes |
| --- | --- | --- | --- |
| Active profile | `... C9 30` | `... C8 30 <profile>` | Driver-derived |
| Rotation correction | `... D9 30` | `... D8 30 <switch> <angle>` | Returns switch and angle |
| Serial number | `05 5A 06 00 0C 0A 0C 60 E8 03` | none found | Mouse/dongle distinction requires verification |
| Factory restore | none | `05 5A 02 00 CE 30` | Destructive; never issue implicitly |

### Buttons and macros

| Function | Read | Write | Notes |
| --- | --- | --- | --- |
| Button mapping | `... C3 30 <index>` | `... C2 30 <index> ...` | Driver iterates indexes 1 through 7 |

Observed driver-side mapping payload types include standard actions,
consumer/standard key combinations, macros with repeat mode/count, and DPI
actions. The action-type enum and every payload length must be documented
before exposing writes.

### Sensor and performance

| Setting | Read | Write |
| --- | --- | --- |
| Debounce: wired / 2.4 GHz / Bluetooth | `... E9 30` | `... E8 30 <wired> <2.4G> <BT>` |
| Lift-off distance | `... CD 30` | `... CC 30 <value>` |
| Motion Sync | `... D3 30` | `... D2 30 <switch>` |
| Angle Snapping | `... D5 30` | `... D4 30 <switch>` |
| Ripple Control | `... D7 30` | `... D6 30 <switch>` |
| Report / polling rate | `... 11 30` | `... 10 30 <value16>` |
| Sensor FPS | `... DF 30` | `... DE 30 <value>` |
| Sleep timers | `... 13 30` | `... 12 30 <timer payload>` |

The driver's sleep getter sums three 2.4 GHz timer segments and three
Bluetooth timer segments. The writer contains additional constant timing
fields that must not be generalized without captures.

### DPI

| Function | Read | Write |
| --- | --- | --- |
| Stage count, current stage, X/Y values | `... C5 30` | X/Y via `... C4 30 <stage> <x16> <y16>` |
| Current DPI stage | included above | `... C7 30 <stage>` |
| DPI quick-switch button | `... EB 30` | `... EA 30 <value>` |
| DPI loop mode | none found | `... C6 30 <value>` |
| DPI stage colors | memory records `0x21...0x28` | memory-record write |

The DPI response contains a current stage, up to eight X values, up to eight Y
values, and a configured stage count.

### Mouse lighting

| Function | Read | Write |
| --- | --- | --- |
| Light switch, type, speed | memory record `... 0A 60 E8 03` | `... B3 30 <switch> <type> <speed>` |
| Primary RGB color | memory record `... 00 62 E8 03` | memory-record write |

The driver also generates multi-frame breathing data. That path should be
treated as a separate lighting compiler, not copied into production without
size and timing validation.

### Base / receiver lighting

Read command:

```text
05 5A 02 00 0E 30
```

Write family:

```text
05 5A 0F 00 0D 30 ...
```

The driver parses:

- light switch
- light type
- three colors
- one saturation value per color
- speed
- brightness

## Rules for future write support

1. Never write on app launch, polling, device discovery, or profile display.
2. Read and store the complete current state before enabling an Apply button.
3. Validate ranges against both driver UI constraints and hardware captures.
4. Serialize commands per physical endpoint.
5. After every write, issue the corresponding getter and compare the result.
6. Preserve a local export that can restore all previously readable settings.
7. Require explicit confirmation for factory reset and future firmware work.
8. Keep battery monitoring functional when configuration reads or writes fail.
9. Treat firmware update as a separate project and risk tier.
