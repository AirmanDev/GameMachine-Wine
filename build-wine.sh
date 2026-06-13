#!/bin/sh
# Builds Wine for GameMachine from CrossOver's published source.
#
# Why this exists: DXMT needs the winemac.drv Metal entry points (the macdrv_* symbols declared in
# dlls/winemac.drv/winemacdrv.h) to be exported. A stock build hides them with -fvisibility=hidden,
# so DXMT can't find them at runtime and bails out with "no exported symbols needed by DXMT".
# Apple's D3DMetal is a separate problem: it is built against CrossOver's unixlib ABI and won't load
# on a non-CrossOver Wine. CrossOver's Wine changes are LGPL and published, so we compile that source
# with the symbols left visible. That covers both cases at once.
#
# What it produces: a self-contained wswine.bundle with new WoW64 (one x86_64 host that runs both
# 32-bit and 64-bit Windows code), winemac symbols visible, and msync (the source already carries it;
# the app toggles it with WINEMSYNC at runtime). The bundle layout is bin/wine, bin/wineserver,
# lib/wine/{i386-windows,x86_64-windows,x86_64-unix}/... which is what GameMachine looks for. The
# shared wine-mono (.NET) and wine-gecko (MSHTML) runtimes are bundled into share/wine/{mono,gecko}
# so a fresh prefix doesn't pop the Wine Mono/Gecko download dialog on first launch (see below).
# NOTE: this only bundles open-source Wine components. Apple's Game Porting Toolkit (D3DMetal) is
# NOT bundled — the engine only stays ABI-compatible so the user's own GPTK import can load.
#
# Host arch: x86_64. The wine binary translates x86/x64 Windows code and runs under Rosetta on Apple
# Silicon, the same way CrossOver and GPTK do. Build natively on an Intel runner, or under
# `arch -x86_64` on Apple Silicon. The PE modules are Windows i386/x86_64 (llvm-mingw) regardless.
#
# Dependencies (Homebrew on an x86_64 prefix): bison flex mingw-w64 gstreamer freetype gnutls sdl2
# faudio mpg123 libpng jpeg sane-backends libgphoto2 molten-vk pkg-config, plus the Xcode CLT. The
# configure flags below follow Apple's game-porting-toolkit formula and the Gcenx macOS Wine builds;
# a full Wine build is touchy, so pin dependency versions on the runner and tweak per CrossOver release.
#
# Output: ./gamemachine-wine-cx26-osx64.tar.xz (CrossOver 26 / Wine 11, the GPTK 4.0-capable base).
# The workflow uploads it to the cx26.2.0-1 release.
set -eu

CX_VERSION="${CX_VERSION:-26.2.0}"
BUILD_TAG="${BUILD_TAG:-cx26.2.0-1}"
OUTPUT_NAME="${OUTPUT_NAME:-gamemachine-wine-cx26-osx64.tar.xz}"
MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
SOURCE_URL="${SOURCE_URL:-https://media.codeweavers.com/pub/crossover/source/crossover-sources-${CX_VERSION}.tar.gz}"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
OUT_DIR="${OUT_DIR:-$(pwd -P)}"

WORK="$(mktemp -d /tmp/gm-wine-build.XXXXXX)"
STAGE="${WORK}/stage/wswine.bundle"
SRC="${WORK}/sources/wine"          # wine tree inside the CrossOver source bundle
BUILD="${WORK}/build"
TARBALL="${TARBALL_CACHE:-/tmp/crossover-sources-${CX_VERSION}.tar.gz}"  # cached download
export MACOSX_DEPLOYMENT_TARGET

BREW="${HOMEBREW_PREFIX:-$(brew --prefix 2>/dev/null || echo /usr/local)}"
export PATH="${BREW}/opt/bison/bin:${BREW}/opt/flex/bin:${BREW}/bin:${PATH}"

echo "==> Building Wine from CrossOver ${CX_VERSION} (tag ${BUILD_TAG})"
echo "    work: ${WORK}"
echo "    brew: ${BREW}"

echo "==> Downloading source (cache: ${TARBALL})"
[ -f "${TARBALL}" ] || curl -fL "${SOURCE_URL}" -o "${TARBALL}"

# The CrossOver bundle is one tarball whose top level is sources/ with many sibling projects
# (wine, ghostscript, dxvk, gstreamer, ...). We only want sources/wine; extract just that so the
# build can't wander into a sibling project's configure.
echo "==> Extracting sources/wine"
tar -xzf "${TARBALL}" -C "${WORK}" sources/wine
[ -x "${SRC}/configure" ] || { echo "ERROR: wine configure not found at ${SRC}"; exit 1; }

# CrossOver's winedbg includes programs/winedbg/distversion.h, which their top-level build
# generates (it carries the crash-dialog strings). We build only sources/wine, so the file is
# missing and config.status' makedep step fails. Provide a minimal one before configure runs.
cat > "${SRC}/programs/winedbg/distversion.h" <<'EOF'
#define WINDEBUG_WHAT_HAPPENED_MESSAGE "The program encountered a problem and stopped working."
#define WINDEBUG_USER_SUGGESTION_MESSAGE "Please relaunch the application. If the problem persists, reinstall it."
EOF

