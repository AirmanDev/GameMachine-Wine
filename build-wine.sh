#!/bin/sh
# Builds the GameMachine Wine runtime from CodeWeavers' published CrossOver source.
set -eu

CX_VERSION="${CX_VERSION:-26.2.0}"
BUILD_TAG="${BUILD_TAG:-v1}"
OUTPUT_NAME="${OUTPUT_NAME:-gamemachine-wine-v1-osx64.tar.xz}"
MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
SOURCE_URL="${SOURCE_URL:-https://media.codeweavers.com/pub/crossover/source/crossover-sources-${CX_VERSION}.tar.gz}"
SOURCE_SHA256="${SOURCE_SHA256:-}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
OUT_DIR="${OUT_DIR:-$(pwd -P)}"
KEEP_WORK="${KEEP_WORK:-0}"

MINGW_GCC_VERSION="${MINGW_GCC_VERSION:-15.2.0}"
XPACK_RELEASE="${XPACK_RELEASE:-15.2.0-2}"
XPACK_HOST="${XPACK_HOST:-darwin-x64}"
XPACK_SHA256="${XPACK_SHA256:-f82340a331b932bdb285ddd2d7861a1d5405c80ebf09dd3308aca60637ad418c}"
XPACK_TAG="${XPACK_TAG:-v${XPACK_RELEASE}}"
XPACK_ARCHIVE="xpack-mingw-w64-gcc-${XPACK_RELEASE}-${XPACK_HOST}.tar.gz"
XPACK_URL="https://github.com/xpack-dev-tools/mingw-w64-gcc-xpack/releases/download/${XPACK_TAG}/${XPACK_ARCHIVE}"
XPACK_CACHE="${XPACK_CACHE:-/tmp/${XPACK_ARCHIVE}}"
XPACK_ROOT="${XPACK_ROOT:-/tmp/xpack-mingw-w64-gcc-${XPACK_RELEASE}}"

LAUNCHER_PROCESSES="steam.exe steamwebhelper.exe EpicGamesLauncher.exe EpicWebHelper.exe upc.exe UplayWebCore.exe"
CEF_PROCESSES="steamwebhelper.exe upc.exe UplayWebCore.exe"
CEF_FLAGS="--use-gl=swiftshader --use-angle=swiftshader --in-process-gpu --no-sandbox --disable-gpu --disable-gpu-compositing"

WORK="$(mktemp -d /tmp/gm-wine-build.XXXXXX)"
STAGE="${WORK}/stage/wswine.bundle"
SRC="${WORK}/sources/wine"
BUILD="${WORK}/build"
TARBALL="${TARBALL_CACHE:-/tmp/crossover-sources-${CX_VERSION}.tar.gz}"

BREW="${HOMEBREW_PREFIX:-$(brew --prefix 2>/dev/null || echo /usr/local)}"
export MACOSX_DEPLOYMENT_TARGET
export PATH="${BREW}/opt/bison/bin:${BREW}/opt/flex/bin:${BREW}/bin:${PATH}"

cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  if [ "${KEEP_WORK}" = "1" ] && [ "${status}" -ne 0 ]; then
    echo "==> Build failed; work directory kept at ${WORK}" >&2
  else
    rm -rf "${WORK}"
  fi
  exit "${status}"
}
trap cleanup EXIT HUP INT TERM

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

download_cached() {
  url=$1
  destination=$2

  [ -f "${destination}" ] && return 0

  mkdir -p "$(dirname "${destination}")"
  temporary="${destination}.part.$$"
  rm -f "${temporary}"
  if ! curl -fL --retry 3 --retry-delay 2 "${url}" -o "${temporary}"; then
    rm -f "${temporary}"
    fail "download failed: ${url}"
  fi
  mv "${temporary}" "${destination}"
}

verify_sha256() {
  expected=$1
  file=$2
  label=$3

  echo "${expected}  ${file}" | shasum -a 256 -c - >/dev/null \
    || fail "${label} SHA-256 mismatch: ${file}"
}

insert_before_literal() {
  target=$1
  marker=$2
  block=$3

  GM_MARKER="${marker}" GM_BLOCK="${block}" perl -0777 -i -pe '
    BEGIN {
      open my $fh, "<", $ENV{GM_BLOCK} or die "$ENV{GM_BLOCK}: $!";
      our $block = do { local $/; <$fh> };
      our $marker = $ENV{GM_MARKER};
      our $matches = 0;
    }
    $matches += s{\Q$marker\E}{$block$marker};
    END { die "patch marker not found exactly once: $marker\n" unless $matches == 1; }
  ' "${target}"
}

