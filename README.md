# GameMachine-Wine

Wine for GameMachine, compiled from CrossOver's published source.

GameMachine's fast paths on Apple Silicon are DXMT (DX10/11 to Metal) and Apple's D3DMetal (DX12).
Neither one works on a stock WineHQ build. DXMT needs the `winemac.drv` Metal symbols to stay
exported, and a normal build hides them with `-fvisibility=hidden`, so DXMT can't bind to them and
fails with "no exported symbols needed by DXMT". D3DMetal is built against CrossOver's ABI and
won't load on anything else. CrossOver releases its Wine changes under the LGPL, so this repo takes
that source and builds a pinned runtime for GameMachine.

The output is one `wswine.bundle` tarball that GameMachine downloads as its "GameMachine Wine" engine.

## Building

The current release target is CrossOver 26.2.0 / Wine 11:

    gamemachine-wine-cx26-osx64.tar.xz

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

Dependencies (x86_64 Homebrew under `/usr/local`): bison, flex, mingw-w64, pkg-config, freetype,
gnutls, gstreamer, sdl2, faudio, mpg123, libpng, and vulkan-loader. A full Wine build is sensitive to
the host setup, so pin dependency versions and adjust configure flags per CrossOver release.

The current published release is:

- Tag: `cx26.2.0-1`
- Asset: `gamemachine-wine-cx26-osx64.tar.xz`
- SHA-256: `e7b4d4397184c6a8494a4c06d716bd70e173447babfe2422b968a90d36d60bbc`

The tarball includes Wine Mono/Gecko, WoW64 (`i386-windows` + `x86_64-windows`), the x86_64 Unix
modules, and the loader patch that restores `WINEDLLPATH_PREPEND` for the D3DMetal bridge.

## Licensing

The Wine binaries are LGPL-2.1; see COPYING. The source is CrossOver's package from
codeweavers.com/crossover/source, and build-wine.sh records the exact version it downloads.

D3DMetal and the Game Porting Toolkit belong to Apple and are not redistributable, so they are
never bundled here. GameMachine imports those from the toolkit each user downloads on their own.
