#!/usr/bin/env bash
set -euo pipefail

log_step() {
  echo
  echo "============================================================"
  echo ">>> $1"
  echo "============================================================"
}

trap 'echo "ERROR: build failed at line $LINENO while running: $BASH_COMMAND" >&2' ERR

: "${TARGET_ARCH:?TARGET_ARCH is required}"
: "${MINGW_CHOST:?MINGW_CHOST is required; run this script in a MinGW MSYS2 shell}"

log_step "Checking required build tools"
for tool in autoreconf automake libtoolize make gcc gcc-ar gcc-ranlib gcc-nm cygpath; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Required build tool is unavailable: $tool" >&2
    exit 1
  fi
  echo "Found $tool: $(command -v "$tool")"
done

runner_temp_posix="$(cygpath -u "$RUNNER_TEMP")"
workspace_posix="$(cygpath -u "$GITHUB_WORKSPACE")"
github_env_posix="$(cygpath -u "$GITHUB_ENV")"

echo "Target architecture: $TARGET_ARCH"
echo "MinGW target host:   $MINGW_CHOST"
echo "Workspace:           $workspace_posix"
echo "Runner temporary:    $runner_temp_posix"

log_step "Detecting source versions"
tiny_archive="$(find tiny-curl-src -maxdepth 1 -type f -name 'tiny-curl-*.tar.gz' -print -quit)"
if [[ -z "$tiny_archive" ]]; then
  echo "No tiny-curl-*.tar.gz archive was found in tiny-curl-src." >&2
  exit 1
fi

tiny_filename="$(basename "$tiny_archive")"
tiny_version="${tiny_filename#tiny-curl-}"
tiny_version="${tiny_version%.tar.gz}"

wolf_url="$(tr -d '\r' < wolfssl-src | sed -n '/[^[:space:]]/ { s/[[:space:]]*$//; p; q; }')"
if [[ ! "$wolf_url" =~ /v([^/]+)-stable\.zip$ ]]; then
  echo "Cannot determine the wolfSSL version from wolfssl-src: $wolf_url" >&2
  exit 1
fi
wolf_version="${BASH_REMATCH[1]}"

echo "tiny-curl archive: $tiny_archive"
echo "tiny-curl version: $tiny_version"
echo "wolfSSL URL:       $wolf_url"
echo "wolfSSL version:   $wolf_version"

work_dir="$runner_temp_posix/build-$TARGET_ARCH"
prefix="$work_dir/prefix"
mkdir -p "$work_dir" "$prefix" dist

echo "Build directory:   $work_dir"
echo "Install prefix:    $prefix"

log_step "Downloading and extracting wolfSSL $wolf_version"
curl --fail --location --retry 3 --output "$work_dir/wolfssl.zip" "$wolf_url"
unzip -q "$work_dir/wolfssl.zip" -d "$work_dir"
wolf_source="$(find "$work_dir" -mindepth 1 -maxdepth 1 -type d -name 'wolfssl-*' -print -quit)"
if [[ -z "$wolf_source" ]]; then
  echo "The wolfSSL source directory was not found after extraction." >&2
  exit 1
fi

common_cppflags="-D_WIN32_WINNT=0x0601 -DWINVER=0x0601 -DWOLFSSL_DES_ECB"
common_cflags="-Os -flto -ffunction-sections -fdata-sections"
curl_cflags="$common_cflags -Wno-error=incompatible-pointer-types"
common_ldflags="-static -static-libgcc -flto -Wl,--gc-sections"

echo "wolfSSL source: $wolf_source"
echo "CPPFLAGS:       $common_cppflags"
echo "CFLAGS:         $common_cflags"
echo "curl CFLAGS:    $curl_cflags"
echo "LDFLAGS:        $common_ldflags"

log_step "Generating wolfSSL configure script"
pushd "$wolf_source"
./autogen.sh