insert_after_regex() {
  target=$1
  pattern=$2
  block=$3

  GM_PATTERN="${pattern}" GM_BLOCK="${block}" perl -0777 -i -pe '
    BEGIN {
      open my $fh, "<", $ENV{GM_BLOCK} or die "$ENV{GM_BLOCK}: $!";
      our $block = do { local $/; <$fh> };
      our $pattern = $ENV{GM_PATTERN};
      our $matches = 0;
    }
    $matches += s{($pattern)}{$1$block};
    END { die "patch pattern not found exactly once: $pattern\n" unless $matches == 1; }
  ' "${target}"
}

write_char_entries() {
  for value in $1; do
    printf '            "%s",\n' "${value}"
  done
}

write_wchar_entries() {
  for value in $1; do
    printf '            L"%s",\n' "${value}"
  done
}

mkdir -p "${OUT_DIR}"

echo "==> Building Wine from CrossOver ${CX_VERSION} (tag ${BUILD_TAG})"
echo "    work: ${WORK}"
echo "    brew: ${BREW}"

echo "==> Ensuring xPack mingw-w64 GCC ${MINGW_GCC_VERSION}"
download_cached "${XPACK_URL}" "${XPACK_CACHE}"
verify_sha256 "${XPACK_SHA256}" "${XPACK_CACHE}" "xPack toolchain"

if [ ! -x "${XPACK_ROOT}/bin/x86_64-w64-mingw32-gcc" ] || \
   [ ! -x "${XPACK_ROOT}/bin/i686-w64-mingw32-gcc" ]; then
  rm -rf "${XPACK_ROOT}"
  mkdir -p "${XPACK_ROOT}"
  tar -xzf "${XPACK_CACHE}" -C "${XPACK_ROOT}" --strip-components=1
fi

xattr -dr com.apple.quarantine "${XPACK_ROOT}" 2>/dev/null || true
export PATH="${XPACK_ROOT}/bin:${PATH}"

for cc in x86_64-w64-mingw32-gcc i686-w64-mingw32-gcc; do
  version="$("${cc}" -dumpfullversion 2>/dev/null || echo missing)"
  [ "${version}" = "${MINGW_GCC_VERSION}" ] \
    || fail "${cc} reports '${version}', expected '${MINGW_GCC_VERSION}'"
done

echo "    cross GCC: $(x86_64-w64-mingw32-gcc -dumpfullversion)"

echo "==> Downloading CrossOver source"
download_cached "${SOURCE_URL}" "${TARBALL}"
if [ -n "${SOURCE_SHA256}" ]; then
  verify_sha256 "${SOURCE_SHA256}" "${TARBALL}" "CrossOver source"
fi

echo "==> Extracting sources/wine"
tar -xzf "${TARBALL}" -C "${WORK}" sources/wine
[ -x "${SRC}/configure" ] || fail "Wine configure script not found at ${SRC}"

cat > "${SRC}/programs/winedbg/distversion.h" <<'EOF'
#define WINDEBUG_WHAT_HAPPENED_MESSAGE "The program encountered a problem and stopped working."
#define WINDEBUG_USER_SUGGESTION_MESSAGE "Please relaunch the application. If the problem persists, reinstall it."
EOF


# App-specific helpers may keep normal windows while remaining outside the macOS Dock.
MACDRV_MAIN="${SRC}/dlls/winemac.drv/macdrv_main.c"
MACDRV_COCOA="${SRC}/dlls/winemac.drv/macdrv_cocoa.h"
COCOA_APP="${SRC}/dlls/winemac.drv/cocoa_app.m"
if ! grep -q '"HideDockIcon"' "${MACDRV_MAIN}"; then
  echo "==> Patching winemac.drv: app-specific Dock visibility"
  python3 - "${MACDRV_MAIN}" "${MACDRV_COCOA}" "${COCOA_APP}" <<'PYDOCK'
from pathlib import Path
import sys

main_path, cocoa_path, app_path = map(Path, sys.argv[1:])

