# Pablo

> Great artists steal.

Pablo is an agent-controlled flight recorder for the Mac. It can capture one app or an entire display as a synchronized replay of video, attributed input, changing apps and windows, and each app's accessibility tree over time—then gives humans a focused window for reviewing and marking up the evidence.

Agents can also inspect and control a running app—click, drag, scroll, type, press keys, or perform exposed accessibility actions—without creating a recording. Pablo keeps live inspection in memory and asks for approval in the app.

## [Download Pablo for macOS](https://github.com/semistrict/pablo/releases/latest)

Requires macOS 14 or newer on an Apple silicon Mac.

1. Download and unzip Pablo.
2. Move **Pablo.app** to **Applications** and open it.
3. Ask your agent to record a Mac app or your entire screen with Pablo.
4. Approve the request in Pablo and grant the requested macOS permissions the first time you record.

Recordings are saved to `~/Documents/Pablo Recordings`; application recording filenames include the application name by default. Open one in Pablo to replay the video, move through indexed accessibility frames such as `A11Y-012`, and trace circles, underlines, or arbitrary shapes directly over time with stable references such as `NOTE-007`.

The bundled Safari Web Extension can dump a DOM-derived accessibility tree and
perform bounded DOM actions without bringing Safari forward. It only receives
website access after the user clicks its toolbar button for the active tab.
Pablo can also stream a masked rrweb recording of that unlocked tab into a local
`.pabloweb` package, with pause/resume/stop controls in both app surfaces and a
built-in rrweb player. See [Safari web recordings](docs/rrweb.md).

Pablo records locally and contains no network code. A recording can include typed text and anything visible in the selected app or display, so treat it with the same care as a screen recording.

Licensed under the [Apache License 2.0](LICENSE).
