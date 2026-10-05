# Pre-built crash(8) image for analyzing the vmcore produced by the
# CONFIG_CRASH_DM_CRYPT LUKS kdump test (see
# encrypt_crash_kernel/qemu-x86.md, Section 12).
#
# WHY FEDORA, SPECIFICALLY:
#   crash-utility is a Red Hat-originated project; its own build docs and
#   .spec file are written in terms of dnf/rpm package names
#   (ncurses-devel, elfutils-libelf-devel, elfutils-debuginfod-client, ...),
#   so there is no translation step from upstream instructions to this
#   Dockerfile. Fedora also ships current elfutils/zlib/zstd/gdb-adjacent
#   toolchain versions, which matters because this image has to build
#   crash's *own* patched GDB 16.2 from source. Fedora 40 and 42 are also
#   the exact two distro-packaged `crash` versions (8.0.4 / 9.0.1) that were
#   confirmed to fail against this kernel with
#   "invalid structure member offset: kmem_cache_s_num" (a known gap for
#   Linux 7.1+ that no released crash build has fixed yet) -- building on
#   the same base keeps the "distro package fails, git HEAD on the same
#   distro works" comparison apples-to-apples. None of this makes Fedora a
#   hard technical requirement: Ubuntu/Debian could build the same crash
#   binary with apt-equivalent -dev packages. Fedora was simply the
#   zero-translation choice given crash's own upstream docs.
#
# Build once (~12-13 min under amd64 emulation on an arm64 host, mostly
# spent compiling the bundled GDB):
#   docker build --platform linux/amd64 -t crash-tool:fedora42 \
#     kernel/qemu/crash-tool
#
# Reuse forever after that, no recompilation:
#   docker run --rm --platform linux/amd64 \
#     -v "$PWD/build-out/vanilla-x86":/out \
#     crash-tool:fedora42 /out/vmlinux /out/vmcore.extracted
#
# Non-interactive (batch) use, same as qemu-x86.md Section 12 Step 4:
#   printf "sys\nbt\nlog\nquit\n" | docker run --rm -i --platform linux/amd64 \
#     -v "$PWD/build-out/vanilla-x86":/out \
#     crash-tool:fedora42 /out/vmlinux /out/vmcore.extracted
#
# This is a single-stage image (not multi-stage) on purpose: crash's merged
# GDB links against readline/ncurses, zlib, bz2, xz, lzo, snappy, zstd,
# elfutils (libelf/libdw), gmp, and mpfr. Copying only the binary into a
# slimmer final stage risks missing one of those at runtime; keeping the
# -devel packages (which pull in their matching runtime .so's on Fedora)
# in the final image trades disk space for a build that is known to run.

FROM fedora:42

# ARG so a future kdump-affecting kernel change can pin a newer commit
# instead of always floating on the crash-utility default branch.
# crash-utility's default branch is "master", not "main".
ARG CRASH_REF=master

RUN dnf install -y -q \
      git gcc gcc-c++ make bison flex ncurses-devel zlib-devel \
      bzip2-devel xz-devel lzo-devel snappy-devel libzstd-devel \
      elfutils-libelf-devel elfutils-devel wget texinfo \
      gmp-devel mpfr-devel libmpc-devel patch \
      elfutils-debuginfod-client \
    && dnf clean all \
    && git clone --depth 1 --branch "${CRASH_REF}" \
         https://github.com/crash-utility/crash.git /usr/src/crash \
    && cd /usr/src/crash \
    && make -j"$(nproc)" \
    && install -m 0755 ./crash /usr/local/bin/crash \
    && /usr/local/bin/crash --version \
    && rm -rf /usr/src/crash

WORKDIR /out
ENTRYPOINT ["/usr/local/bin/crash"]
