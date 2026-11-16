# Upstream druntime provenance and license handling

This directory configures a staged port of the druntime sources bundled in LDC
1.43.0. It does not replace their license, grant a license to the rest of this
repository, or claim that the full runtime has been ported.

- Upstream: https://github.com/ldc-developers/ldc
- LDC commit: `ad42ba07be491c79a16a04e17ce54c06d8943c03` (`v1.43.0`).
- druntime source tree: `91f6e6544ed3dddee36d4ff3e77526c2ca2a10e3`.
- The archive URL and SHA-256 are pinned in `source.lock.json`.
- `LICENSE-LDC.txt` is an unmodified copy of that revision's top-level LICENSE.
  It distinguishes the compiler, runtime libraries, and other components.
- `LICENSE-Boost.txt` is the complete runtime-library license text extracted
  from that file: Boost Software License 1.0.

`tools/druntime.py fetch` retains every original file under
`runtime/druntime/src/`, including copyright, author and license headers. The original cache remains unmodified; startup builds apply the tracked platform
patch to a separate copy, preserving all upstream source headers. A per-file SHA-256 manifest records the
prepared tree; builds reject changed or missing files. Future port changes must
retain upstream notices and be recorded as reviewable patches, not silently
applied edits to the prepared source cache.

The bootstrap archive currently compiles `core/bitop.d`, `rt/aApply.d`, and
`rt/aApplyR.d`. Their original headers identify Digital Mars and contributors;
consult the retained source for each file's precise attribution. Imported
modules are also retained in the prepared source tree. No host druntime archive,
Phobos archive, C library or external unwinder is linked into the bootstrap ELF.

Keep this notice, both license files, the source lock, build report and pinned
source archive with any redistribution of the bootstrap development bundle.
`make druntime-package` produces that bundle. The upstream archive contains
additional LDC components governed by the licenses recorded in its LICENSE and
individual source headers; inclusion is for provenance, not a claim that those
components are linked into the guest application.

New components (for example an unwinder or a C library) require their own
source/version/license inventory before being added to this build. A successful
bootstrap build does not establish the license inventory of future components.

The startup port additionally builds selected object/rt/core sources from a
separate copy with `patches/0001-dlangos-startup.patch` applied. This patch retains
upstream copyright and license headers. `port/dlangos/` contains the OS adapters;
`app.ld` defines the static executable/TLS layout. The package includes these
patches and adapters alongside the original source archive and license texts.
The C ABI exercise is compiled freestanding; no Clang runtime or host C library
is linked into the application. See `docs/druntime.md` for the supported subset.