# Restore CrossOver's WINEDLLPATH_PREPEND, which CrossOver 26 dropped from the loader. GameMachine's
# D3DMetal (GPTK) backend relies on it: the GPTK PE DLLs carry the "Wine builtin DLL" signature, so
# Wine won't load them from the prefix as native — they must shadow the engine's own builtin
# d3d11/dxgi/... by being searched FIRST on the builtin DLL path. CX26/upstream only APPEND
# WINEDLLPATH after the default dll_dir (set_dll_path: dll_dir is pushed before the WINEDLLPATH
# entries), so a plain WINEDLLPATH never wins. The prepend_dll_path() helper (CW Hack 24067) still
# exists in the source — we only re-wire the env-var caller into set_dll_path(). Without this the
# engine's builtin DXMT always wins and D3DMetal silently never loads. Idempotent (skip if present).
LOADER="${SRC}/dlls/ntdll/unix/loader.c"
if ! grep -q 'WINEDLLPATH_PREPEND' "${LOADER}"; then
  echo "==> Patching loader.c: restore WINEDLLPATH_PREPEND (GPTK D3DMetal DLL shadowing)"
  cat > "${WORK}/gm-prepend.c" <<'CEOF'

    /* GameMachine: re-add CrossOver's WINEDLLPATH_PREPEND (dropped in CX26) so an external dir
       (the GPTK D3DMetal DLLs) can shadow the engine's builtin DLLs by name. Entries are prepended
       in reverse so the first listed dir ends up searched first, ahead of dll_dir. */
    if ((path = getenv( "WINEDLLPATH_PREPEND" )) && *path)
    {
        char **gm_entries;
        int gm_n = 0, gm_cap = 1;
        for (p = path; *p; p++) if (*p == ':') gm_cap++;
        gm_entries = malloc( gm_cap * sizeof(*gm_entries) );
        path = strdup( path );
        for (p = strtok( path, ":" ); p; p = strtok( NULL, ":" )) gm_entries[gm_n++] = strdup( p );
        free( path );
        while (gm_n > 0) prepend_dll_path( gm_entries[--gm_n] );
        free( gm_entries );
    }
CEOF
  sed -i.bak '/^    dll_paths\[count\] = NULL;$/r '"${WORK}/gm-prepend.c" "${LOADER}"
  rm -f "${LOADER}.bak"
  grep -q 'WINEDLLPATH_PREPEND' "${LOADER}" || { echo "ERROR: WINEDLLPATH_PREPEND patch did not apply"; exit 1; }
fi

# Keep winemac.drv symbols visible for DXMT. CrossOver already exports them; default visibility makes
# sure a toolchain default of -fvisibility=hidden can't strip the Metal bridge.
export CFLAGS="-g -O2 -fvisibility=default -Wno-implicit-function-declaration -Wno-deprecated-declarations -Wno-incompatible-pointer-types"
export CXXFLAGS="${CFLAGS}"
export LDFLAGS="-Wl,-rpath,@loader_path/../../ -Wl,-rpath,${BREW}/lib"
# mingw-w64 / gcc 14 defaults to C23, where `bool` is a reserved keyword. Wine 9.0's PE code still
# uses `bool` as an identifier (e.g. programs/winhlp32/macro.h: `BOOL bool;`), which fails to parse.
# Build the cross-compiled (PE) side as gnu17 so the pre-C23 meaning holds across all such code.
export CROSSCFLAGS="-g -O2 -std=gnu17"

echo "==> Configuring (new WoW64, i386 + x86_64)"
mkdir -p "${BUILD}"
cd "${BUILD}"
"${SRC}/configure" \
  --prefix="${WORK}/stage-prefix" \
  --enable-archs=i386,x86_64 \
  --with-mingw \
  --disable-tests \
  --disable-win16 \
  --without-x \
  --without-oss \
  --with-gnutls \
  --with-freetype \
  --with-gstreamer \
  --with-sdl \
  --with-faudio \
  --with-mpg123 \
  --without-pulse \
  --without-dbus \
  --without-alsa \
  --without-krb5

echo "==> Building -j${JOBS}"
make -j"${JOBS}"
make install

echo "==> Staging wswine.bundle"
mkdir -p "${STAGE}"
cp -R "${WORK}/stage-prefix/." "${STAGE}/"

# Sanity check that DXMT will find what it needs.
winemac="$(find "${STAGE}/lib/wine" \( -name 'winemac.drv.so' -o -name 'winemac.so' \) -print -quit 2>/dev/null)"
if [ -n "${winemac}" ] && nm -gU "${winemac}" 2>/dev/null | grep -qi 'macdrv'; then
  echo "==> winemac exports macdrv_* (DXMT can bind)"
