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
# NOT bundled - the engine only stays ABI-compatible so the user's own GPTK import can load.
#
# Host arch: x86_64. The wine binary translates x86/x64 Windows code and runs under Rosetta on Apple
# Silicon, the same way CrossOver and GPTK do. Build natively on an Intel runner, or under
# `arch -x86_64` on Apple Silicon. The PE modules are Windows i386/x86_64, cross-compiled with the
# xPack mingw-w64 GCC toolchain pinned by MINGW_GCC_VERSION below (currently 15.2.0; see the note).
#
# Dependencies (Homebrew on an x86_64 prefix): bison flex gstreamer freetype gnutls sdl2 faudio mpg123
# libpng jpeg sane-backends libgphoto2 molten-vk pkg-config, plus the Xcode CLT. The mingw-w64 cross
# compiler is NOT taken from Homebrew (it tracks whatever GCC is current); this script downloads an
# exact, SHA-pinned xPack GCC toolchain so the PE build is reproducible. The configure flags follow
# Apple's game-porting-toolkit formula and the Gcenx macOS Wine builds; a full Wine build is touchy,
# so pin dependency versions on the runner and tweak per CrossOver release.
#
# Output: ./gamemachine-wine-v1-osx64.tar.xz (CrossOver 26 / Wine 11, the GPTK 4.0-capable base).
# The workflow uploads it to the v1 release.
set -eu

CX_VERSION="${CX_VERSION:-26.2.0}"
BUILD_TAG="${BUILD_TAG:-v1}"
OUTPUT_NAME="${OUTPUT_NAME:-gamemachine-wine-v1-osx64.tar.xz}"
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

# --- mingw-w64 cross-compiler: xPack GCC toolchain (version pinned, currently 15.2.0) -------------
# The Windows PE DLLs are cross-compiled with the xPack prebuilt mingw-w64 GCC. We pin an EXACT version
# (SHA-checked) and download it here instead of Homebrew's mingw-w64 (which tracks whatever GCC is
# current) so the PE build is reproducible. To change toolchains, flip MINGW_GCC_VERSION + XPACK_RELEASE
# + XPACK_SHA256 together (XPACK_HOST stays darwin-x64 for the Rosetta build).
#
# WHY 15.2.0 NOW (and why 13.2.0 was pinned before): we used to pin 13.2.0 as "CrossOver's exact PE
# compiler", on the theory that Blizzard's "eidolon" anti-tamper (Overwatch 2, D2R, D4) was sensitive
# to the exact PE codegen. That theory was WRONG. The real eidolon fix is the CrossOver loader hook
# ("CW HACK 22434") compiled into this engine plus the app's CX_APPLEGPTK_LIBD3DSHARED_PATH env, which
# registers every loaded PE code range as NON-NATIVE with Rosetta (docs/WineBuildStatus.md §13). With
# that in place, our own from-source 13.2.0 build, the 13.4.0 build AND the 15.2.0 build all behaved
# the same way regarding eidolon - so the GCC version was never the cause. We therefore test the latest
# xPack GCC (15.2.0) and verify on a real machine. To fall back to the 13.2.0 CrossOver-parity
# toolchain, set:
#   MINGW_GCC_VERSION=13.2.0 XPACK_RELEASE=13.2.0-1 \
#   XPACK_SHA256=9c2bb3841b991dc07481507f76304397fd1b61ec8cfea973a9fb96dc12c038ae ./build-wine.sh
#
# The xPack tarball ships BOTH i686 + x86_64 targets; XPACK_HOST=darwin-x64 runs natively on an Intel
# runner and under Rosetta on Apple Silicon (the whole build runs under `arch -x86_64`).
MINGW_GCC_VERSION="${MINGW_GCC_VERSION:-15.2.0}"
XPACK_RELEASE="${XPACK_RELEASE:-15.2.0-2}"          # xPack release suffix (GCC version + xPack revision)
XPACK_HOST="${XPACK_HOST:-darwin-x64}"
XPACK_SHA256="${XPACK_SHA256:-f82340a331b932bdb285ddd2d7861a1d5405c80ebf09dd3308aca60637ad418c}"
XPACK_TAG="${XPACK_TAG:-v${XPACK_RELEASE}}"
XPACK_ARCHIVE="xpack-mingw-w64-gcc-${XPACK_RELEASE}-${XPACK_HOST}.tar.gz"
XPACK_URL="https://github.com/xpack-dev-tools/mingw-w64-gcc-xpack/releases/download/${XPACK_TAG}/${XPACK_ARCHIVE}"
XPACK_CACHE="${XPACK_CACHE:-/tmp/${XPACK_ARCHIVE}}"
XPACK_ROOT="${XPACK_ROOT:-/tmp/xpack-mingw-w64-gcc-${XPACK_RELEASE}}"

