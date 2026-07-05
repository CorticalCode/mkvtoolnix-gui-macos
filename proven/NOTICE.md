# Third-Party Notices — Proven Dependency Cache

The `proven/arm/` and `proven/intel/` directories contain pre-compiled binary
tarballs of the upstream dependencies needed to build MKVToolNix for macOS.
These tarballs are redistributed here as a build-time optimization so that
clean builds don't have to recompile identical dependencies on every run.

Both architectures (Apple Silicon `arm64` and Intel `x86_64`) contain the same
software built for their respective target; the licenses and obligations below
apply equally to both caches.

This notice acknowledges each project's authorship, license, and upstream
source. Full license texts are not reproduced here; they are preserved verbatim
inside each upstream source tarball (cached in `~/opt/source/` during builds,
or available at each project's homepage).

---

## MKVToolNix (the primary project)

The software whose distribution this repository supports. **All credit for
MKVToolNix itself belongs to Moritz Bunkus and the MKVToolNix contributors.**
This repository only provides macOS build automation — it contains no
MKVToolNix source code.

| | |
|---|---|
| **Project** | MKVToolNix |
| **Version** | 98.0 (build target; `proven/` does not bundle MKVToolNix binaries) |
| **Author** | Moritz Bunkus & contributors |
| **License** | GPL-2.0-or-later |
| **Upstream** | https://mkvtoolnix.download |
| **Source** | https://codeberg.org/mbunkus/mkvtoolnix |

---

## Runtime libraries bundled into the MKVToolNix application

These libraries are compiled from the sources below and end up inside the
shipped `.app` bundle. Both architecture caches contain equivalent builds.

| Library | Version | License (SPDX) | Copyright | Source |
|---------|---------|---------------|-----------|--------|
| **Qt** (Core, Gui, Widgets, Network, Concurrent, Multimedia, MultimediaWidgets, MultimediaQuick, Svg, SvgWidgets, NetworkAuth, Core5Compat) | 6.11.1 | `LGPL-3.0-only` with Qt GPL Exception v1.0 | The Qt Company Ltd. and other contributors | https://download.qt.io/archive/qt/6.11/6.11.1/ |
| **Boost** (system; headers-only components are not separately bundled) | 1.88.0 | `BSL-1.0` (Boost Software License 1.0) | Boost contributors | https://boost.org |
| **zlib** | 1.3.2 | `Zlib` | Jean-loup Gailly & Mark Adler | https://zlib.net |
| **FLAC** (`libFLAC`) | 1.5.0 | `BSD-3-Clause` (Xiph variant) | Josh Coalson, Xiph.Org Foundation | https://xiph.org/flac/ |
| **libogg** | 1.3.4 | `BSD-3-Clause` (Xiph variant) | Xiph.Org Foundation | https://xiph.org/ogg/ |
| **libvorbis** | 1.3.7 | `BSD-3-Clause` (Xiph variant) | Xiph.Org Foundation | https://xiph.org/vorbis/ |
| **GNU libiconv** (`libiconv`, `libcharset`) | 1.16 | `LGPL-2.0-or-later` (library) / `GPL-2.0-or-later` (tools) | Bruno Haible & FSF | https://gnu.org/software/libiconv/ |
| **GNU gettext** (`libintl` runtime) | 0.23 | `LGPL-2.1-or-later` (runtime) / `GPL-3.0-or-later` (tools) | Ulrich Drepper, Bruno Haible, FSF | https://gnu.org/software/gettext/ |
| **GMP** | 6.3.0 | `LGPL-3.0-or-later` **or** `GPL-2.0-or-later` (dual-licensed) | Free Software Foundation | https://gmplib.org |
| **cmark** | 0.30.3 | `BSD-2-Clause` | John MacFarlane | https://github.com/commonmark/cmark |
| **curl** (99.0+ only — not in 98.0 builds) | 8.11.1 | `curl` (MIT-like) | Daniel Stenberg & contributors | https://curl.se |

---

## Build-time tools (used during build; not shipped in the `.app`)

Tarballs for these tools are included in `proven/` because they are built from
source as part of the dependency chain. Their binaries run on the build
machine and are not redistributed inside the final DMG — **they appear in
`proven/` only as compiled build-tool artifacts reused across builds.**

| Tool | Version | License (SPDX) | Source |
|------|---------|---------------|--------|
| **CMake** | 3.31.3 | `BSD-3-Clause` | https://cmake.org |
| **GNU autoconf** | 2.69 | `GPL-3.0-or-later` with autoconf exception | https://gnu.org/software/autoconf/ |
| **GNU automake** | 1.16.1 | `GPL-2.0-or-later` | https://gnu.org/software/automake/ |
| **pkg-config** | 0.29.2 | `GPL-2.0-or-later` | https://gitlab.freedesktop.org/pkg-config/pkg-config |
| **docbook-xsl** | 1.79.2 | `MIT` (DocBook variant) | https://github.com/docbook/xslt10-stylesheets |
| **GnuPG** (`gpg`; 99.0+ — verifies the upstream source-tarball OpenPGP signature at build time) | 1.4.23 | `GPL-3.0-or-later` | https://gnupg.org |

---

## Source code availability (GPL / LGPL obligation)

For the GPL- and LGPL-licensed components listed above, source code is
available in three ways:

1. **Upstream projects** — follow the "Source" URL in each table above.
2. **Source tarballs cached locally during builds** at `~/opt/source/`
   (see `build-local.sh` for the download URLs in `specs.sh`).
3. **On request** — open an issue at
   https://github.com/CorticalCode/mkvtoolnix-gui-macos/issues and we will
   provide the exact source tarball used to produce any given release.

All source URLs are pinned by SHA256 checksums in upstream MKVToolNix's
`packaging/macos/specs.sh`; the same checksums are archived in this repo's
build output.

---

## Trademark notice

MKVToolNix, macOS, Apple Silicon, and other names used in this repository are
trademarks of their respective owners. Use of these names does not imply
endorsement.

---

## About this notice

This file exists to satisfy attribution, source-availability, and notice
obligations of the licenses above. It is maintained on a best-effort basis.
If you believe any attribution here is missing, incorrect, or stale, please
open an issue at
https://github.com/CorticalCode/mkvtoolnix-gui-macos/issues and we will fix it.

Last updated: 2026-05-24 — added GnuPG (`gpg`) to the build-time tools cache for v99 (covers both `proven/arm/` and `proven/intel/`).
