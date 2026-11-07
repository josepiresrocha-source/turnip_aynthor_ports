#!/usr/bin/env bash
# Turnip for the AYN Thor (Snapdragon 8 Gen 2 / Adreno 740, Android 13), tuned for console ports.
#
#   Mesa main 21bbed37 (2026-11-06) + patches/ (disk shader cache on Android, KGSL GPU boost,
#   driconf profiles for Xenia- and shadPS4-based ports).
#
# Usage:  VARIANT=ports         ./build.sh   (default: autotune "profiled" in the port profiles)
#         VARIANT=ports-sysmem  ./build.sh   (same, autotune "prefer_sysmem" in the port profiles)
#         VARIANT=upstream      ./build.sh   (Mesa main without patches: the control for A/B tests)
#
# All variants use the same compiler flags, so an A/B between them measures only the patches.
# Adapted from StevenMXZ/Adreno-Tools-Drivers build_turnip.sh (GPL-3.0).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="$ROOT/work"
NDKVER="android-ndk-r29"
NDK="$WORKDIR/$NDKVER/toolchains/llvm/prebuilt/linux-x86_64/bin"
MESA_COMMIT="21bbed371887fa750a6ce5ccbedf5354d2411a66"
VARIANT="${VARIANT:-ports}"
BUILD_VERSION="${BUILD_VERSION:-1}"
# The Thor ships Android 13. Building against a newer API level can reference libc symbols that
# Android 13 does not have, and the driver would fail to load.
API=33
# Snapdragon 8 Gen 2: Cortex-X3 + A715/A710 + A510, all ARMv9.0. armv8.2-a (a subset every core
# has) gives inline LSE atomics instead of LL/SC loops; tuned for the A715/A710 cores where the
# ports' render threads run. Not for older phones.
CPU_FLAGS="'-march=armv8.2-a+fp16+dotprod+rcpc', '-mtune=cortex-a715'"

log() { echo -e "\033[0;32m$*\033[0m"; }
die() { echo -e "\033[0;31m$*\033[0m" >&2; exit 1; }

case "$VARIANT" in
    ports|ports-sysmem|upstream) ;;
    *) die "VARIANT must be ports, ports-sysmem or upstream (got '$VARIANT')" ;;
esac

check_deps() {
    local dep
    for dep in git meson ninja curl unzip zip flex bison glslangValidator python3; do
        command -v "$dep" >/dev/null 2>&1 || die "Missing dependency: $dep"
    done
    python3 -c "import mako, yaml" 2>/dev/null || die "Missing python modules: mako, pyyaml"
}

get_ndk() {
    mkdir -p "$WORKDIR"
    if [ ! -d "$WORKDIR/$NDKVER" ]; then
        log "Downloading Android NDK r29..."
        curl -sSfL "https://dl.google.com/android/repository/${NDKVER}-linux.zip" \
            -o "$WORKDIR/${NDKVER}-linux.zip"
        unzip -q "$WORKDIR/${NDKVER}-linux.zip" -d "$WORKDIR"
        rm -f "$WORKDIR/${NDKVER}-linux.zip"
    fi
    [ -f "$NDK/aarch64-linux-android${API}-clang" ] || die "NDK has no API $API clang"
}

get_mesa() {
    rm -rf "$WORKDIR/mesa"
    git init -q "$WORKDIR/mesa"
    cd "$WORKDIR/mesa"
    log "Fetching Mesa $MESA_COMMIT..."
    git fetch -q --depth=1 https://gitlab.freedesktop.org/mesa/mesa.git "$MESA_COMMIT" ||
        git fetch -q --depth=1 https://github.com/chaotic-cx/mesa-mirror.git "$MESA_COMMIT" ||
        die "Could not fetch Mesa $MESA_COMMIT"
    git checkout -q --detach FETCH_HEAD
}