def replace_once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"ERROR: {label} patch expected one match, found {count}")
    return text.replace(old, new, 1)

main = main_path.read_text(encoding="utf-8")
cocoa = cocoa_path.read_text(encoding="utf-8")
app = app_path.read_text(encoding="utf-8")

main = replace_once(
    main,
    "bool enable_app_nap = false;\n",
    "bool enable_app_nap = false;\nbool hide_dock_icon = false;\n",
    "macdrv global",
)
main = replace_once(
    main,
    '''    if (!get_config_key(hkey, appkey, "EnableAppNap", buffer, sizeof(buffer)))
        enable_app_nap = IS_OPTION_TRUE(buffer[0]);
''',
    '''    if (!get_config_key(hkey, appkey, "EnableAppNap", buffer, sizeof(buffer)))
        enable_app_nap = IS_OPTION_TRUE(buffer[0]);

    if (!get_config_key(hkey, appkey, "HideDockIcon", buffer, sizeof(buffer)))
        hide_dock_icon = IS_OPTION_TRUE(buffer[0]);
''',
    "macdrv registry option",
)
cocoa = replace_once(
    cocoa,
    "extern bool enable_app_nap;\n",
    "extern bool enable_app_nap;\nextern bool hide_dock_icon;\n",
    "macdrv declaration",
)
app = replace_once(
    app,
    '''    - (void) transformProcessToForeground:(BOOL)activateIfTransformed
    {
        if ([NSApp activationPolicy] != NSApplicationActivationPolicyRegular)
''',
    '''    - (void) transformProcessToForeground:(BOOL)activateIfTransformed
    {
        if (hide_dock_icon)
        {
            if ([NSApp activationPolicy] != NSApplicationActivationPolicyAccessory)
                [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
            if (activateIfTransformed)
                [self tryToActivateIgnoringOtherApps:YES];
            return;
        }

        if ([NSApp activationPolicy] != NSApplicationActivationPolicyRegular)
''',
    "Cocoa activation policy",
)

main_path.write_text(main, encoding="utf-8")
cocoa_path.write_text(cocoa, encoding="utf-8")
app_path.write_text(app, encoding="utf-8")
PYDOCK
fi

# GameMachine: set per-executable macOS application names before Dock registration.
MACDRV_MAIN="${SRC}/dlls/winemac.drv/macdrv_main.c"
MACDRV_COCOA="${SRC}/dlls/winemac.drv/macdrv_cocoa.h"
COCOA_APP="${SRC}/dlls/winemac.drv/cocoa_app.m"
if ! grep -q 'GameMachine: set per-executable macOS application names' "${MACDRV_MAIN}"; then
  echo "==> Patching winemac.drv: per-executable application names"
  python3 - "${MACDRV_MAIN}" "${MACDRV_COCOA}" "${COCOA_APP}" <<'PYNAME'
from pathlib import Path
import sys

main_path, cocoa_path, app_path = map(Path, sys.argv[1:])


def replace_once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"ERROR: {label} patch expected one match, found {count}")
    return text.replace(old, new, 1)


main = main_path.read_text(encoding="utf-8")
cocoa = cocoa_path.read_text(encoding="utf-8")
app = app_path.read_text(encoding="utf-8")