echo "==> Ensuring xPack mingw-w64 GCC ${MINGW_GCC_VERSION} (PE cross-compiler)"
[ -f "${XPACK_CACHE}" ] || curl -fL "${XPACK_URL}" -o "${XPACK_CACHE}"
echo "${XPACK_SHA256}  ${XPACK_CACHE}" | shasum -a 256 -c - >/dev/null \
  || { echo "ERROR: xPack toolchain SHA-256 mismatch for ${XPACK_CACHE}"; exit 1; }
if [ ! -x "${XPACK_ROOT}/bin/x86_64-w64-mingw32-gcc" ]; then
  rm -rf "${XPACK_ROOT}"; mkdir -p "${XPACK_ROOT}"
  # The tarball has a single top-level xpack-mingw-w64-gcc-*/ dir; --strip-components=1 drops it so
  # bin/ lands directly at ${XPACK_ROOT}/bin (deterministic - no find/mv that could double-nest).
  tar -xzf "${XPACK_CACHE}" -C "${XPACK_ROOT}" --strip-components=1
fi
xattr -dr com.apple.quarantine "${XPACK_ROOT}" 2>/dev/null || true
export PATH="${XPACK_ROOT}/bin:${PATH}"

# Hard pin: both PE target compilers must be EXACTLY ${MINGW_GCC_VERSION}. Fail loudly so a wandering
# Homebrew/PATH mingw-w64 can never silently swap the toolchain out from under the build.
for cc in x86_64-w64-mingw32-gcc i686-w64-mingw32-gcc; do
  v="$("${cc}" -dumpfullversion 2>/dev/null || echo missing)"
  [ "${v}" = "${MINGW_GCC_VERSION}" ] || { echo "ERROR: ${cc} reports '${v}', need exactly ${MINGW_GCC_VERSION}"; exit 1; }
