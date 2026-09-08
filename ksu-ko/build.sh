#!/data/data/com.termux/files/usr/bin/bash
# Build a XRing O1-compatible kernelsu.ko from the upstream KernelSU source
# against the Xiaomi O1 kernel tree, entirely on-device in Termux.
#
# Baseline: tiann/KernelSU v3.3.0 (or any tree you point KSU_SRC at).
# Output : kernelsu.ko with XRing 6.6.30 device-tree struct layout.
#
# Why not the official prebuilt ko:
#   The official CI ko is compiled against the GKI 6.6.127 reference tree.
#   Its hardcoded struct offsets do not match the XRing 6.6.77 device tree,
#   and it lacks the fallback paths needed when kernel assumptions fail
#   (see ksu-ko/README.md). Same UNDEF-symbol count as official (218),
#   same empty __versions CRC table, same module params — only the
#   compile-time struct layout differs, which is what makes it work.
#
# Usage: bash ksu-ko/build.sh [KSU_TAG]
#   KSU_TAG  git ref in KSU_SRC to build (default: v3.3.0)

set -euo pipefail

KSU_TAG="${1:-v3.3.0}"
KSRC="${KSRC:-$HOME/Xiaomi_Kernel_OpenSource/common-ogki}"   # O1 kernel source tree
KOUT="${KOUT:-$TMPDIR/kb-xring}"                              # kernel build output dir
KSU_SRC="${KSU_SRC:-$HOME/kernelsu_upstream}"                 # KernelSU clone
KSU_KO_OUT="$KSU_SRC/kernel/kernelsu.ko"

log()  { printf '\033[0;32m[build-ksu]\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31m[build-ksu] FAIL: %s\033[0m\n' "$*" >&2; exit 1; }

# --- 0. dependency check -----------------------------------------------------
log "checking dependencies"
for c in clang llvm-objcopy llvm-nm llvm-readelf llvm-strip make bison flex bc python3; do
    command -v "$c" >/dev/null 2>&1 || fail "missing: $c (pkg install clang llvm make bison flex bc)"
done
[ -d "$KSRC" ]   || fail "kernel source not found: $KSRC (clone Xiaomi_Kernel_OpenSource)"
[ -d "$KSU_SRC/.git" ] || fail "KernelSU clone not found: $KSU_SRC"

# --- 1. host-tool shims (bionic friction, see termux-android-kernel-build) ---
SHIM="$TMPDIR/bionic-shim"
if [ ! -f "$SHIM/elf.h" ]; then
    log "creating bionic-shim"
    mkdir -p "$SHIM"
    for d in linux asm-generic aarch64-linux-android; do
        [ -d "$PREFIX/include/$d" ] && ln -sfn "$PREFIX/include/$d" "$SHIM/$d"
    done
    cat > "$SHIM/elf.h" <<'EOF'
/* bionic elf.h lacks ELF*_ST_TYPE/ELF*_R_SYM and the R_ARM_* reloc set.
 * Found via -I bionic-shim (first in path); #include_next pulls real bionic elf.h. */
#include_next <elf.h>
#undef ELF32_R_SYM
#undef ELF64_R_SYM
#undef ELF32_ST_BIND
#undef ELF64_ST_BIND
#undef ELF32_ST_TYPE
#undef ELF64_ST_TYPE
#define ELF32_R_SYM(i)   ((i) >> 8)
#define ELF64_R_SYM(i)   ((i) >> 32)
#define ELF32_ST_BIND(i) (((i) >> 4) & 0xf)
#define ELF64_ST_BIND(i) (((i) >> 4) & 0xf)
#define ELF32_ST_TYPE(i) ((i) & 0xf)
#define ELF64_ST_TYPE(i) ((i) & 0xf)
#ifndef R_ARM_CALL
#define R_ARM_CALL            28
#endif
#ifndef R_ARM_JUMP24
#define R_ARM_JUMP24          29
#endif
#ifndef R_ARM_MOVW_ABS_NC
#define R_ARM_MOVW_ABS_NC     43
#endif
#ifndef R_ARM_MOVT_ABS
#define R_ARM_MOVT_ABS        44
#endif
#ifndef R_ARM_THM_MOVW_ABS_NC
#define R_ARM_THM_MOVW_ABS_NC 47
#endif
#ifndef R_ARM_THM_MOVT_ABS
#define R_ARM_THM_MOVT_ABS    48
#endif
#ifndef R_ARM_THM_JUMP19
#define R_ARM_THM_JUMP19      51
#endif
#ifndef R_ARM_THM_JUMP24
#define R_ARM_THM_JUMP24      60
#endif
EOF
fi