main = replace_once(
    main,
    "bool hide_dock_icon = false;\n",
    "bool hide_dock_icon = false;\nchar *application_display_name;\n",
    "application name global",
)
main = replace_once(
    main,
    '''    len = lstrlenW(appname);

    if (len && len < MAX_PATH)
''',
    '''    len = lstrlenW(appname);

    /* GameMachine: set per-executable macOS application names from the launch environment. */
    for (unsigned int i = 0; i < 8; i++)
    {
        char executable_key[64], name_key[64];
        const char *configured_executable, *configured_name;
        WCHAR configured_executableW[MAX_PATH];
        size_t configured_length;

        snprintf(executable_key, sizeof(executable_key), "GAMEMACHINE_DOCK_EXECUTABLE_%u", i);
        snprintf(name_key, sizeof(name_key), "GAMEMACHINE_DOCK_NAME_%u", i);
        configured_executable = getenv(executable_key);
        configured_name = getenv(name_key);
        if (!configured_executable || !*configured_executable || !configured_name || !*configured_name) continue;

        configured_length = strlen(configured_executable);
        if (configured_length >= ARRAY_SIZE(configured_executableW)) continue;
        asciiz_to_unicode(configured_executableW, configured_executable);

        if (!wcsicmp(appname, configured_executableW))
        {
            application_display_name = strdup(configured_name);
            break;
        }
    }

    if (len && len < MAX_PATH)
''',
    "application name selection",
)
cocoa = replace_once(
    cocoa,
    "extern bool hide_dock_icon;\n",
    "extern bool hide_dock_icon;\nextern char *application_display_name;\n",
    "application name declaration",
)
app = replace_once(
    app,
    '''    - (void) transformProcessToForeground:(BOOL)activateIfTransformed
    {
        if (hide_dock_icon)
''',
    '''    - (void) transformProcessToForeground:(BOOL)activateIfTransformed
    {
        if (application_display_name)
        {
            NSString *name = [NSString stringWithUTF8String:application_display_name];
            if ([name length]) [[NSProcessInfo processInfo] setProcessName:name];
        }

        if (hide_dock_icon)
''',
    "process name assignment",
)
app = replace_once(
    app,
    '''            bundleName = [[NSBundle mainBundle] objectForInfoDictionaryKey:(NSString*)kCFBundleNameKey];
''',
    '''            bundleName = application_display_name ? [[NSProcessInfo processInfo] processName] :
                         [[NSBundle mainBundle] objectForInfoDictionaryKey:(NSString*)kCFBundleNameKey];
''',
    "application menu name",
)

main_path.write_text(main, encoding="utf-8")
cocoa_path.write_text(cocoa, encoding="utf-8")
app_path.write_text(app, encoding="utf-8")
PYNAME
fi

LOADER="${SRC}/dlls/ntdll/unix/loader.c"
if ! grep -q 'WINEDLLPATH_PREPEND' "${LOADER}"; then
  echo "==> Restoring WINEDLLPATH_PREPEND"
  cat > "${WORK}/gm-prepend.c" <<'CEOF'

    /* Allow an external builtin DLL directory to shadow the engine DLL directory. */
    if ((path = getenv( "WINEDLLPATH_PREPEND" )) && *path)
    {
        char *gm_path, **gm_entries;
        int gm_count = 0, gm_capacity = 1;

        for (p = path; *p; p++) if (*p == ':') gm_capacity++;
        if (!(gm_entries = malloc( gm_capacity * sizeof(*gm_entries) ))) abort();
        if (!(gm_path = strdup( path ))) abort();

        for (p = strtok( gm_path, ":" ); p; p = strtok( NULL, ":" ))
            gm_entries[gm_count++] = p;

        while (gm_count > 0)
        {
            char *gm_entry = strdup( gm_entries[--gm_count] );
            if (!gm_entry) abort();
            prepend_dll_path( gm_entry );
        }

        free( gm_entries );
        free( gm_path );
    }
CEOF
  sed -i.bak '/^    dll_paths\[count\] = NULL;$/r '"${WORK}/gm-prepend.c" "${LOADER}"
  rm -f "${LOADER}.bak"
  grep -q 'WINEDLLPATH_PREPEND' "${LOADER}" \
    || fail "WINEDLLPATH_PREPEND patch did not apply"
fi

EPIC_OPENGL_MARKER='GameMachine: force Epic Games Launcher to use OpenGL'
if ! grep -q "${EPIC_OPENGL_MARKER}" "${LOADER}"; then
  echo "==> Forcing Epic Games Launcher to use its OpenGL renderer"
  cat > "${WORK}/gm-epic-opengl.c" <<'CEOF'
    /* GameMachine: force Epic Games Launcher to use OpenGL under winemac.
       This runs in __wine_main before Wine stores argc/argv, so it covers the initial `wine EXE`
       invocation as well as launcher self-restarts and updater-spawned Wine processes. The argv
       allocation intentionally lives for the process lifetime because main_argv retains it. */
    {
        int gm_arg;
        int gm_epic = 0;
        int gm_has_opengl = 0;

        for (gm_arg = 1; gm_arg < argc; gm_arg++)
        {
            if (!argv[gm_arg]) continue;
            if (strstr( argv[gm_arg], "EpicGamesLauncher.exe" )) gm_epic = 1;
            if (!strcmp( argv[gm_arg], "-opengl" )) gm_has_opengl = 1;
        }

        if (gm_epic && !gm_has_opengl)
        {
            char **gm_argv = malloc( (argc + 2) * sizeof(*gm_argv) );
            if (!gm_argv) abort();

            memcpy( gm_argv, argv, argc * sizeof(*gm_argv) );
            gm_argv[argc] = strdup( "-opengl" );
            if (!gm_argv[argc]) abort();
            gm_argv[argc + 1] = NULL;

            argv = gm_argv;
            argc++;
        }
    }

