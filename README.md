# GameMachine-Wine

Wine for GameMachine, compiled from CrossOver's published source.

GameMachine's fast paths on Apple Silicon are DXMT (DX10/11 to Metal) and Apple's D3DMetal (DX12).
Neither one works on a stock WineHQ build. DXMT needs the `winemac.drv` Metal symbols to stay
exported, and a normal build hides them with `-fvisibility=hidden`, so DXMT can't bind to them and
fails with "no exported symbols needed by DXMT". D3DMetal is built against CrossOver's ABI and
won't load on anything else. CrossOver releases its Wine changes under the LGPL, so this repo just
takes that source and builds it with the symbols left visible. The result is the same kind of build
CrossOver and the Game Porting Toolkit ship, only open and pinned to a version we control.

The output is one `wswine.bundle` tarball that GameMachine downloads as its "GameMachine Wine" engine.

## Building

Build on an Intel Mac or the `macos-13` runner so the x86_64 host compiles natively. On Apple
Silicon the engine runs under Rosetta, same as CrossOver and GPTK.

    CX_VERSION=24.0.7 ./build-wine.sh

Or run the Build workflow from the Actions tab; it uploads the tarball to a release tagged
`cx24.0.7-1`.

Dependencies (Homebrew): bison flex mingw-w64 gstreamer freetype gnutls sdl2 faudio mpg123 libpng
jpeg sane-backends libgphoto2 molten-vk pkg-config, plus the Xcode command line tools. A full Wine
build is sensitive to the host setup, so expect to pin dependency versions and adjust configure
flags per CrossOver release.

## Licensing

The Wine binaries are LGPL-2.1; see COPYING. The source is CrossOver's package from
codeweavers.com/crossover/source, and build-wine.sh records the exact version it downloads.

D3DMetal and the Game Porting Toolkit belong to Apple and are not redistributable, so they are
never bundled here. GameMachine imports those from the toolkit each user downloads on their own.