BCWRAP="$TMPDIR/bcwrap"
if [ ! -x "$BCWRAP/bc" ]; then
    log "creating bcwrap"
    mkdir -p "$BCWRAP"
    printf '#!/data/data/com.termux/files/usr/bin/bash\nexec /bin/bc "$@"\n' > "$BCWRAP/bc"
    chmod +x "$BCWRAP/bc"
fi
export PATH="$BCWRAP:$PATH"

# Host tool flags. Two Termux-specific workarounds baked in:
#  - bionic has no bcmp; implicit decls are errors on clang>=16 host tools
#  - dtc yaml support references dt_to_yaml which is not in this tree's Makefile:
#    build dtc with -DNO_YAML (yaml output is unused for module builds)
# NOTE: HOST_EXTRACFLAGS is passed on the command line on purpose — a command-
# line assignment overrides the per-dir += in scripts/*/Makefile, so every
# include dir those Makefiles want must be listed here explicitly.
HOSTCFLAGS="-Wno-error=implicit-function-declaration -Wno-error=implicit-int \
    -Dbcmp=memcmp -Wno-incompatible-pointer-types -Wno-int-conversion -DNO_YAML"
HOST_EXTRACFLAGS="-I$SHIM \
    -I$KSRC/include/uapi -I$KSRC/include \
    -I$KSRC/security/selinux/include \
    -I$KOUT/include -I$KSRC/arch/arm64/tools"
# KCFLAGS: flask.h is generated into KOUT (not the source tree); clang>=21 flags
# -Wdefault-const-init-var-unsafe on kernel headers as an error.
KCFLAGS="-I$KOUT/security/selinux/include \
    -Wno-default-const-init-var-unsafe -Wno-error=default-const-init-var-unsafe"

MAKE_ARGS=(
    O="$KOUT" ARCH=arm64
    CC=clang HOSTCC=clang
    OBJCOPY=llvm-objcopy NM=llvm-nm READELF=llvm-readelf STRIP=llvm-strip
    HOSTCFLAGS="$HOSTCFLAGS" HOST_EXTRACFLAGS="$HOST_EXTRACFLAGS"
)

# --- 2. pin KernelSU baseline -------------------------------------------------
log "checking out KernelSU $KSU_TAG"
git -C "$KSU_SRC" checkout -q "$KSU_TAG"
KSU_VER=$(git -C "$KSU_SRC" describe --tags 2>/dev/null || echo "$KSU_TAG")
log "KernelSU baseline: $KSU_VER ($(git -C "$KSU_SRC" log --format=%h -1))"

# --- 3. configure kernel (first run only) -------------------------------------
if [ ! -f "$KOUT/.config" ]; then
    log "configuring kernel (gki_defconfig)"
    mkdir -p "$KOUT"
    make -C "$KSRC" "${MAKE_ARGS[@]}" gki_defconfig >/dev/null
fi
# sanity: the vermagic flags we rely on
grep -q '^CONFIG_MODVERSIONS=y'   "$KOUT/.config" || fail "CONFIG_MODVERSIONS missing"
grep -q '^CONFIG_ARM64_4K_PAGES=y' "$KOUT/.config" || fail "CONFIG_ARM64_4K_PAGES missing"
log "kernel config OK (MODVERSIONS=y, LOCALVERSION=$(grep CONFIG_LOCALVERSION= "$KOUT/.config" | cut -d'"' -f2))"