CEOF
  insert_before_literal "${LOADER}" '    main_argc = argc;' "${WORK}/gm-epic-opengl.c"
  grep -q "${EPIC_OPENGL_MARKER}" "${LOADER}" \
    || fail "Epic Games Launcher OpenGL patch did not apply"
fi

KERNELBASE_PROCESS="${SRC}/dlls/kernelbase/process.c"
CEF_MARKER='GameMachine: software rendering for Steam and Ubisoft embedded browser processes'
if ! grep -q "${CEF_MARKER}" "${KERNELBASE_PROCESS}"; then
  echo "==> Enabling software rendering for Steam and Ubisoft browser processes"
  {
    cat <<'CEOF'
    /* GameMachine: software rendering for Steam and Ubisoft embedded browser processes.
       Epic Games Launcher must not receive these Chromium flags; it uses its own -opengl path. */
    if (tidy_cmdline)
    {
        static const WCHAR *const gm_cef_processes[] =
        {
CEOF
    write_wchar_entries "${CEF_PROCESSES}"
    cat <<'CEOF'
        };
        static const WCHAR *const gm_cef_flags[] =
        {
CEOF
    write_wchar_entries "${CEF_FLAGS}"
    cat <<'CEOF'
        };
        BOOL gm_cef_process = FALSE;
        SIZE_T gm_chars;
        unsigned int gm_index;

        for (gm_index = 0; gm_index < ARRAY_SIZE( gm_cef_processes ); gm_index++)
        {
            if (wcsstr( tidy_cmdline, gm_cef_processes[gm_index] ))
            {
                gm_cef_process = TRUE;
                break;
            }
        }

        if (gm_cef_process)
        {
            DWORD gm_head = lstrlenW( tidy_cmdline );
            WCHAR *gm_cmdline, *gm_tail;

            gm_chars = gm_head + 1;
            for (gm_index = 0; gm_index < ARRAY_SIZE( gm_cef_flags ); gm_index++)
            {
                if (!wcsstr( tidy_cmdline, gm_cef_flags[gm_index] ))
                    gm_chars += 1 + lstrlenW( gm_cef_flags[gm_index] );
            }

            if (gm_chars > gm_head + 1 &&
                (gm_cmdline = RtlAllocateHeap( GetProcessHeap(), 0,
                                               gm_chars * sizeof(*gm_cmdline) )))
            {
                lstrcpyW( gm_cmdline, tidy_cmdline );
                gm_tail = gm_cmdline + gm_head;

                for (gm_index = 0; gm_index < ARRAY_SIZE( gm_cef_flags ); gm_index++)
                {
                    if (!wcsstr( tidy_cmdline, gm_cef_flags[gm_index] ))
                    {
                        *gm_tail++ = ' ';
                        lstrcpyW( gm_tail, gm_cef_flags[gm_index] );
                        gm_tail += lstrlenW( gm_cef_flags[gm_index] );
                    }
                }

                if (tidy_cmdline != cmd_line)
                    RtlFreeHeap( GetProcessHeap(), 0, tidy_cmdline );
                tidy_cmdline = gm_cmdline;
                FIXME( "GameMachine: enabled software rendering for an embedded browser process\n" );
            }
        }
    }

CEOF
  } > "${WORK}/gm-cef.c"
  insert_before_literal "${KERNELBASE_PROCESS}" '    /* Warn if unsupported features are used */' "${WORK}/gm-cef.c"
  grep -q "${CEF_MARKER}" "${KERNELBASE_PROCESS}" \
    || fail "embedded browser rendering patch did not apply"
fi

