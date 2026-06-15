# GameMachine-Wine

Wine for GameMachine, compiled from CrossOver's published source.

GameMachine's fast paths on Apple Silicon are DXMT (DX10/11 to Metal) and Apple's D3DMetal (DX12).
Neither one works on a stock WineHQ build. DXMT needs the `winemac.drv` Metal symbols to stay
exported, and a normal build hides them with `-fvisibility=hidden`, so DXMT can't bind to them and
fails with "no exported symbols needed by DXMT". D3DMetal is built against CrossOver's ABI and
won't load on anything else. CrossOver releases its Wine changes under the LGPL, so this repo takes
that source and builds a pinned runtime for GameMachine.

The output is one `wswine.bundle` tarball that GameMachine downloads as its "GameMachine Wine" engine.
The engine carries its own version (currently **v1**); the underlying source is CrossOver 26.2.0 /
Wine 11, but the artifact and release are named after the GameMachine engine, not the upstream
release. New engine builds keep the same `v1` name and are tracked by their SHA-256 (the app
re-downloads when the hash changes); a breaking change would bump to `v2`.

## Building

The v1 engine is built from CrossOver 26.2.0 / Wine 11 source:

    gamemachine-wine-v1-osx64.tar.xz

The reproducible local build environment is an Apple Silicon Mac running the x86_64 build under
Rosetta with Xcode 15.4 selected:

    arch -x86_64 env \
      DEVELOPER_DIR=/Applications/Xcode-15.4.0.app/Contents/Developer \
      HOMEBREW_PREFIX=/usr/local \
      ./build-wine.sh

The GitHub workflow is intentionally manual (`workflow_dispatch` only). Do not rely on tag pushes to
rebuild Wine: local builds are faster to inspect, and the release asset can be uploaded with
`gh release upload --clobber` after validation. The workflow still uses `macos-14` when run manually
because that image provides the arm64 runner shape we need and can select Xcode 15.4. Newer images are
not automatically better for this build; Xcode 16+ currently trips Wine's x86_64 CFI assembler path.

Dependencies (x86_64 Homebrew under `/usr/local`): bison, flex, pkg-config, freetype, gnutls,
gstreamer, sdl2, faudio, mpg123, libpng, and vulkan-loader. A full Wine build is sensitive to the host
setup, so pin dependency versions and adjust configure flags per CrossOver release. The mingw-w64 PE
cross-compiler is **not** taken from Homebrew — see the toolchain pin below.

## PE toolchain is pinned to mingw GCC 13.2.0 (Overwatch 2 / eidolon)

The Windows PE DLLs must be built with **mingw-w64 GCC 13.2.0** — CrossOver's exact PE compiler — not a
newer GCC. Blizzard's `eidolon` anti-tamper (Overwatch 2, and D2R/D4 since Jan 2026) scans the loaded
Wine modules' in-memory code and dispatches via raised exceptions; it is sensitive to the exact
codegen. Builds with GCC 15.2.0 **and** 13.4.0 both make an eidolon routine recurse into a stack
overflow inside `Overwatch_loader.dll`, holding ntdll's `loader_section` so the game deadlocks at
launch. This was isolated on a real M5 Pro: CrossOver's GCC-13.2.0 PE DLLs dropped into our own engine
pass eidolon, our GCC-13.4.0 ones don't — even after a full `--strip-all` (so it is not debug info),
and ntdll's export surface is identical (so it is not an API patch). The minor version matters.

GCC 13.2.0 will not compile from source on a modern macOS SDK (GCC bug #111632), so `build-wine.sh`
downloads the prebuilt [xPack mingw-w64 GCC 13.2.0](https://github.com/xpack-dev-tools/mingw-w64-gcc-xpack/releases/tag/v13.2.0-1)
toolchain (both i686 + x86_64 targets, darwin-x64 so it runs under Rosetta) and hard-fails if the cross
GCC is anything other than 13.2.0. The PE DLLs are then built without `-g` and `--strip-all`-stripped,
matching CrossOver's lean, stripped release layout (strip is for parity/size, not the eidolon fix).

The release artifact must be self-contained for end users. GStreamer is enabled for Wine media
paths, but the script fails the build if any native Mach-O module keeps an absolute non-system dylib
dependency. If GStreamer/FFmpeg pulls in developer-machine `/usr/local` libraries, the build script
copies them into `wswine.bundle/lib`, rewrites references to loader-relative install names
(`@loader_path/...`), and audits the result before signing and packaging.

The tarball includes Wine Mono/Gecko, WoW64 (`i386-windows` + `x86_64-windows`), the x86_64 Unix
modules, and the loader patch that restores `WINEDLLPATH_PREPEND` for the D3DMetal bridge.

## Licensing

The Wine binaries are LGPL-2.1; see COPYING. The source is CrossOver's package from
codeweavers.com/crossover/source, and build-wine.sh records the exact version it downloads.

D3DMetal and the Game Porting Toolkit belong to Apple and are not redistributable, so they are
never bundled here. GameMachine imports those from the toolkit each user downloads on their own.