done
echo "    cross GCC: $(x86_64-w64-mingw32-gcc -dumpfullversion) (i686 + x86_64, xPack)"

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
# Wine won't load them from the prefix as native - they must shadow the engine's own builtin
# d3d11/dxgi/... by being searched FIRST on the builtin DLL path. CX26/upstream only APPEND
# WINEDLLPATH after the default dll_dir (set_dll_path: dll_dir is pushed before the WINEDLLPATH
# entries), so a plain WINEDLLPATH never wins. The prepend_dll_path() helper (CW Hack 24067) still
# exists in the source - we only re-wire the env-var caller into set_dll_path(). Without this the
# engine's builtin DXMT always wins and D3DMetal silently never loads. Idempotent (skip if present).
LOADER="${SRC}/dlls/ntdll/unix/loader.c"
if ! grep -q 'WINEDLLPATH_PREPEND' "${LOADER}"; then
  echo "==> Patching loader.c: restore WINEDLLPATH_PREPEND (GPTK D3DMetal DLL shadowing)"
  cat > "${WORK}/gm-prepend.c" <<'CEOF'

    /* GameMachine: re-add CrossOver's WINEDLLPATH_PREPEND (dropped in CX26) so an external dir
       (the GPTK D3DMetal DLLs) can shadow the engine's builtin DLLs by name. Entries are prepended
       in reverse so the first listed dir ends up searched first, ahead of dll_dir.
       OWNERSHIP: prepend_dll_path() stores the pointer it is given WITHOUT copying it (it does
       `dll_paths[0] = path;`), and dll_paths lives for the whole process. So each entry MUST be a
       persistent allocation - we strdup() it. The earlier version passed pointers INTO a strtok'd
       buffer that was then free()'d, leaving dll_paths[0..n] dangling into freed memory that
       set_system_dll_path()/set_home_dir()/set_config_dir() (called right after in init_paths)
       promptly reused - so the GPTK path was silently clobbered and D3DMetal fell back to the
       engine's builtin DXMT. The strdup'd copies are intentionally never freed (matches how
       set_dll_path() strdup's its own WINEDLLPATH entries). */
    if ((path = getenv( "WINEDLLPATH_PREPEND" )) && *path)
    {
        char *gm_path, **gm_entries;
        int gm_n = 0, gm_cap = 1;
        for (p = path; *p; p++) if (*p == ':') gm_cap++;
        gm_entries = malloc( gm_cap * sizeof(*gm_entries) );
        gm_path = strdup( path );
        for (p = strtok( gm_path, ":" ); p; p = strtok( NULL, ":" )) gm_entries[gm_n++] = p;
        while (gm_n > 0) prepend_dll_path( strdup( gm_entries[--gm_n] ) );
        free( gm_entries );
        free( gm_path );
    }
CEOF
  sed -i.bak '/^    dll_paths\[count\] = NULL;$/r '"${WORK}/gm-prepend.c" "${LOADER}"
  rm -f "${LOADER}.bak"
  grep -q 'WINEDLLPATH_PREPEND' "${LOADER}" || { echo "ERROR: WINEDLLPATH_PREPEND patch did not apply"; exit 1; }
fi