# --- 4. prepare ---------------------------------------------------------------
# gen-hyprel (host tool, built before autoconf.h exists) needs a stub; the real
# autoconf.h is produced by syncconfig right after. Both stub locations are
# removed so syncconfig regenerates the genuine file.
if [ ! -f "$KOUT/include/generated/autoconf.h" ] || \
   [ "$KOUT/.config" -nt "$KOUT/include/generated/autoconf.h" ]; then
    log "syncconfig (generate autoconf.h)"
    rm -f "$KOUT/include/generated/autoconf.h" "$KOUT/arch/arm64/tools/generated/autoconf.h"
    rm -rf "$KOUT/include/config"
    mkdir -p "$KOUT/arch/arm64/tools/generated"
    printf '#define CONFIG_RANDSTRUCT_NONE 1\n#define CONFIG_CPU_LITTLE_ENDIAN 1\n' \
        > "$KOUT/arch/arm64/tools/generated/autoconf.h"
    cp "$KOUT/arch/arm64/tools/generated/autoconf.h" "$KOUT/include/generated/autoconf.h" 2>/dev/null || \
        { mkdir -p "$KOUT/include/generated"; cp "$KOUT/arch/arm64/tools/generated/autoconf.h" "$KOUT/include/generated/autoconf.h"; }
    make -C "$KSRC" "${MAKE_ARGS[@]}" syncconfig >/dev/null
fi

log "prepare + modules_prepare"
make -C "$KSRC" "${MAKE_ARGS[@]}" prepare modules_prepare >/dev/null

# selinux genheaders products (flask.h / av_permissions.h) live in KOUT;
# objsec.h includes "flask.h" relative to the SOURCE include dir, so the
# generated headers must exist and be reachable via KCFLAGS.
if [ ! -f "$KOUT/security/selinux/include/flask.h" ]; then
    log "generating selinux headers (flask.h, av_permissions.h)"
    mkdir -p "$KOUT/security/selinux/include"
    "$KOUT/scripts/selinux/genheaders/genheaders" \
        "$KOUT/security/selinux/include/flask.h" \
        "$KOUT/security/selinux/include/av_permissions.h"
fi

# --- 5. build the module -------------------------------------------------------
log "building kernelsu.ko (baseline $KSU_VER)"
# KBUILD_MODPOST_WARN=1: no vmlinux/Module.symvers exists (we never build the
# kernel image). modpost therefore cannot resolve kernel symbols — that is
# EXPECTED for this workflow: every undefined symbol is resolved at load time
# by ksuinit from /proc/kallsyms, and the resulting empty __versions CRC table
# makes the MODVERSIONS loader compare only the vermagic flags (which match).
make -C "$KSRC" "${MAKE_ARGS[@]}" \
    KCFLAGS="$KCFLAGS" KBUILD_MODPOST_WARN=1 \
    M="$KSU_SRC/kernel" CONFIG_KSU=m modules 2>&1 | grep -E "LD \[M\]|error:" || true

[ -f "$KSU_KO_OUT" ] || fail "kernelsu.ko not produced"

# --- 6. report -----------------------------------------------------------------
log "built: $KSU_KO_OUT ($(stat -c%s "$KSU_KO_OUT") bytes)"
python3 - "$KSU_KO_OUT" <<'EOF'
import sys
from elftools.elf.elffile import ELFFile
f = open(sys.argv[1], 'rb')
elf = ELFFile(f)
mi = elf.get_section_by_name('.modinfo')
params = []
for e in mi.data().split(b'\x00'):
    if e.startswith(b'vermagic='): vm = e[9:].decode()
    if e.startswith(b'parmtype='): params.append(e[9:].decode())
symtab = elf.get_section_by_name('.symtab')
undef = sum(1 for s in symtab.iter_symbols() if s['st_shndx']=='SHN_UNDEF' and s.name)
v = elf.get_section_by_name('__versions')
ver_n = v.header['sh_size']//68 if v is not None else -1
print(f"  vermagic : {vm}")
print(f"  params   : {params}")
print(f"  UNDEF syms: {undef}  __versions CRC entries: {ver_n}")
f.close()
EOF
log "done. push to device: adb push $KSU_KO_OUT /data/local/tmp/kernelsu.ko"