log_step "Configuring wolfSSL"
CPPFLAGS="$common_cppflags" \
CFLAGS="$common_cflags" \
LDFLAGS="$common_ldflags" \
AR=gcc-ar \
RANLIB=gcc-ranlib \
NM=gcc-nm \
  ./configure \
    --host="$MINGW_CHOST" \
    --prefix="$prefix" \
    --enable-static \
    --disable-shared \
    --enable-curl=tiny \
    --enable-opensslextra \
    --enable-md4 \
    --enable-des3 \
    --disable-examples \
    --disable-crypttests

log_step "Compiling wolfSSL"
make -j"$(nproc)"

log_step "Installing static wolfSSL"
make install
popd

log_step "Verifying wolfSSL NTLM compatibility symbols"
for symbol in \
  wolfSSL_MD4_Init \
  wolfSSL_MD4_Update \
  wolfSSL_MD4_Final \
  wolfSSL_DES_set_odd_parity \
  wolfSSL_DES_set_key_unchecked \
  wolfSSL_DES_ecb_encrypt; do
  if ! gcc-nm "$prefix/lib/libwolfssl.a" | grep -Eq "[[:space:]]${symbol}$"; then
    echo "ERROR: wolfSSL static library is missing required symbol: $symbol" >&2
    exit 1
  fi
  echo "  found: $symbol"
done

log_step "Downloading CA certificate bundle"
ca_bundle="$work_dir/curl-ca-bundle.crt"
curl --fail --location --retry 3 --output "$ca_bundle" https://curl.se/ca/cacert.pem

