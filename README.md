## <p align="center">Ground Control Station for ArduPilot & PX4, INAV.</p>

<p align="center">
 <a href="LICENSE"><img alt="License: GPL-3.0-or-later" src="https://img.shields.io/badge/License-GPLv3-blue.svg"></a>
 <a href="https://github.com/kolabuzlu/MavGCS-iOS/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/kolabuzlu/MavGCS-iOS?label=Release&color=59aa29"></a>
 <img alt="Platform" src="https://img.shields.io/badge/Platform-iOS-lightgrey?style=flat">
 <a href="https://github.com/kolabuzlu/MavGCS"><img alt="Desktop version for Windows and macOS" src="https://img.shields.io/badge/Desktop%20version-Windows%20%7C%20macOS-red?style=flat"></a>
 <a href="https://github.com/kolabuzlu/MavGCS-Android"><img alt="Android version" src="https://img.shields.io/badge/Android%20version-Android-8957e5?style=flat"></a>
</p>

<p align="center">
  <img alt="MavGCS running on a radio handset, two laptops, a monitor and a tablet, arranged on a table in a field under an open sky, beneath the words FPV Ground Control Station" src="mavgcstabletoplogosmall.png" />
</p>

A ground control station software for **MAVLink** protocol, for iPhone. 🛩️

It works with **Ardupilot**, **PX4** (Bi-directional) or **INAV** (Uni-directional).

Supports MAVLink over WiFi telemetry bridges such as mLRS, ELRS and LTE
telemetry, over UDP or TCP.

The iPhone member of MavGCS: simpler than the desktop and Android
versions, and made to be carried. You can monitor HUD and vital
information about flight, follow the vehicle on a satellite map, use
weather radar, view terrain radar, Live AGL and a compass with the way
home, arm and disarm, change flight modes, fly to a point by tapping the
map, and get directions to the aircraft in Google Maps.

There is a desktop version for Windows and macOS,
[MavGCS](https://github.com/kolabuzlu/MavGCS), and an Android version,
[MavGCS Android](https://github.com/kolabuzlu/MavGCS-Android).

Created by **Derin Hakan Karakurt**

### Installing & Running MavGCS (iOS)

iPhone, iOS 17 or later, held in landscape with the charging port on the
left.

- **Build it yourself** - see *Building* below. A free Apple ID is
  enough; apps installed that way run for 7 days, then need installing
  again.
- **Sideload** - download `MavGCS-iOS-<version>-unsigned.ipa` from the
  [Releases page](https://github.com/kolabuzlu/MavGCS-iOS/releases) and
  install it with a sideloading tool such as AltStore or Sideloadly, which
  sign it with your own Apple ID.

### Connecting 📡

- **mLRS WiFi bridge** - choose UDP, *Connect to*, `192.168.4.55` port
  `14550`. The bridge broadcasts until a ground station speaks to it, and
  iOS does not give apps broadcasts, so MavGCS speaks first.
- **SITL, MAVProxy, a radio that sends to the phone** - UDP, *Listen*,
  port `14550`.
- **A TCP server** - TCP, the server's address and port (SITL: `5760`).
- **No aircraft at hand** - choose *Demo* and connect: a simulated plane
  flies over Ankara inside the app and answers every control.

The first connection asks for Local Network access. MavGCS cannot reach
anything on WiFi without it; it is under Settings > Privacy & Security >
Local Network if it was declined.

### Building 🛠️

Open `MavGCS.xcodeproj` in Xcode 26 or later, choose your team under
Signing & Capabilities, and run.

Everything MAVLink lives in the `MavlinkCore` Swift package, which builds
and tests on the Mac without a simulator:

```
cd MavlinkCore && swift test
```

The messages are generated from pymavlink's own definitions, and the
codec is tested against frames pymavlink built:

```
~/MavGCS/.venv/bin/python tools/generate_mavlink.py
~/MavGCS/.venv/bin/python tools/make_test_vectors.py
```

The desktop repository's `tools/fake_plane.py` flies a simulated ArduPlane
for the app to connect to.
