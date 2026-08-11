#!/usr/bin/env bash
set -euo pipefail

: "${TARGET_ARCH:?TARGET_ARCH is required}"

for tool in autoreconf automake libtoolize make gcc; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Required build tool is unavailable: $tool" >&2
    exit 1
  fi
done

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

work_dir="$RUNNER_TEMP/build-$TARGET_ARCH"
prefix="$work_dir/prefix"
mkdir -p "$work_dir" "$prefix" dist

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

pushd "$wolf_source"
./autogen.sh
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
make -j"$(nproc)"
make install
popd

tar -xzf "$tiny_archive" -C "$work_dir"
tiny_source="$(find "$work_dir" -mindepth 1 -maxdepth 1 -type d -name "tiny-curl-$tiny_version*" -print -quit)"
if [[ -z "$tiny_source" ]]; then
  echo "The tiny-curl source directory was not found after extraction." >&2
  exit 1
fi

pushd "$tiny_source"
if [[ ! -x configure ]]; then
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
make -j"$(nproc)" V=1
strip src/curl.exe
popd

imported_dlls="$(objdump -p "$tiny_source/src/curl.exe" | sed -n 's/^[[:space:]]*DLL Name: //p')"
printf 'Imported DLLs:\n%s\n' "$imported_dlls"
if printf '%s\n' "$imported_dlls" | grep -Eiq '^(libwolfssl|libgcc|libstdc\+\+|libwinpthread|msys-).*\.dll$'; then
  echo "Unexpected non-system runtime DLL dependency detected." >&2
  exit 1
fi

package_name="tiny-curl-$tiny_version-via-wolfssl-$wolf_version-$TARGET_ARCH"
package_dir="$work_dir/$package_name"
mkdir -p "$package_dir"
cp "$tiny_source/src/curl.exe" "$package_dir/curl.exe"
curl --fail --location --retry 3 --output "$package_dir/curl-ca-bundle.crt" https://curl.se/ca/cacert.pem

(cd "$package_dir" && ./curl.exe --version)
(cd "$package_dir" && zip -9 "$GITHUB_WORKSPACE/dist/$package_name.zip" curl.exe curl-ca-bundle.crt)

{
  echo "PACKAGE_NAME=$package_name"
  echo "RELEASE_TAG=tiny-curl-$tiny_version-wolfssl-$wolf_version"
  echo "RELEASE_TITLE=tiny-curl $tiny_version via wolfSSL $wolf_version"
} >> "$GITHUB_ENV"
