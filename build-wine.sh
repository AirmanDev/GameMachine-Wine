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
# lib/wine/{i386-windows,x86_64-windows,x86_64-unix}/... which is what GameMachine looks for.
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
# Output: ./gamemachine-wine-cx24-osx64.tar.xz. The workflow uploads it to the cx24.0.7-1 release.
set -eu

CX_VERSION="${CX_VERSION:-24.0.7}"
BUILD_TAG="${BUILD_TAG:-cx24.0.7-1}"
OUTPUT_NAME="${OUTPUT_NAME:-gamemachine-wine-cx24-osx64.tar.xz}"
MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
SOURCE_URL="${SOURCE_URL:-https://media.codeweavers.com/pub/crossover/source/crossover-sources-${CX_VERSION}.tar.gz}"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

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

# Keep winemac.drv symbols visible for DXMT. CrossOver already exports them; default visibility makes
# sure a toolchain default of -fvisibility=hidden can't strip the Metal bridge.
export CFLAGS="-g -O2 -fvisibility=default -Wno-implicit-function-declaration -Wno-deprecated-declarations -Wno-incompatible-pointer-types"
export CXXFLAGS="${CFLAGS}"
export LDFLAGS="-Wl,-rpath,@loader_path/../../ -Wl,-rpath,${BREW}/lib"

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
winemac="$(find "${STAGE}/lib/wine" -name 'winemac.drv.so' -print -quit 2>/dev/null \
          || find "${STAGE}/lib/wine" -name 'winemac.so' -print -quit 2>/dev/null)"
if [ -n "${winemac}" ] && nm -gU "${winemac}" 2>/dev/null | grep -qi 'macdrv'; then
  echo "==> winemac exports macdrv_* (DXMT can bind)"
else
  echo "WARN: macdrv_* symbols not found in winemac driver; check the visibility flags"
fi

echo "==> Ad-hoc signing"
find "${STAGE}" -type f \( -name '*.dylib' -o -name '*.so' -o -perm -111 \) -print0 2>/dev/null \
  | xargs -0 -I{} sh -c 'file "{}" | grep -q Mach-O && codesign --force -s - "{}" 2>/dev/null || true'

echo "==> Packing ${OUTPUT_NAME}"
OUT_DIR="$(pwd -P)"
cd "${WORK}/stage"
COPYFILE_DISABLE=1 tar --options xz:compression-level=6 -cJf "${OUT_DIR}/${OUTPUT_NAME}" wswine.bundle

echo "==> Done: ${OUT_DIR}/${OUTPUT_NAME}"
rm -rf "${WORK}"
