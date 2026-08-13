# Pablo

> Great artists steal.

Pablo is an agent-controlled flight recorder for Mac apps. It captures a synchronized replay of what happened—video, input, and the app's accessibility tree over time—then gives humans a focused window for reviewing and marking up the evidence.

Agents can also inspect and control a running app—click, drag, scroll, type, press keys, or perform exposed accessibility actions—without creating a recording. Pablo keeps live inspection in memory and asks for approval in the app.

## [Download Pablo for macOS](https://github.com/semistrict/pablo/releases/latest)

Requires macOS 14 or newer on an Apple silicon Mac.

1. Download and unzip Pablo.
2. Move **Pablo.app** to **Applications** and open it.
3. Ask your agent to record a Mac app with Pablo.
4. Approve the request in Pablo and grant the requested macOS permissions the first time you record.

Recordings are saved to `~/Movies/Pablo Recordings`. Open one in Pablo to replay the video, move through indexed accessibility frames such as `A11Y-012`, and trace circles, underlines, or arbitrary shapes directly over time with stable references such as `NOTE-007`.

Pablo records locally and contains no network code. A recording can include typed text and anything visible in the captured app, so treat it with the same care as a screen recording.

Licensed under the [Apache License 2.0](LICENSE).
