# win-tiny-curl

Build static Windows x86 and x64 binaries of **tiny-curl** with **wolfSSL** using **GitHub Actions**, **MSYS2**, and **MinGW**.

The goal of this project is to provide lightweight, portable Windows builds of tiny-curl that are compatible with **Windows 7 and later** and do not require third-party runtime DLLs.

## Features

* Windows **x86** and **x64** builds
* Windows 7 compatibility target
* wolfSSL used as the TLS backend
* static linking where practical
* no external MinGW or wolfSSL runtime DLLs
* CA certificate bundle included
* automated builds through GitHub Actions
* package names include the tiny-curl version, wolfSSL version, and target architecture

## Current Versions

The versions currently used by this project are:

```text
tiny-curl: 8.4.0
wolfSSL:   5.9.2
```

These versions may be updated in future releases.

The tiny-curl source archive is stored under:

```text
src/
└── tiny-curl-8.4.0.tar.gz
```

wolfSSL is downloaded during the build using the version configured by the GitHub Actions workflow.

## Release Packages

Each build produces separate x86 and x64 ZIP archives.

With the current versions, the output files are:

```text
tiny-curl-8.4.0-via-wolfssl-5.9.2-x64.zip
tiny-curl-8.4.0-via-wolfssl-5.9.2-x86.zip
```

Each ZIP archive contains:

```text
curl.exe
curl-ca-bundle.crt
```

For example:

```text
tiny-curl-8.4.0-via-wolfssl-5.9.2-x64.zip
├── curl.exe
└── curl-ca-bundle.crt
```

## Package Naming

The package naming convention is:

```text
tiny-curl-<tiny-curl-version>-via-wolfssl-<wolfssl-version>-<arch>.zip
```

For example:

```text
tiny-curl-8.4.0-via-wolfssl-5.9.2-x64.zip
tiny-curl-8.4.0-via-wolfssl-5.9.2-x86.zip
```

If either tiny-curl or wolfSSL is upgraded, the corresponding version in the package name changes accordingly.

For example:

```text
tiny-curl-8.5.0-via-wolfssl-5.9.2-x64.zip
```

or:

```text
tiny-curl-8.4.0-via-wolfssl-5.9.3-x64.zip
```

This makes it possible to identify the exact tiny-curl and wolfSSL versions used to produce a binary directly from the archive name.

## Build Environment

Builds are performed automatically by GitHub Actions on Windows using MSYS2 and MinGW.

The build process is roughly:

```text
GitHub Actions
      |
      +-- Windows runner
      |
      +-- MSYS2
      |
      +-- MinGW x64 / x86
      |
      +-- extract tiny-curl source
      |
      +-- download configured wolfSSL version
      |
      +-- build wolfSSL statically
      |
      +-- build tiny-curl against wolfSSL
      |
      +-- verify curl.exe dependencies
      |
      +-- add curl-ca-bundle.crt
      |
      `-- create ZIP packages
```

## Architectures

Two Windows architectures are built:

| Package suffix | Architecture  |
| -------------- | ------------- |
| `x64`          | 64-bit x86-64 |
| `x86`          | 32-bit x86    |

Example output:

```text
dist/
├── tiny-curl-8.4.0-via-wolfssl-5.9.2-x64.zip
└── tiny-curl-8.4.0-via-wolfssl-5.9.2-x86.zip
```

## Static Build

The goal is for `curl.exe` to be as self-contained as practical.

The generated executable should not require separately distributed runtime DLLs such as:

```text
libwolfssl.dll
libgcc_s_seh-1.dll
libgcc_s_sjlj-1.dll
libwinpthread-1.dll
libstdc++-6.dll
```

Dependencies on standard Windows system DLLs are expected.

For example:

```text
KERNEL32.dll
WS2_32.dll
ADVAPI32.dll
CRYPT32.dll
```

The exact set of Windows system DLLs may differ between x86 and x64 builds.

## CA Certificate Bundle

Each release package includes:

```text
curl-ca-bundle.crt
```

This file is distributed alongside `curl.exe` for HTTPS certificate verification.

The intended extracted layout is:

```text
tiny-curl/
├── curl.exe
└── curl-ca-bundle.crt
```

## Windows 7 Compatibility

Windows 7 compatibility is an explicit target of this project.

The build configuration aims to avoid dependencies on APIs and runtime components that require newer Windows versions.

Both x86 and x64 binaries are intended to run on:

```text
Windows 7+
```

Compatibility should be verified whenever the compiler, tiny-curl version, wolfSSL version, or build configuration changes.

## GitHub Actions

The build workflow is located under:

```text
.github/workflows/
```

The workflow is responsible for:

1. Setting up MSYS2
2. Installing the required MinGW toolchains
3. Extracting the configured tiny-curl source archive from `src/`
4. Downloading the configured wolfSSL version
5. Building wolfSSL as a static library
6. Building tiny-curl against wolfSSL
7. Producing x86 and x64 `curl.exe` binaries
8. Checking runtime DLL dependencies
9. Adding `curl-ca-bundle.crt`
10. Creating versioned ZIP packages
11. Uploading the resulting artifacts or GitHub Release assets

## Verification

The generated binary can be checked with:

```console
curl.exe --version
```

The output should show wolfSSL as the TLS backend.

Runtime dependencies can be inspected with:

```console
objdump -p curl.exe
```

or another PE dependency inspection tool.

The expected result is that `curl.exe` only depends on Windows system DLLs and does not require external wolfSSL or MinGW runtime DLLs.

HTTPS can be tested with:

```console
curl.exe https://example.com/
```

## Repository Structure

A typical repository layout is:

```text
win-tiny-curl/
├── .github/
│   └── workflows/
│       └── build.yml
├── src/
│   └── tiny-curl-8.4.0.tar.gz
├── scripts/
│   └── ...
├── README.md
└── LICENSE
```

The exact tiny-curl source archive under `src/` may change as the project is updated to newer versions.

Generated binaries are not required to be stored in the repository. They are produced by GitHub Actions and published as build artifacts or GitHub Release assets.

## Upstream Projects

This repository provides Windows build automation and packaging for upstream tiny-curl and wolfSSL releases.

### tiny-curl

https://curl.se/tiny/

Current version used by this project:

```text
8.4.0
```

### wolfSSL

https://github.com/wolfSSL/wolfssl

Current version used by this project:

```text
5.9.2
```

The versions used by future builds may change.

## License

The build scripts, workflow files, and other original files in this repository may be licensed separately by this project.

The upstream components retain their own licenses.

### tiny-curl

tiny-curl is distributed under the **GNU General Public License version 3 (GPLv3)**.

### wolfSSL

wolfSSL retains its applicable upstream licensing terms.

### Generated Binaries

The generated `curl.exe` binaries contain and/or link GPL-licensed software.

Redistribution of the generated binaries must therefore comply with the applicable license requirements of tiny-curl and wolfSSL.

The license used for this repository's own build scripts does not override the licenses of the upstream software.

The bundled `curl-ca-bundle.crt` retains its own upstream licensing and attribution terms.

## Disclaimer

This is an independent Windows build project.

It is not an official curl, tiny-curl, or wolfSSL distribution.

Issues related specifically to these Windows builds may be reported to this repository.

Issues in tiny-curl or wolfSSL themselves should generally be reported to the appropriate upstream project.
