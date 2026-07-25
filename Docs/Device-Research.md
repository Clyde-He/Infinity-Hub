# Device Research and Verification Log

## Scope

The supported devices are the Angry Miao AM Infinity .97 mouse/receiver/Base
and the original AM Infinity 8K mouse/receiver.

Research was performed locally against the owner's hardware. The process
included USB/HID enumeration, non-exclusive vendor-interface probes, inspection
of Angry Miao's macOS driver behavior, and observation of the values published
by macOS.

This repository contains only our notes and original tools. It does not contain
the vendor installer, vendor binaries, firmware images, or a copy of
decompiled vendor source.

## AM Infinity .97 verified on hardware

- Receiver VID/PID: `0x0E8D:0x0703`
- Wired mouse VID/PID: `0x0E8D:0x0880`
- Protocol interface: primary usage `0xFF13 / 0x01`
- The receiver and wired mouse can exist at the same time.
- Mouse battery can be queried remotely through the receiver.
- Mouse battery can be queried locally over wired USB.
- Base battery is a distinct local query on the receiver.
- Mouse and Base each return charging status, percentage, health byte, and an
  exists flag.
- `charging_status = 0` has been observed while the mouse runs on battery.
- `charging_status = 1` has been observed while both wired Mouse and Base are
  charging.
- `charging_status = 2` has been observed on Base at 100%.
- The health byte has returned `0xFF` and is treated as unknown.
- Remote mouse firmware query returned `v1.7.6`.
- macOS can display Mouse and Base as two independent accessory power sources.
- In Bluetooth mode the Mouse enumerates as `AM Infinity .97` over Bluetooth
  Low Energy with observed VID/PID `0x0148:0x0000`.
- The Bluetooth Mouse exposes the standard `180F / 2A19` Battery Service.
  A live CoreBluetooth read returned `93%`.
- macOS publishes the Bluetooth Mouse natively with a Bluetooth icon, so
  Infinity Hub displays that value in its panel without republishing it.

Example verified live state after adding independent endpoint discovery:

```text
Mouse: Wired USB, 91%, charging_status 1, exists 1
Base: Receiver, 21%, charging_status 1, exists 1
```

These percentages are examples, not fixtures or expected values.

## Original AM Infinity 8K verified on hardware

- USB product: `AM INFINITY 8K MOUSE`
- Receiver VID/PID: `0x3151:0x5007`
- Private protocol interface: primary usage `0xFFFF / 0x0002`
- The protocol interface exposes a 64-byte Feature report and no input/output
  reports.
- Its report descriptor exactly describes one vendor Feature collection.
- The same USB device exposes separate Mouse and Consumer Control endpoints;
  neither is opened by Infinity Hub.
- Official-driver analysis identified the `F7` status getter and its response
  fields.
- The exact Feature Set/Get framing was verified against the physical
  receiver.
- A live response reported Mouse `100%`, Mouse online, and Receiver `99%`.
- The app published both values as separate macOS accessory power sources with
  VID/PID `0x3151:0x5007`.
- The profile does not report charging status or battery health; the app leaves
  those states unset instead of inferring them.

The original 8K is an independent app profile. Its reader does not reuse the
`.97` RACE parser or open any `.97` endpoint.

## AM Infinity .97 connection model

Mouse and Base are independent:

```text
Wired mouse (0x0880) ──> Mouse battery and future mouse settings

Bluetooth LE ──────────> Standard Battery Service, display only

Receiver (0x0703) ─────> Base battery and future Base settings
                    └──> Remote mouse fallback over 2.4 GHz
```

The application should:

1. Prefer a successful wired read for Mouse.
2. Use the standard Bluetooth Battery Service when the Bluetooth Mouse is
   connected.
3. Continue reading Base whenever the receiver is present.
4. Fall back to the receiver's remote-mouse path when neither wired nor
   Bluetooth Mouse battery is available.
5. Never hide Base merely because Mouse uses another connection.

## What can be inferred, but not measured directly

When the receiver exists and a remote Mouse battery response succeeds, the
2.4 GHz link was operational at that moment.

When the receiver exists but the remote Mouse query times out, possible causes
include sleep, power-off, range, interference, or a temporary protocol race.
The response alone cannot distinguish those causes.

With persistent history, a future Hub could estimate discharge rate, charge
rate, wake/sleep transitions, and approximate remaining runtime. Those values
would be statistical estimates, not device-reported telemetry.

## Information not currently available

No protocol evidence has been found for:

- RSSI, SNR, RF channel, interference, retry count, or packet loss
- measured end-to-end input latency
- explicit pairing identity or encryption state
- battery voltage, current, wattage, temperature, or cycle count
- design capacity, full-charge capacity, or reliable battery health
- accurate time remaining or time to full
- explicit docked state versus another external charging source

The configured report rate can likely be queried; this is not the same as
measuring the effective USB polling interval.

## Privacy and access constraints

Infinity Hub must only open the vendor-defined protocol interface selected
by an exact profile matcher:

- `.97`: VID/PID plus `0xFF13 / 0x01`
- original 8K: `0x3151:0x5007 + 0xFFFF / 0x0002`

Bluetooth support does not open the Bluetooth HID endpoints or depend on the
user-editable device name. It verifies Device Information model `ab162x` and
PnP vendor/product `0x0148:0x0000`, remembers the verified CoreBluetooth
identifier, and reads only Battery Service `180F` / Battery Level `2A19`.

It must not read:

- pointer movement
- mouse buttons
- scrolling
- keyboard reports
- consumer-control reports

Matching only by VID/PID after opening a broad `IOHIDManager` is insufficient.
The initial match must also include primary usage page and usage. This avoids
the macOS Keystroke Receiving / Input Monitoring prompt encountered during
early investigation.

## Suggested path toward Infinity Hub

### Stage 1: read-only diagnostics

- firmware versions
- active profile
- report rate and sensor FPS
- DPI stages and current stage
- sleep timers
- Sensor feature switches
- mouse and Base lighting state
- button mapping inventory
- export a diagnostic snapshot

### Stage 2: guarded settings

- one setting editor at a time
- explicit Apply
- range validation
- automatic read-back
- visible errors without interrupting battery monitoring

### Stage 3: profiles and backup

- export/import a versioned local JSON schema
- compare current device state with a saved profile
- restore selected sections
- retain unknown bytes when round-tripping structures

### Stage 4: lighting and macros

- Base lighting editor
- Mouse lighting editor
- DPI color editor
- button and macro editor after the action enum is fully documented

### Separate risk tier

Factory reset and firmware update must remain outside normal settings flows.
Firmware flashing should not be implemented from the current notes alone.
