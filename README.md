# Infinity Hub

A native macOS menu-bar hub for the Angry Miao AM Infinity .97 and original
AM Infinity 8K mice.

It reads the proven battery status getters from each hardware family's private
USB HID interface and the standard Bluetooth Battery Service exposed by the
`.97`, then publishes only the USB-backed Mouse and Receiver/Base values as
macOS accessory power sources for the built-in Batteries widget.

The project also preserves the protocol and device research needed to evolve
the app into a broader native macOS device Hub.

## Behavior

- Mouse and base battery cards in a menu-bar panel
- Adaptive grouping: paired endpoints share one divided card; product headers
  appear only when multiple device groups need to be distinguished
- Manual Refresh and Quit controls
- User-controlled Start at Login toggle using `SMAppService.mainApp`
- Five-second retry until the first valid Mouse value is available
- Sixty-second polling after the first valid Mouse reading
- Independent endpoint discovery: wired Mouse is preferred while Base remains
  available through the receiver
- Standard Bluetooth Battery Service display with connection priority
  `Wired USB → Bluetooth → 2.4 GHz`
- Automatic Mouse fallback to the 2.4 GHz receiver
- Disconnected wired endpoints are hidden immediately
- The last wireless Mouse reading is retained for up to five minutes across
  brief sleep or reconnect periods
- An empty state is shown when no device remains available
- Bluetooth Mouse battery is not republished because macOS already supplies
  its native Bluetooth entry to the Batteries widget
- Sources for a disconnected hardware profile are released immediately, so
  only connected profiles remain in the Batteries widget
- Both accessory sources are released when the app quits

The app opens only each profile's vendor USB HID interface, non-exclusively.
For Bluetooth it verifies the standard Device Information Service using model
`ab162x` and PnP ID `0x0148:0x0000`, then reads only the standard `180F / 2A19`
Battery Service. The original 8K profile uses the verified official
`F6/F7/FE/D6/FC` read-only mailbox sequence. The app never sends device
configuration, lighting, DPI, mappings, or firmware.

HID matching is restricted from the first manager query to either:

- AM Infinity .97: `0x0E8D:0x0703/0x0880 + 0xFF13/0x01`
- Original AM Infinity 8K: `0x3151:0x5007 + 0xFFFF/0x0002`

Bluetooth display requires the normal macOS Bluetooth permission. The app does
not request or require Input Monitoring, Keystroke Receiving, Accessibility,
or access to pointer, keyboard, or consumer-control endpoints.

Start at Login is not enabled automatically.

## Research

- [HID protocol and command catalog](Docs/Protocol.md)
- [Device research, verified behavior, and Hub roadmap](Docs/Device-Research.md)
- [macOS Batteries widget publishing](Docs/macOS-Battery-Publishing.md)
- [Read-only research tools](Tools/README.md)

Vendor installers, binaries, firmware images, and decompiled vendor source are
not stored in this project.