else
  echo "WARN: macdrv_* symbols not found in winemac driver; check the visibility flags"
fi

# Bundle the shared wine-mono (.NET) and wine-gecko (MSHTML) runtimes so a fresh prefix doesn't
# pop the "Wine could not find a wine-mono/gecko package" download dialog on first launch. These
# are NOT part of the Wine source tree (they are separate prebuilt packages), so a from-source
# build omits them unless we add them here, exactly like the Gcenx/CrossOver macOS packages do.
# The versions are read from the very source we compile (dlls/appwiz.cpl/addons.c) so they always
# match the engine and auto-track a CrossOver bump — no hardcoding. mscoree looks for the runtime
# at share/wine/mono/wine-mono-<MONO_VERSION>/ and mshtml at share/wine/gecko/wine-gecko-<ver>-<arch>/.
echo "==> Bundling wine-mono + wine-gecko (offline .NET/Gecko, no first-launch download prompt)"
ADDONS="${SRC}/dlls/appwiz.cpl/addons.c"
MONO_VERSION="$(awk -F'"' '/#define[[:space:]]+MONO_VERSION/{print $2; exit}' "${ADDONS}")"
GECKO_VERSION="$(awk -F'"' '/#define[[:space:]]+GECKO_VERSION/{print $2; exit}' "${ADDONS}")"
[ -n "${MONO_VERSION}" ] && [ -n "${GECKO_VERSION}" ] || { echo "ERROR: could not read MONO/GECKO version from ${ADDONS}"; exit 1; }
echo "    wine-mono ${MONO_VERSION}, wine-gecko ${GECKO_VERSION} (parsed from addons.c)"

MONO_DIR="${STAGE}/share/wine/mono"
GECKO_DIR="${STAGE}/share/wine/gecko"
mkdir -p "${MONO_DIR}" "${GECKO_DIR}"

fetch() {  # url cache_path  — download once, reuse on re-runs (like the source tarball)
  [ -f "$2" ] || curl -fL "$1" -o "$2"
}

# wine-mono ships a single universal (32+64-bit) "-x86" packager tarball that extracts to
# wine-mono-<ver>/ (bin/lib/etc/support); wine-gecko ships per-arch tarballs, both needed (WoW64).
MONO_TARBALL="/tmp/wine-mono-${MONO_VERSION}-x86.tar.xz"
fetch "https://dl.winehq.org/wine/wine-mono/${MONO_VERSION}/wine-mono-${MONO_VERSION}-x86.tar.xz" "${MONO_TARBALL}"
tar -xJf "${MONO_TARBALL}" -C "${MONO_DIR}"
for GARCH in x86 x86_64; do
  GTB="/tmp/wine-gecko-${GECKO_VERSION}-${GARCH}.tar.xz"
  fetch "https://dl.winehq.org/wine/wine-gecko/${GECKO_VERSION}/wine-gecko-${GECKO_VERSION}-${GARCH}.tar.xz" "${GTB}"
  tar -xJf "${GTB}" -C "${GECKO_DIR}"
done

# Sanity: the extracted dir names must match exactly what mscoree/mshtml look for.
[ -d "${MONO_DIR}/wine-mono-${MONO_VERSION}" ] || { echo "ERROR: wine-mono did not extract to wine-mono-${MONO_VERSION}"; exit 1; }
[ -d "${GECKO_DIR}/wine-gecko-${GECKO_VERSION}-x86_64" ] && [ -d "${GECKO_DIR}/wine-gecko-${GECKO_VERSION}-x86" ] \
  || { echo "ERROR: wine-gecko did not extract to wine-gecko-${GECKO_VERSION}-{x86,x86_64}"; exit 1; }
echo "==> Mono/Gecko bundled (share/wine/mono/wine-mono-${MONO_VERSION}, share/wine/gecko/wine-gecko-${GECKO_VERSION}-*)"

echo "==> Ad-hoc signing"
# Sign only the native Mach-O modules. A `while read -d ''` loop (NOT `xargs -I{}`, which now hits
# "command line cannot be assembled, too long" because the bundled mono/gecko trees add thousands of
# files) handles any file count; prune those PE/managed trees up front since they never contain Mach-O.
find "${STAGE}" \( -path "${STAGE}/share/wine/mono" -o -path "${STAGE}/share/wine/gecko" \) -prune -o \
  -type f \( -name '*.dylib' -o -name '*.so' -o -perm -111 \) -print0 2>/dev/null \
  | while IFS= read -r -d '' f; do
      file "$f" | grep -q Mach-O && codesign --force -s - "$f" 2>/dev/null || true
    done

echo "==> Packing ${OUTPUT_NAME}"
cd "${WORK}/stage"
COPYFILE_DISABLE=1 tar --options xz:compression-level=6 -cJf "${OUT_DIR}/${OUTPUT_NAME}" wswine.bundle

echo "==> Done: ${OUT_DIR}/${OUTPUT_NAME}"
rm -rf "${WORK}"