apply_patches() {
    if [ "$VARIANT" = upstream ]; then
        log "upstream: no patches"
        return
    fi
    local p n=0
    for p in "$ROOT"/patches/*.patch; do
        log "  $(basename "$p")"
        git -c user.name=build -c user.email=build@localhost am -q --3way "$p" ||
            die "Patch failed: $p"
        n=$((n + 1))
    done
    log "Applied $n patches"

    local conf=src/freedreno/vulkan/00-turnip-defaults.conf
    if [ "$VARIANT" = ports-sysmem ]; then
        sed -i 's|value="profiled" /> <!-- ports-autotune -->|value="prefer_sysmem" /> <!-- ports-autotune -->|' "$conf"
    fi

    # Guard rails: fail instead of shipping a driver without what its name promises.
    grep -q "android_app_cache_dir" src/util/disk_cache_os.c || die "disk cache patch missing"
    grep -q "KGSL_PROP_PWR_CONSTRAINT" src/freedreno/vulkan/tu_knl_kgsl.cc || die "GPU boost patch missing"
    local want=profiled
    [ "$VARIANT" = ports-sysmem ] && want=prefer_sysmem
    [ "$(grep -c "value=\"$want\" /> <!-- ports-autotune -->" "$conf")" = 2 ] ||
        die "port profiles do not use autotune '$want'"
}

build() {
    cat > android-aarch64.txt <<EOF
[binaries]
ar = '$NDK/llvm-ar'
c = ['$NDK/aarch64-linux-android${API}-clang']
cpp = ['$NDK/aarch64-linux-android${API}-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables']
c_ld = 'lld'
cpp_ld = 'lld'
strip = '$NDK/llvm-strip'
pkg-config = ['env', 'PKG_CONFIG_LIBDIR=$WORKDIR/pkgconfig', '/usr/bin/pkg-config']

[built-in options]
c_args = [$CPU_FLAGS]
cpp_args = [$CPU_FLAGS]
cpp_link_args = ['-static-libstdc++']

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF
    mkdir -p "$WORKDIR/pkgconfig"

    OUT="$WORKDIR/out-$VARIANT"
    rm -rf build-android "$OUT"
    meson setup build-android \
        --cross-file android-aarch64.txt \
        -Dbuildtype=release \
        -Dstrip=true \
        -Db_lto=false \
        -Dplatforms=android \
        -Dplatform-sdk-version=$API \
        -Dandroid-stub=true \
        -Dandroid-libbacktrace=disabled \
        -Dgallium-drivers= \
        -Dvulkan-drivers=freedreno \
        -Dvulkan-beta=true \
        -Dfreedreno-kmds=kgsl \
        -Dvideo-codecs= \
        -Degl=disabled -Dopengl=false -Dgles1=disabled -Dgles2=disabled -Dglx=disabled \
        -Dllvm=disabled -Dvalgrind=disabled
    ninja -C build-android src/freedreno/vulkan/libvulkan_freedreno.so
    mkdir -p "$OUT"
    cp build-android/src/freedreno/vulkan/libvulkan_freedreno.so "$OUT/"
}

package() {
    local name desc suffix
    case "$VARIANT" in
        ports)
            name="Turnip Thor Ports"
            desc="A740/Thor: Mesa main 21bbed37 + disk shader cache, GPU boost, port profiles (autotune profiled)"
            suffix="Ports" ;;
        ports-sysmem)
            name="Turnip Thor Ports SYSMEM"
            desc="A740/Thor: Mesa main 21bbed37 + disk shader cache, GPU boost, port profiles (autotune prefer_sysmem)"
            suffix="Ports-SYSMEM" ;;
        upstream)
            name="Turnip Thor Upstream"
            desc="A740/Thor: Mesa main 21bbed37 without patches (control for A/B tests)"
            suffix="Upstream" ;;
    esac

    cd "$OUT"
    cat > meta.json <<EOF
{
  "schemaVersion": 1,
  "name": "$name",
  "description": "$desc (build $BUILD_VERSION)",
  "author": "Mesa + Thor ports patches",
  "packageVersion": "$BUILD_VERSION",
  "vendor": "Mesa",
  "driverVersion": "Mesa 26.x main 21bbed37",
  "minApi": $API,
  "libraryName": "libvulkan_freedreno.so"
}
EOF
    mkdir -p "$ROOT/dist"
    local zip="$ROOT/dist/Turnip_Thor_${suffix}_b${BUILD_VERSION}.zip"
    rm -f "$zip"
    zip -9 -q "$zip" libvulkan_freedreno.so meta.json
    log "Generated: $zip"
}

check_deps
get_ndk
get_mesa
apply_patches
build
package