# GameMachine: CEF (Chromium Embedded Framework) launchers render broken under winemac with their default
# ANGLE GL backend - Steam's webhelper (steamwebhelper.exe) shows a BLACK frame, and Ubisoft Connect
# (browser host upc.exe + its UplayWebCore.exe gpu/renderer subprocesses) shows a TRANSPARENT/INVISIBLE
# window (the CEF render/gpu process crashes; cf. Whisky #502). Verified for Steam via macdrv/bitblt trace
# that the present path is fine (both ANGLE and SwiftShader present identically through NtGdiStretchBlt) -
# ANGLE just produces no usable frame; the documented CEF-under-Wine fix is to force the software
# SwiftShader GL backend + disable GPU compositing. Applied on every CEF launch (the browser process AND
# its gpu/renderer children, which also go through CreateProcess). Relocates the former per-prefix
# steamwebhelper.exe wrapper into the engine: no binary swap, automatic for all prefixes. Placed in
# CreateProcessInternalW right after CrossOver's own app-specific hacks (Epic/powershell), modifying
# tidy_cmdline (the cmdline actually used downstream; freed at function end). Idempotent (skip if present).
PROC="${SRC}/dlls/kernelbase/process.c"
if ! grep -q 'GameMachine HACK: forcing --use-gl=swiftshader' "${PROC}"; then
  echo "==> Patching process.c: force SwiftShader GL on CEF launchers (Steam black-UI + Ubisoft invisible-window fix)"
  cat > "${WORK}/gm-steam-cef.c" <<'CEOF'
    /* GameMachine HACK: CEF launchers render broken under winemac with their default ANGLE GL backend -
       Steam's webhelper (steamwebhelper.exe) shows a BLACK frame (verified via macdrv/bitblt trace: the
       present path is fine, both ANGLE and SwiftShader present identically through NtGdiStretchBlt -
       ANGLE just produces no usable frame), and Ubisoft Connect (browser host upc.exe + its
       UplayWebCore.exe gpu/renderer subprocesses) shows a TRANSPARENT/INVISIBLE window because the CEF
       render/gpu process crashes (cf. Whisky #502). The documented CEF-under-Wine fix is to force the
       software SwiftShader GL backend + disable GPU compositing. Applied on every CEF process launch
       (the browser process AND its gpu/renderer children, which also pass through CreateProcess), unless
       already set. Same flags the standalone prefix wrapper used, relocated into the engine so no
       per-prefix binary swap is needed. Idempotency marker: --use-gl=swiftshader (Chromium propagates
       it to children, so we don't double-append). */
    if (tidy_cmdline
        && (wcsstr( tidy_cmdline, L"steamwebhelper.exe" )   /* Steam CEF webhelper (browser + children) */
            || wcsstr( tidy_cmdline, L"UplayWebCore.exe" )  /* Ubisoft Connect CEF gpu/renderer subprocess */
            || wcsstr( tidy_cmdline, L"upc.exe" ))          /* Ubisoft Connect CEF browser host */
        && !wcsstr( tidy_cmdline, L"--use-gl=swiftshader" ))
    {
        static const WCHAR gm_cef_flags[] = L" --use-gl=swiftshader --in-process-gpu --no-sandbox --disable-gpu --disable-gpu-compositing";
        DWORD gm_cef_head = lstrlenW( tidy_cmdline );
        DWORD gm_cef_len = gm_cef_head + ARRAY_SIZE( gm_cef_flags );
        WCHAR *gm_cef_cmd = RtlAllocateHeap( GetProcessHeap(), 0, gm_cef_len * sizeof(WCHAR) );
        if (gm_cef_cmd)
        {
            lstrcpyW( gm_cef_cmd, tidy_cmdline );
            lstrcpyW( gm_cef_cmd + gm_cef_head, gm_cef_flags );
            if (tidy_cmdline != cmd_line) RtlFreeHeap( GetProcessHeap(), 0, tidy_cmdline );
            tidy_cmdline = gm_cef_cmd;
            FIXME( "GameMachine HACK: forcing --use-gl=swiftshader on CEF launcher (Steam/Ubisoft)\n" );
        }
    }

CEOF
  GM_BLOCK="${WORK}/gm-steam-cef.c" perl -0777 -i -pe '
    BEGIN { local $/; open my $f,"<",$ENV{GM_BLOCK} or die "$!"; our $b=<$f> }
    s{(\Q    /* Warn if unsupported features are used */\E)}{$b$1};
  ' "${PROC}"
  grep -q 'GameMachine HACK: forcing --use-gl=swiftshader' "${PROC}" || { echo "ERROR: Steam CEF patch did not apply"; exit 1; }
fi

# GameMachine: Disable Metal HUD on launcher processes at the UNIX level.
# Apple's Metal Performance HUD is forced onto any window created by a process with MTL_HUD_ENABLED=1.
# For store launchers (Steam, Epic, Ubisoft), this pollutes the CEF/web UI.
# By unsetting it in the UNIX environment inside ntdll/unix/loader.c immediately AFTER init_environment(),
# the Windows environment block retains the variable (so games inherit it), but the macOS Metal framework
# won't see it on the launcher process.
LOADER_UNIX="${SRC}/dlls/ntdll/unix/loader.c"
if ! grep -q 'MTL_HUD_ENABLED' "${LOADER_UNIX}"; then
  echo "==> Patching loader.c: disable Metal HUD on launcher processes"
  cat > "${WORK}/gm-hud-disable.c" <<'CEOF'

    /* GameMachine HACK: Disable Metal HUD on launcher processes at the UNIX level. */
    {
        extern int *_NSGetArgc(void);
        extern char ***_NSGetArgv(void);
        int gm_argc = *_NSGetArgc();
        char **gm_argv = *_NSGetArgv();
        int gm_i;
        for (gm_i = 0; gm_i < gm_argc; gm_i++) {
            if (gm_argv[gm_i] && (strstr(gm_argv[gm_i], "steam.exe") || strstr(gm_argv[gm_i], "steamwebhelper.exe") ||
                                  strstr(gm_argv[gm_i], "EpicGamesLauncher.exe") || strstr(gm_argv[gm_i], "upc.exe") ||
                                  strstr(gm_argv[gm_i], "UplayWebCore.exe")))
            {
                unsetenv("MTL_HUD_ENABLED");
                break;
            }
        }
    }
