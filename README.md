# Pablo

> Great artists steal.

Pablo is a flight recorder for Mac apps. Pick an app, press record, and get a synchronized replay of what happened: video, input, and the app's accessibility tree over time.

## [Download Pablo for macOS](https://github.com/semistrict/pablo/releases/latest)

Requires macOS 14 or newer on an Apple silicon Mac.

1. Download and unzip Pablo.
2. Move **Pablo.app** to **Applications** and open it.
3. Choose an app from the menu-bar recorder and press **Start Recording**.
4. Grant the requested macOS permissions the first time you record.

Recordings are saved to `~/Movies/Pablo Recordings`. Open one in Pablo to replay the video and move through indexed accessibility frames such as `A11Y-012`.

Pablo records locally and contains no network code. A recording can include typed text and anything visible in the captured app, so treat it with the same care as a screen recording.

Licensed under the [Apache License 2.0](LICENSE).