LOADER_HUD_MARKER='GameMachine: route the Metal HUD for launcher processes'
if ! grep -q "${LOADER_HUD_MARKER}" "${LOADER}"; then
  echo "==> Routing the Metal HUD for launcher processes"
  {
    cat <<'CEOF'

    /* GameMachine: route the Metal HUD for launcher processes. */
    {
        static const char *const gm_launchers[] =
        {
CEOF
    write_char_entries "${LAUNCHER_PROCESSES}"
    cat <<'CEOF'
        };
        extern int *_NSGetArgc(void);
        extern char ***_NSGetArgv(void);
        int gm_argc = *_NSGetArgc();
        char **gm_argv = *_NSGetArgv();
        int gm_launcher = 0;
        int gm_arg;
        unsigned int gm_index;

        for (gm_arg = 0; gm_arg < gm_argc && !gm_launcher; gm_arg++)
        {
            if (!gm_argv[gm_arg]) continue;
            for (gm_index = 0; gm_index < ARRAY_SIZE( gm_launchers ); gm_index++)
            {
                if (strstr( gm_argv[gm_arg], gm_launchers[gm_index] ))
                {
                    gm_launcher = 1;
                    break;
                }
            }
        }

        if (gm_launcher)
        {
            const char *gm_hud = getenv( "MTL_HUD_ENABLED" );
            if (gm_hud && !getenv( "GM_MTL_HUD_ENABLED" ))
                setenv( "GM_MTL_HUD_ENABLED", gm_hud, 1 );
            unsetenv( "MTL_HUD_ENABLED" );
        }
    }
CEOF
  } > "${WORK}/gm-hud-loader.c"
  insert_before_literal "${LOADER}" '    start_main_thread();' "${WORK}/gm-hud-loader.c"
  grep -q "${LOADER_HUD_MARKER}" "${LOADER}" \
    || fail "launcher Metal HUD patch did not apply"
fi

NTDLL_PROCESS="${SRC}/dlls/ntdll/unix/process.c"
HUD_CHILD_MARKER='GameMachine: restore the Metal HUD for launcher-spawned games'
if ! grep -q "${HUD_CHILD_MARKER}" "${NTDLL_PROCESS}"; then
  echo "==> Restoring the Metal HUD for launcher-spawned games"
  {
    cat <<'CEOF'

#ifdef __APPLE__
            /* GameMachine: restore the Metal HUD for launcher-spawned games. */
            {
                static const char *const gm_launchers[] =
                {
CEOF
    write_char_entries "${LAUNCHER_PROCESSES}"
    cat <<'CEOF'
                };
                const char *gm_saved_hud = getenv( "GM_MTL_HUD_ENABLED" );
                char gm_image[2048];
                int gm_launcher = 0;
                int gm_length = 0;
                unsigned int gm_index;

                if (params->ImagePathName.Buffer)
                {
                    gm_length = ntdll_wcstoumbs( params->ImagePathName.Buffer,
                                                 params->ImagePathName.Length / sizeof(WCHAR),
                                                 gm_image, sizeof(gm_image) - 1, FALSE );
                    if (gm_length > 0)
                    {
                        gm_image[gm_length] = 0;
                        for (gm_index = 0; gm_index < ARRAY_SIZE( gm_launchers ); gm_index++)
                        {
                            if (strstr( gm_image, gm_launchers[gm_index] ))
                            {
                                gm_launcher = 1;
                                break;
                            }
                        }
                    }
                }

                if (gm_launcher)
                    unsetenv( "MTL_HUD_ENABLED" );
                else if (gm_saved_hud)
                    setenv( "MTL_HUD_ENABLED", gm_saved_hud, 1 );
            }
#endif
CEOF
  } > "${WORK}/gm-hud-child.c"
  insert_after_regex "${NTDLL_PROCESS}" '\n\s*if \(winedebug\) putenv\( winedebug \);' "${WORK}/gm-hud-child.c"
  grep -q "${HUD_CHILD_MARKER}" "${NTDLL_PROCESS}" \
    || fail "child Metal HUD patch did not apply"
fi

export CFLAGS="-g -O2 -fvisibility=default -Wno-implicit-function-declaration -Wno-deprecated-declarations -Wno-incompatible-pointer-types"
export CXXFLAGS="${CFLAGS}"
export LDFLAGS="-Wl,-rpath,@loader_path/../../ -Wl,-rpath,${BREW}/lib"
export CROSSCFLAGS="-O2 -std=gnu17"

echo "==> Configuring Wine"
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