CEOF
  GM_BLOCK="${WORK}/gm-hud-disable.c" perl -0777 -i -pe '
    BEGIN { local $/; open my $f,"<",$ENV{GM_BLOCK} or die "$!"; our $b=<$f> }
    s/(init_environment\s*\([^\)]*\)\s*;)/$1\n$b/g;
  ' "${LOADER_UNIX}"
  grep -q 'MTL_HUD_ENABLED' "${LOADER_UNIX}" || { echo "ERROR: Metal HUD patch did not apply"; exit 1; }
fi

# Keep winemac.drv symbols visible for DXMT. CrossOver already exports them; default visibility makes
# sure a toolchain default of -fvisibility=hidden can't strip the Metal bridge.
export CFLAGS="-g -O2 -fvisibility=default -Wno-implicit-function-declaration -Wno-deprecated-declarations -Wno-incompatible-pointer-types"
export CXXFLAGS="${CFLAGS}"
export LDFLAGS="-Wl,-rpath,@loader_path/../../ -Wl,-rpath,${BREW}/lib"
# PE cross-flags: force C17 on the PE side. GCC 15 defaults to C23 (-std=gnu23), where `bool` is a
# reserved keyword, so Wine PE code that still uses `bool` as an identifier (e.g.
# programs/winhlp32/macro.h: `BOOL bool;`) fails to compile. Pinning -std=gnu17 restores the GCC-13/14
# default and keeps the PE side compiling on the newer toolchain. We omit -g (Wine's PE default does
# too) and --strip-all after staging anyway. NOTE: setting CROSSCFLAGS replaces Wine's configure-chosen
# default cross-flags; the earlier worry that this changes codegen and breaks OW2/eidolon is moot - the
# eidolon fix is the CW HACK 22434 loader hook + CX_APPLEGPTK env, not PE codegen (see the GCC note above).
export CROSSCFLAGS="-O2 -std=gnu17"

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

# Strip the PE modules to keep the artifact lean. We already compile the PE side without -g, so there
# are no DWARF sections; --strip-all additionally drops the COFF symbol table (PE exports live in .edata
# and are preserved), which shrinks the download. ONLY the PE .dll/.exe are stripped here - the Mach-O
# unix .so/.dylib are left intact for the ad-hoc signing step below. NOTE: stripping is purely a size
# optimization, NOT an anti-tamper fix - the eidolon/OW2 mitigation is the CW HACK 22434 loader hook +
# CX_APPLEGPTK env, independent of the PE toolchain (see the GCC note above).
echo "==> Stripping PE modules (lean artifact)"
for arch_win in i386-windows x86_64-windows; do
  win_dir="${STAGE}/lib/wine/${arch_win}"
  [ -d "${win_dir}" ] || continue
  case "${arch_win}" in
    i386-windows)   pe_strip="i686-w64-mingw32-strip" ;;
    x86_64-windows) pe_strip="x86_64-w64-mingw32-strip" ;;
  esac
  find "${win_dir}" -type f \( -name '*.dll' -o -name '*.exe' \) -print0 2>/dev/null \
    | while IFS= read -r -d '' f; do "${pe_strip}" --strip-all "$f" 2>/dev/null || true; done
done

