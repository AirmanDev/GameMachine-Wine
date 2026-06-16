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

## Building locally (Apple Silicon)

The engine is an x86_64 Wine that runs under Rosetta, so it is built as x86_64 too. This is the
primary, reproducible path on an Apple Silicon Mac; the GitHub workflow below just mirrors it on a
clean runner. Output: `gamemachine-wine-v1-osx64.tar.xz` (CrossOver 26.2.0 / Wine 11 source).

One-time setup - an x86_64 Homebrew under `/usr/local` (the Rosetta brew) plus the build deps:

    arch -x86_64 /usr/local/bin/brew install bison flex pkg-config \
        freetype gnutls gstreamer sdl2 faudio mpg123 libpng vulkan-loader

Build, from the repo root. The script downloads everything else it needs into `/tmp` and caches it
for re-runs - the CrossOver source tarball and the pinned xPack mingw GCC toolchain (currently 15.2.0,
see the toolchain section below) - so no mingw-w64 from Homebrew:

    arch -x86_64 env HOMEBREW_PREFIX=/usr/local ./build-wine.sh

To make the app pick up a fresh build, copy its hash into `AppConstants.gamemachineWineArchiveSHA256`
(the app re-downloads when the hash changes), and upload the asset to the `v1` release if you
distribute it:

    shasum -a 256 gamemachine-wine-v1-osx64.tar.xz
    gh release upload v1 gamemachine-wine-v1-osx64.tar.xz --clobber

Xcode: the current Command Line Tools work for this build. Only if it stops in `signal_x86_64.c` with
a CFI assembler error (seen on some Xcode 16+ toolchains) select Xcode 15.4 for the run by prefixing
`DEVELOPER_DIR=/Applications/Xcode-15.4.0.app/Contents/Developer`.

Dependencies recap (x86_64 Homebrew under `/usr/local`): bison, flex, pkg-config, freetype, gnutls,
gstreamer, sdl2, faudio, mpg123, libpng, vulkan-loader. A full Wine build is sensitive to the host
setup, so pin dependency versions and adjust configure flags per CrossOver release. The mingw-w64 PE
cross-compiler is **not** taken from Homebrew - see the toolchain pin below.

## Building via GitHub Actions (optional)

The workflow is manual only (`workflow_dispatch`) and mirrors the local build on a `macos-14` runner,
then uploads the artifact to the `v1` release. Unlike a local build (which uses the working tree
directly), the workflow builds the pushed ref, so commit and push `build-wine.sh` first:

    gh workflow run build.yml -f cx_version=26.2.0 -f build_tag=v1
    gh run watch

Tag pushes intentionally do not trigger a rebuild; the CI image selects Xcode 15.4 defensively.

## PE toolchain: xPack mingw GCC (pinned, currently 15.2.0)

The Windows PE DLLs are cross-compiled with the prebuilt
[xPack mingw-w64 GCC](https://github.com/xpack-dev-tools/mingw-w64-gcc-xpack/releases) toolchain
(both i686 + x86_64 targets, `darwin-x64` so it runs under Rosetta). `build-wine.sh` downloads an exact,
SHA-checked version and hard-fails if the cross GCC is anything else - the version is set by the
`MINGW_GCC_VERSION` / `XPACK_RELEASE` / `XPACK_SHA256` vars at the top of the script, so it is a single
place to change. The PE DLLs are built without `-g` and `--strip-all`-stripped (CrossOver's lean layout,
for parity/size). GCC 15 defaults to C23, so the script pins `CROSSCFLAGS=-std=gnu17` on the PE side -
without it Wine PE code that uses `bool` as an identifier (e.g. `programs/winhlp32/macro.h`) won't compile.

The GCC version is **not** the anti-tamper fix. We previously pinned **13.2.0** ("CrossOver's exact PE
compiler") on a theory that the exact PE codegen mattered for code-scanning anti-tamper under Rosetta
(Blizzard's `eidolon` - Overwatch 2, D2R, D4). That theory was wrong: with the real fix in place (the
loader hook below) our 13.2.0, 13.4.0 and 15.2.0 builds all behave the same, so the version never
mattered. We now build with the latest GCC (15.2.0) and verify on a real machine. To fall back to the
13.2.0 CrossOver-parity toolchain, run:

    MINGW_GCC_VERSION=13.2.0 XPACK_RELEASE=13.2.0-1 \
        XPACK_SHA256=9c2bb3841b991dc07481507f76304397fd1b61ec8cfea973a9fb96dc12c038ae ./build-wine.sh

## D3DMetal under Rosetta: non-native code-region registration

The actual mitigation is global, not game-specific. The engine carries CrossOver's loader hook
("CW HACK 22434"), built in from CrossOver's source, and the app sets `CX_APPLEGPTK_LIBD3DSHARED_PATH`
(the path to the user's imported GPTK `libd3dshared.dylib`) on **every** D3DMetal launch. The hook then
registers every loaded PE module's code range as a NON-NATIVE region with Rosetta.

That is what lets Rosetta-based anti-tamper which scans loaded module code tolerate the Apple D3DMetal
ARM64 code instead of treating it as tampering. Blizzard's `eidolon` (Overwatch 2, D2R, D4) is the known
case - without the registration it recurses into a stack overflow inside the game's loader DLL, holds
ntdll's `loader_section`, and the process deadlocks at launch - but the mechanism is not game-specific:
it applies to any title with that kind of protection and is a harmless no-op for the rest. Verified on a
real M5 Pro with Overwatch 2 (the loader deadlock cleared: 0 stack overflow, 0 `loader_section`
timeout). The build's only job is to keep the CrossOver loader hook intact; activation is the app's env
var, not a rebuild.

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