build_tiny() {
  local package_suffix="$1"
  local cookie_option="$2"
  local zlib_option="$3"
  local expect_zlib="$4"
  local build_label="${package_suffix#-}"
  local tiny_source="$work_dir/tiny-curl-$tiny_version-${build_label:-default}"
  local package_name="tiny-curl-$tiny_version-via-wolfssl-$wolf_version-$TARGET_ARCH$package_suffix"
  local package_dir="$work_dir/$package_name"
  local version_output
  local imported_dlls

  log_step "Extracting tiny-curl $tiny_version (${build_label:-default})"
  mkdir -p "$tiny_source"
  tar -xzf "$tiny_archive" -C "$tiny_source" --strip-components=1

  log_step "Configuring tiny-curl (${build_label:-default})"
  pushd "$tiny_source"
  if [[ ! -x configure ]]; then
    echo "configure is missing; generating it with buildconf"
    ./buildconf
  fi
  PKG_CONFIG_PATH="$prefix/lib/pkgconfig" \
  CPPFLAGS="$common_cppflags -I$prefix/include" \
  CFLAGS="$curl_cflags" \
  LDFLAGS="$common_ldflags -L$prefix/lib" \
  LIBS="-lws2_32 -lcrypt32 -lbcrypt" \
  AR=gcc-ar \
  RANLIB=gcc-ranlib \
  NM=gcc-nm \
    ./configure \
      --host="$MINGW_CHOST" \
      --with-wolfssl="$prefix" \
      --disable-shared \
      --enable-static \
      --disable-dependency-tracking \
      --disable-threaded-resolver \
      --disable-file \
      --disable-ftp \
      --disable-ldap \
      --disable-ldaps \
      --disable-rtsp \
      --disable-dict \
      --disable-telnet \
      --disable-tftp \
      --disable-pop3 \
      --disable-imap \
      --disable-smb \
      --disable-smtp \
      --disable-gopher \
      --disable-mqtt \
      --disable-alt-svc \
      --disable-hsts \
      --disable-unix-sockets \
      --disable-libcurl-option \
      --without-zstd \
      --without-brotli \
      "$cookie_option" \
      "$zlib_option"

  echo "tiny-curl configure arguments: $(./config.status --config)"
  if ! grep -Eq '^#define HAVE_IOCTLSOCKET_FIONBIO 1' lib/curl_config.h; then
    echo "ERROR: tiny-curl did not detect Windows ioctlsocket(FIONBIO)." >&2
    grep -Ei -A 8 -B 3 'ioctlsocket' config.log >&2 || true
    exit 1
  fi
  if [[ "$cookie_option" == "--disable-cookies" ]]; then
    if ! grep -Eq '^#define CURL_DISABLE_COOKIES 1' lib/curl_config.h; then
      echo "ERROR: tiny-curl did not disable cookies." >&2
      exit 1
    fi
  elif grep -Eq '^#define CURL_DISABLE_COOKIES 1' lib/curl_config.h; then
    echo "ERROR: the Cookies/zlib package unexpectedly disabled cookies." >&2
    exit 1
  fi

  log_step "Compiling tiny-curl"
  make -j"$(nproc)" V=1
  strip src/curl.exe
  popd

  log_step "Checking runtime DLL dependencies"
  imported_dlls="$(objdump -p "$tiny_source/src/curl.exe" | sed -n 's/^[[:space:]]*DLL Name: //p')"
  printf 'Imported DLLs:\n%s\n' "$imported_dlls"
  if printf '%s\n' "$imported_dlls" | grep -Eiq '^(libwolfssl|libgcc|libstdc\+\+|libwinpthread|msys-|libzstd|zlib1|libbrotli).*\.dll$'; then
    echo "Unexpected non-system runtime DLL dependency detected." >&2
    exit 1
  fi

  mkdir -p "$package_dir"
  cp "$tiny_source/src/curl.exe" "$package_dir/curl.exe"
  cp "$ca_bundle" "$package_dir/curl-ca-bundle.crt"

  log_step "Verifying package"
  version_output="$(cd "$package_dir" && ./curl.exe --version)"
  printf '%s\n' "$version_output"
  if ! printf '%s\n' "$version_output" | grep -Eq '^Protocols: http https$'; then
    echo "ERROR: expected exactly HTTP and HTTPS protocols." >&2
    exit 1
  fi
  if [[ "$expect_zlib" == "yes" ]]; then
    if ! printf '%s\n' "$version_output" | grep -Eiq 'zlib/[0-9]'; then
      echo "ERROR: the Cookies/zlib package did not enable zlib." >&2
      exit 1
    fi
  elif printf '%s\n' "$version_output" | grep -Eiq 'zlib|libz'; then
    echo "ERROR: the default package unexpectedly enabled zlib." >&2
    exit 1
  fi
  if printf '%s\n' "$version_output" | grep -Eiq 'zstd|brotli'; then
    echo "ERROR: a disabled compression library is still enabled." >&2
    exit 1
  fi
  if printf '%s\n' "$version_output" | grep -Eq '^Features:.*UnixSockets'; then
    echo "ERROR: Unix socket support is still enabled." >&2
    exit 1
  fi

  log_step "Compressing release package"
  (cd "$package_dir" && zip -9 "$workspace_posix/dist/$package_name.zip" curl.exe curl-ca-bundle.crt)
  echo "Output: $workspace_posix/dist/$package_name.zip"
}

case "${BUILD_FLAVOR:-default}" in
  default)
    artifact_suffix=""
    build_tiny "" "--disable-cookies" "--without-zlib" "no"
    ;;
  cookies-zlib)
    artifact_suffix="-cookies-zlib"
    build_tiny "$artifact_suffix" "--enable-cookies" "--with-zlib" "yes"
    ;;
  *)
    echo "ERROR: unsupported BUILD_FLAVOR: $BUILD_FLAVOR" >&2
    exit 1
    ;;
esac

{
  echo "ARTIFACT_NAME=tiny-curl-$tiny_version-via-wolfssl-$wolf_version-$TARGET_ARCH$artifact_suffix"
  echo "RELEASE_TAG=tiny-curl-$tiny_version-wolfssl-$wolf_version"
  echo "RELEASE_TITLE=tiny-curl $tiny_version via wolfSSL $wolf_version"
} >> "$github_env_posix"

log_step "Build completed successfully"
ls -lh "$workspace_posix"/dist/*.zip
