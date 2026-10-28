# Contributing to SmoothDisplay

Thanks for helping. Bug reports, reports about how your monitor behaves, translations and pull requests are all welcome.

## Building

You need macOS 13 or later and the Xcode Command Line Tools (`xcode-select --install`). There are no dependencies
and no Xcode project.

```bash
./build.sh            # builds build/SmoothDisplay.app (universal: arm64 + x86_64)
./build.sh --install  # also replaces /Applications/SmoothDisplay.app with it and launches it
```

`build.sh` signs with the certificate named in `SIGN_IDENTITY`, otherwise with an **Apple Development** certificate
when your keychain has one, otherwise ad-hoc. macOS ties the Accessibility permission (needed for the brightness keys)
to the code signature, so ad-hoc builds lose it on every rebuild. A free Apple Development certificate
(Xcode › Settings › Accounts) keeps it. A dev build shares the bundle id and settings with the release app but not its
signature, so after switching between them you may need to re-allow SmoothDisplay in the Accessibility list.

Releases are made by the maintainers with `scripts/release.sh` (Developer ID signing, notarization, DMG).
CI builds every push and pull request with `.github/workflows/build.yml`, signed ad-hoc.

## Code style

- Swift and AppKit only, no third-party dependencies.
- Match the surrounding code: naming, structure, formatting.
- Comments explain *why*, not what the next line does. Hardware quirks, macOS behaviour and magic numbers deserve one.
- Keep pull requests focused on one change, and say in the description what you tested it on.

## Localization

All UI text goes through `L("...")`, and the English text is the key. The app ships English, Ukrainian and Russian:

- `Resources/en.lproj/Localizable.strings`
- `Resources/uk.lproj/Localizable.strings`
- `Resources/ru.lproj/Localizable.strings`

These files are generated. When you add or change a string, add its translation to every language table in
`scripts/strings.py` and run `python3 scripts/strings.py`; it rewrites all `Localizable.strings` files and fails when a
key used in `Sources/` has no translation. Edits made directly in the `.strings` files are overwritten on the next
release. A missing translation falls back to English at runtime. Command line output is English only.

## Testing notes

DDC/CI behaviour differs from monitor to monitor, and sometimes between ports, cables and docks of the same monitor.
Some monitors ignore brightness commands while a picture feature such as backlight strobing, dynamic contrast or HDR
locks brightness. Please test with your own monitor and include in an issue or pull request:

- the monitor model and how it is connected (port, cable, dock or adapter);
- the Mac model and macOS version;
- the relevant lines from `~/Library/Logs/SmoothDisplay.log`, especially the `probe` and `DDC write` lines;
- the output of `/Applications/SmoothDisplay.app/Contents/MacOS/SmoothDisplay --list` and `--brightness`.

Display mode changes, the Retina override and color profiles change system state. Before you finish testing, go back
with **Standard Mode, No HiDPI** and **Colors › macOS Factory Profile (from monitor data)** if you need a clean slate.

## License

By contributing you agree that your contributions are licensed under the [MIT License](LICENSE).
