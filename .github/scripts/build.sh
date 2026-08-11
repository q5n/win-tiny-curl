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

log_step "Checking required build tools"
for tool in autoreconf automake libtoolize make gcc cygpath; do
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

common_cppflags="-D_WIN32_WINNT=0x0601 -DWINVER=0x0601"
common_cflags="-O2 -ffunction-sections -fdata-sections"
common_ldflags="-static -static-libgcc -Wl,--gc-sections"

echo "wolfSSL source: $wolf_source"
echo "CPPFLAGS:       $common_cppflags"
echo "CFLAGS:         $common_cflags"
echo "LDFLAGS:        $common_ldflags"

log_step "Generating wolfSSL configure script"
pushd "$wolf_source"
./autogen.sh

log_step "Configuring wolfSSL"
CPPFLAGS="$common_cppflags" \
CFLAGS="$common_cflags" \
LDFLAGS="$common_ldflags" \
  ./configure \
    --prefix="$prefix" \
    --enable-static \
    --disable-shared \
    --enable-curl \
    --disable-examples \
    --disable-crypttests

log_step "Compiling wolfSSL"
make -j"$(nproc)"

log_step "Installing static wolfSSL"
make install
popd

log_step "Extracting tiny-curl $tiny_version"
tar -xzf "$tiny_archive" -C "$work_dir"
tiny_source="$(find "$work_dir" -mindepth 1 -maxdepth 1 -type d -name "tiny-curl-$tiny_version*" -print -quit)"
if [[ -z "$tiny_source" ]]; then
  echo "The tiny-curl source directory was not found after extraction." >&2
  exit 1
fi

echo "tiny-curl source: $tiny_source"

log_step "Configuring tiny-curl with wolfSSL"
pushd "$tiny_source"
if [[ ! -x configure ]]; then
  echo "configure is missing; generating it with buildconf"
  ./buildconf
fi
PKG_CONFIG_PATH="$prefix/lib/pkgconfig" \
CPPFLAGS="$common_cppflags -I$prefix/include" \
CFLAGS="$common_cflags" \
LDFLAGS="$common_ldflags -L$prefix/lib" \
LIBS="-lws2_32 -lcrypt32 -lbcrypt" \
  ./configure \
    --with-wolfssl="$prefix" \
    --disable-shared \
    --enable-static \
    --disable-dependency-tracking \
    --disable-threaded-resolver

log_step "Compiling tiny-curl"
make -j"$(nproc)" V=1

log_step "Stripping curl.exe"
strip src/curl.exe
popd

log_step "Checking curl.exe runtime DLL dependencies"
imported_dlls="$(objdump -p "$tiny_source/src/curl.exe" | sed -n 's/^[[:space:]]*DLL Name: //p')"
printf 'Imported DLLs:\n%s\n' "$imported_dlls"
if printf '%s\n' "$imported_dlls" | grep -Eiq '^(libwolfssl|libgcc|libstdc\+\+|libwinpthread|msys-).*\.dll$'; then
  echo "Unexpected non-system runtime DLL dependency detected." >&2
  exit 1
fi

log_step "Creating release package"
package_name="tiny-curl-$tiny_version-via-wolfssl-$wolf_version-$TARGET_ARCH"
package_dir="$work_dir/$package_name"
mkdir -p "$package_dir"
cp "$tiny_source/src/curl.exe" "$package_dir/curl.exe"
curl --fail --location --retry 3 --output "$package_dir/curl-ca-bundle.crt" https://curl.se/ca/cacert.pem

echo "Package name:      $package_name"
echo "Package directory: $package_dir"

log_step "Verifying generated curl.exe"
(cd "$package_dir" && ./curl.exe --version)

log_step "Compressing release package"
(cd "$package_dir" && zip -9 "$workspace_posix/dist/$package_name.zip" curl.exe curl-ca-bundle.crt)

{
  echo "PACKAGE_NAME=$package_name"
  echo "RELEASE_TAG=tiny-curl-$tiny_version-wolfssl-$wolf_version"
  echo "RELEASE_TITLE=tiny-curl $tiny_version via wolfSSL $wolf_version"
} >> "$github_env_posix"

log_step "Build completed successfully"
echo "Output: $workspace_posix/dist/$package_name.zip"
