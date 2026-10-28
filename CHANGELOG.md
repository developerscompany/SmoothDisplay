# Changelog

All notable changes to SmoothDisplay are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-10-27

First public release.

### Added

- Menu bar app for macOS 13 Ventura and later, universal binary (Apple Silicon and Intel),
  signed with a Developer ID certificate and notarized by Apple, distributed as a DMG.
- Retina (HiDPI) modes for external monitors: "Retina — native size" plus presets with 15%, 25%,
  one third and 1.5× larger UI, a "More Retina Sizes" submenu and "Standard Mode, No HiDPI".
  The highest refresh rate is kept for every size.
- "Unlock Retina Modes…": installs a display override plist with `scale-resolutions` from 2x the panel
  down to 1x in 32 px steps for monitors that macOS offers no near-native Retina mode for.
- "Keep Mode After Reconnect and Sleep": re-applies the chosen mode when a display connects and after wake.
- Brightness keys of the MacBook control the external monitor under the pointer (16 steps, 64 with
  Option+Shift), with an on-screen indicator and a brightness slider in the menu.
- Automatic brightness method: hardware backlight over DDC/CI (VCP 0x10, IOAVService on Apple Silicon),
  verified with a write-then-read probe, or software dimming through the display gamma table.
  "Check Monitor Again" re-runs the probe.
- "Colors" submenu: ICC v2 matrix/TRC display profiles generated from the monitor's real primaries, with a
  D65, 6000K, 5500K or native white point (vcgt), and a way back to the macOS factory profile.
- "Thinner Text (applies after apps restart)" toggle for macOS stem darkening (`AppleFontSmoothing`).
- "Launch at Login", "Check for Updates…" with an optional daily check against GitHub Releases,
  "About SmoothDisplay" and "Display Settings…".
- Command line options: `--list`, `--apply WxH`, `--native`, `--brightness [0-100]`,
  `--color [d65|6000k|5500k|native|factory]`, `--login on|off`.
- English, Ukrainian and Russian localization, following the system language or picked in the "Language" menu.
- Troubleshooting log in `~/Library/Logs/SmoothDisplay.log`.

[Unreleased]: https://github.com/developerscompany/SmoothDisplay/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/developerscompany/SmoothDisplay/releases/tag/v1.0.0
