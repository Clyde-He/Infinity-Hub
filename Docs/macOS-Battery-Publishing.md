# macOS Accessory Battery Publishing

## Purpose

Infinity Hub publishes device-reported values to macOS so the native
Batteries widget can show Mouse and Receiver/Base independently for both the
AM Infinity .97 and original AM Infinity 8K profiles.

The app currently uses the following IOKit power-source symbols:

```text
IOPSCreatePowerSource
IOPSSetPowerSourceDetails
IOPSReleasePowerSource
```

The created sources are process-owned. When the app exits or releases them,
the accessory entries disappear from macOS. Start at Login is therefore a
user-controlled convenience, not merely an app preference.

## Published dictionary

The `.97` sources publish:

| Key | Mouse | Base |
| --- | --- | --- |
| `Name` | `AM Infinity .97` | `AM Infinity .97 Base` |
| `Type` | `Accessory Source` | `Accessory Source` |
| `Transport Type` | `USB` | `USB` |
| `Current Capacity` | reported percentage | reported percentage |
| `Max Capacity` | `100` | `100` |
| `Is Present` | parsed exists/availability | parsed exists/availability |
| `Is Charging` | derived from status `1` | derived from status `1` |
| `Is Charged` | status `2`, or external at 100% | same |
| `Power Source State` | AC or Battery Power | AC or Battery Power |
| `Vendor ID` | `0x0E8D` | `0x0E8D` |
| `Product ID` | `0x0880` | `0x0703` |
| `Accessory Category` | `Mouse` | `Unknown` |
| `Accessory Identifier` | stable project identifier | stable project identifier |

`Transport Type = USB` describes the Mac-facing transport. A wireless Mouse
queried through the USB receiver still reaches macOS through USB.

The original 8K sources use:

| Key | Mouse | Receiver |
| --- | --- | --- |
| `Name` | `AM Infinity 8K` | `AM Infinity 8K Receiver` |
| `Vendor ID` | `0x3151` | `0x3151` |
| `Product ID` | `0x5007` | `0x5007` |
| `Accessory Category` | `Mouse` | `Unknown` |
| `Accessory Identifier` | `angrymiao.am-infinity-8k.mouse` | `angrymiao.am-infinity-8k.receiver` |

That profile reports percentages and a Mouse online flag, but no charging
status. Its published `Is Charging` and `Is Charged` values therefore remain
false rather than being inferred from the USB connection.

## Widget icon behavior

`Accessory Category` is a hint, not a guaranteed icon selector. Mouse produces
the expected mouse presentation. Base has used a neutral `Unknown` category,
but testing showed that changing categories did not reliably force a visibly
different icon on the current macOS version.

The Batteries widget may use internal category mapping, accessory identity,
cached presentation, or other private properties. Do not make core application
behavior depend on a particular widget glyph.

## Lifetime and stale readings

Mouse sleep is different from receiver removal:

- A temporary remote timeout may represent a sleeping Mouse. The app may keep
  the last useful Mouse value while retrying.
- Receiver removal means Base is no longer available and its source should be
  released.
- A wired Mouse may remain present while Base becomes absent.
- Base may remain present while a wireless Mouse sleeps.
- When an entire hardware profile disconnects, both of its sources are
  released. Keeping registered sources with only `Is Present = false` can
  leave stale entries visible in the Batteries widget.

This is why Mouse and Base must not share one global connected flag.

## Polling

- Startup retry: 5 seconds until the first valid Mouse value arrives
- Normal polling: 60 seconds
- Manual refresh: available in the menu-bar UI

Polling and power-source publishing are read-only with respect to the Angry
Miao device.

## API stability

These power-source creation symbols are not a polished public framework for
third-party accessory vendors. They have worked on the tested macOS version,
but a future macOS update could change symbol availability, dictionary keys,
widget filtering, or icon selection.

A production Hub should:

- isolate publishing behind a small adapter
- tolerate source creation/update failure
- keep the menu-bar UI useful even if the widget bridge breaks
- test symbol availability and OS behavior on every supported macOS release