echo "==> Building with ${JOBS} jobs"
make -j"${JOBS}"
make install

echo "==> Staging wswine.bundle"
mkdir -p "${STAGE}"
cp -R "${WORK}/stage-prefix/." "${STAGE}/"

echo "==> Stripping PE modules"
for arch_win in i386-windows x86_64-windows; do
  win_dir="${STAGE}/lib/wine/${arch_win}"
  [ -d "${win_dir}" ] || continue

  case "${arch_win}" in
    i386-windows) pe_strip="i686-w64-mingw32-strip" ;;
    x86_64-windows) pe_strip="x86_64-w64-mingw32-strip" ;;
  esac

  find "${win_dir}" -type f \( -name '*.dll' -o -name '*.exe' \) -print 2>/dev/null \
    | while IFS= read -r file_path; do
        "${pe_strip}" --strip-all "${file_path}" 2>/dev/null || true
      done
done

winemac="$(find "${STAGE}/lib/wine" \( -name 'winemac.drv.so' -o -name 'winemac.so' \) -print -quit 2>/dev/null)"
if [ -n "${winemac}" ] && nm -gU "${winemac}" 2>/dev/null | grep -qi 'macdrv'; then
  echo "==> winemac exports macdrv_*"
else
  fail "macdrv_* symbols are not exported by winemac"
fi

echo "==> Bundling Wine Mono and Gecko"
ADDONS="${SRC}/dlls/appwiz.cpl/addons.c"
MONO_VERSION="$(awk -F'"' '/#define[[:space:]]+MONO_VERSION/{print $2; exit}' "${ADDONS}")"
GECKO_VERSION="$(awk -F'"' '/#define[[:space:]]+GECKO_VERSION/{print $2; exit}' "${ADDONS}")"
[ -n "${MONO_VERSION}" ] && [ -n "${GECKO_VERSION}" ] \
  || fail "could not read Wine Mono/Gecko versions from ${ADDONS}"

MONO_DIR="${STAGE}/share/wine/mono"
GECKO_DIR="${STAGE}/share/wine/gecko"
mkdir -p "${MONO_DIR}" "${GECKO_DIR}"

MONO_TARBALL="/tmp/wine-mono-${MONO_VERSION}-x86.tar.xz"
download_cached \
  "https://dl.winehq.org/wine/wine-mono/${MONO_VERSION}/wine-mono-${MONO_VERSION}-x86.tar.xz" \
  "${MONO_TARBALL}"
tar -xJf "${MONO_TARBALL}" -C "${MONO_DIR}"

for gecko_arch in x86 x86_64; do
  gecko_tarball="/tmp/wine-gecko-${GECKO_VERSION}-${gecko_arch}.tar.xz"
  download_cached \
    "https://dl.winehq.org/wine/wine-gecko/${GECKO_VERSION}/wine-gecko-${GECKO_VERSION}-${gecko_arch}.tar.xz" \
    "${gecko_tarball}"
  tar -xJf "${gecko_tarball}" -C "${GECKO_DIR}"
done

[ -d "${MONO_DIR}/wine-mono-${MONO_VERSION}" ] \
  || fail "Wine Mono extracted to an unexpected directory"
[ -d "${GECKO_DIR}/wine-gecko-${GECKO_VERSION}-x86" ] \
  || fail "32-bit Wine Gecko extracted to an unexpected directory"
[ -d "${GECKO_DIR}/wine-gecko-${GECKO_VERSION}-x86_64" ] \
  || fail "64-bit Wine Gecko extracted to an unexpected directory"

echo "==> Bundling native runtime dependencies"
BUNDLE_LIB_DIR="${STAGE}/lib"
BUNDLE_DEPS="${WORK}/bundle-native-deps.txt"
BUNDLE_DEPS_SORTED="${WORK}/bundle-native-deps.sorted.txt"
MACHO_FILES="${WORK}/macho-files.txt"
OTOOL_DEPS="${WORK}/otool-deps.txt"
mkdir -p "${BUNDLE_LIB_DIR}"