# Sanity check that DXMT will find what it needs.
winemac="$(find "${STAGE}/lib/wine" \( -name 'winemac.drv.so' -o -name 'winemac.so' \) -print -quit 2>/dev/null)"
if [ -n "${winemac}" ] && nm -gU "${winemac}" 2>/dev/null | grep -qi 'macdrv'; then
  echo "==> winemac exports macdrv_* (DXMT can bind)"
else
  echo "ERROR: macdrv_* symbols not found in winemac driver; DXMT cannot bind"
  exit 1
fi

# Bundle the shared wine-mono (.NET) and wine-gecko (MSHTML) runtimes so a fresh prefix doesn't
# pop the "Wine could not find a wine-mono/gecko package" download dialog on first launch. These
# are NOT part of the Wine source tree (they are separate prebuilt packages), so a from-source
# build omits them unless we add them here, exactly like the Gcenx/CrossOver macOS packages do.
# The versions are read from the very source we compile (dlls/appwiz.cpl/addons.c) so they always
# match the engine and auto-track a CrossOver bump - no hardcoding. mscoree looks for the runtime
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

fetch() {  # url cache_path  - download once, reuse on re-runs (like the source tarball)
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

echo "==> Bundling native runtime dependencies"
BUNDLE_LIB_DIR="${STAGE}/lib"
BUNDLE_DEPS="${WORK}/bundle-native-deps.txt"
mkdir -p "${BUNDLE_LIB_DIR}"

collect_external_deps() {
  : > "$1"
  find "${STAGE}" \( -path "${STAGE}/share/wine/mono" -o -path "${STAGE}/share/wine/gecko" \) -prune -o \
    -type f \( -name '*.dylib' -o -name '*.so' -o -perm -111 \) -print0 2>/dev/null \
    | while IFS= read -r -d '' f; do
        if file "$f" | grep -q Mach-O; then
          otool -L "$f" | awk 'NR > 1 { print $1 }' | while IFS= read -r dep; do
            case "$dep" in
              /usr/lib/*|/System/Library/*|@rpath/*|@loader_path/*|@executable_path/*) ;;
              *) printf '%s	%s\n' "$f" "$dep" >> "$1" ;;
            esac
          done
        fi
      done
}

bundle_external_deps() {
  collect_external_deps "${BUNDLE_DEPS}"
  [ -s "${BUNDLE_DEPS}" ] || return 1

  sort -u "${BUNDLE_DEPS}" | while IFS="$(printf '\t')" read -r owner dep; do
    [ -f "${dep}" ] || { echo "ERROR: dependency not found: ${owner#${STAGE}/} -> ${dep}"; exit 1; }
    leaf="$(basename "${dep}")"
    dest="${BUNDLE_LIB_DIR}/${leaf}"

    if [ ! -f "${dest}" ]; then
      cp -p "${dep}" "${dest}"
      chmod u+w "${dest}" 2>/dev/null || true
      install_name_tool -id "@loader_path/${leaf}" "${dest}" 2>/dev/null || true
      echo "    bundled ${leaf}"
    fi

    chmod u+w "${owner}" 2>/dev/null || true
    case "${owner#${STAGE}/}" in
      bin/*) replacement="@loader_path/../lib/${leaf}" ;;
      lib/wine/*) replacement="@loader_path/../../${leaf}" ;;
      lib/*) replacement="@loader_path/${leaf}" ;;
      *) replacement="@rpath/${leaf}" ;;
    esac
    install_name_tool -change "${dep}" "${replacement}" "${owner}"
  done
}

while bundle_external_deps; do :; done

echo "==> Auditing native runtime dependencies"
BAD_DEPS="${WORK}/bad-native-deps.txt"
collect_external_deps "${BAD_DEPS}"
if [ -s "${BAD_DEPS}" ]; then
  echo "ERROR: non-system native dependencies found in the Wine artifact:"
  awk -F "$(printf '\t')" '{ print $1 " -> " $2 }' "${BAD_DEPS}"
  echo "Bundle these libraries in wswine.bundle/lib or disable the feature before release."
  exit 1
fi

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