collect_external_deps() {
  output=$1
  : > "${output}"
  : > "${MACHO_FILES}"

  find "${STAGE}" \
    \( -path "${STAGE}/share/wine/mono" -o -path "${STAGE}/share/wine/gecko" \) -prune -o \
    -type f \( -name '*.dylib' -o -name '*.so' -o -perm -111 \) -print 2>/dev/null \
    > "${MACHO_FILES}"

  while IFS= read -r owner; do
    file "${owner}" | grep -q 'Mach-O' || continue
    otool -L "${owner}" | awk 'NR > 1 { print $1 }' > "${OTOOL_DEPS}"

    while IFS= read -r dependency; do
      case "${dependency}" in
        /usr/lib/*|/System/Library/*|@rpath/*|@loader_path/*|@executable_path/*|'')
          ;;
        *'|'*)
          fail "unsupported '|' character in dependency path: ${owner} -> ${dependency}"
          ;;
        *)
          printf '%s|%s\n' "${owner}" "${dependency}" >> "${output}"
          ;;
      esac
    done < "${OTOOL_DEPS}"
  done < "${MACHO_FILES}"
}

bundle_external_deps() {
  collect_external_deps "${BUNDLE_DEPS}"
  [ -s "${BUNDLE_DEPS}" ] || return 1

  LC_ALL=C sort -u "${BUNDLE_DEPS}" > "${BUNDLE_DEPS_SORTED}"

  while IFS='|' read -r owner dependency; do
    [ -n "${owner}" ] && [ -n "${dependency}" ] \
      || fail "malformed native dependency record: ${owner}|${dependency}"
    [ -f "${owner}" ] || fail "dependency owner not found: ${owner}"
    [ -f "${dependency}" ] \
      || fail "dependency not found: ${owner#${STAGE}/} -> ${dependency}"

    leaf="$(basename "${dependency}")"
    destination="${BUNDLE_LIB_DIR}/${leaf}"

    if [ ! -f "${destination}" ]; then
      cp -p "${dependency}" "${destination}"
      chmod u+w "${destination}" 2>/dev/null || true
      install_name_tool -id "@loader_path/${leaf}" "${destination}" 2>/dev/null || true
      echo "    bundled ${leaf}"
    fi

    chmod u+w "${owner}" 2>/dev/null || true
    case "${owner#${STAGE}/}" in
      bin/*) replacement="@loader_path/../lib/${leaf}" ;;
      lib/wine/*) replacement="@loader_path/../../${leaf}" ;;
      lib/*) replacement="@loader_path/${leaf}" ;;
      *) replacement="@rpath/${leaf}" ;;
    esac

    install_name_tool -change "${dependency}" "${replacement}" "${owner}" \
      || fail "could not rewrite dependency: ${owner#${STAGE}/}: ${dependency} -> ${replacement}"
  done < "${BUNDLE_DEPS_SORTED}"

  return 0
}

while :; do
  if bundle_external_deps; then
    :
  else
    bundle_status=$?
    [ "${bundle_status}" -eq 1 ] && break
    exit "${bundle_status}"
  fi
done

echo "==> Auditing native runtime dependencies"
BAD_DEPS="${WORK}/bad-native-deps.txt"
collect_external_deps "${BAD_DEPS}"
if [ -s "${BAD_DEPS}" ]; then
  echo "ERROR: non-system native dependencies remain in the Wine artifact:" >&2
  awk -F '|' '{ print "  " $1 " -> " $2 }' "${BAD_DEPS}" >&2
  exit 1
fi

echo "==> Ad-hoc signing native Mach-O files"
: > "${MACHO_FILES}"
find "${STAGE}" \
  \( -path "${STAGE}/share/wine/mono" -o -path "${STAGE}/share/wine/gecko" \) -prune -o \
  -type f \( -name '*.dylib' -o -name '*.so' -o -perm -111 \) -print 2>/dev/null \
  > "${MACHO_FILES}"

while IFS= read -r file_path; do
  file "${file_path}" | grep -q 'Mach-O' || continue
  codesign --force -s - "${file_path}" >/dev/null \
    || fail "could not sign ${file_path#${STAGE}/}"
done < "${MACHO_FILES}"

echo "==> Packing ${OUTPUT_NAME}"
cd "${WORK}/stage"
COPYFILE_DISABLE=1 XZ_OPT=-6 tar -cJf "${OUT_DIR}/${OUTPUT_NAME}" wswine.bundle
[ -s "${OUT_DIR}/${OUTPUT_NAME}" ] || fail "output archive was not created"

echo "==> Done: ${OUT_DIR}/${OUTPUT_NAME}"
