#!/usr/bin/env bash
# Turnip for the AYN Thor (Snapdragon 8 Gen 2 / Adreno 740, Android 13): a gaming build for games,
# emulators and console ports.
#
#   Mesa main 21bbed37 (2026-11-06) + patches/:
#     - disk shader cache on Android (all apps)
#     - KGSL GPU and CPU L3 boost (on for all apps)
#     - tiling for MUTABLE images without a format list when no view can swap (all apps)
#     - driconf profiles for Xenia- and shadPS4-based ports (autotune profiled, concurrent binning,
#       A2C emulation for Xenia, opt-in tiling for 4-byte mutable images)
#     - experimental UBWC for mutable images (off; TU_MUTABLE_UBWC=1 in the app's environment)
#     - per-app TU_DEBUG flags through driconf (tu_debug), with an Eden/yuzu profile hook
#
# Usage:  VARIANT=thor          ./build.sh   (default: everything above)
#         VARIANT=thor-safe     ./build.sh   (same, without the opt-in 4-byte tiling in the port profiles)
#         VARIANT=thor-nocb     ./build.sh   (same as thor, without concurrent binning in the port profiles)
#         VARIANT=thor-eden-sysmem ./build.sh (test: Eden/yuzu renders every pass in system memory)
#         VARIANT=thor-eden-nolrz  ./build.sh (test: Eden/yuzu without LRZ)
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
VARIANT="${VARIANT:-thor}"
BUILD_VERSION="${BUILD_VERSION:-1}"
# The Thor ships Android 13. Building against a newer API level can reference libc symbols that
# Android 13 does not have, and the driver would fail to load.
API=33
# Snapdragon 8 Gen 2: Cortex-X3 + A715/A710 + A510, all ARMv9.0. armv8.2-a (a subset every core
# has) gives inline LSE atomics instead of LL/SC loops; tuned for the A715/A710 cores where the
# render threads run. Not for older phones.
CPU_FLAGS="'-march=armv8.2-a+fp16+dotprod+rcpc', '-mtune=cortex-a715'"

log() { echo -e "\033[0;32m$*\033[0m"; }
die() { echo -e "\033[0;31m$*\033[0m" >&2; exit 1; }

case "$VARIANT" in
    thor|thor-safe|thor-nocb|thor-eden-sysmem|thor-eden-nolrz|upstream) ;;
    *) die "VARIANT must be thor, thor-safe, thor-nocb, thor-eden-sysmem, thor-eden-nolrz or upstream (got '$VARIANT')" ;;
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
    if [ "$VARIANT" = thor-safe ]; then
        sed -i 's|value="true" /> <!-- ports-tiling -->|value="false" /> <!-- ports-tiling -->|' "$conf"
    fi
    if [ "$VARIANT" = thor-nocb ]; then
        sed -i 's|value="true" /> <!-- ports-cb -->|value="false" /> <!-- ports-cb -->|' "$conf"
    fi
    local eden=""
    [ "$VARIANT" = thor-eden-sysmem ] && eden=sysmem
    [ "$VARIANT" = thor-eden-nolrz ] && eden=nolrz
    if [ -n "$eden" ]; then
        sed -i "s|value=\"\" /> <!-- eden-debug -->|value=\"$eden\" /> <!-- eden-debug -->|" "$conf"
    fi

    # Guard rails: fail instead of shipping a driver without what its name promises.
    local drirc=src/freedreno/vulkan/tu_drirc_gen.py
    grep -q "android_app_cache_dir" src/util/disk_cache_os.c || die "disk cache patch missing"
    grep -q "KGSL_PROP_PWR_CONSTRAINT" src/freedreno/vulkan/tu_knl_kgsl.cc || die "GPU boost patch missing"
    grep -q "KGSL_PROP_L3_PWR_CONSTRAINT" src/freedreno/vulkan/tu_knl_kgsl.cc || die "L3 boost patch missing"
    grep -q 'B("tu_kgsl_gpu_boost", True' "$drirc" || die "GPU boost is not on by default"
    grep -q 'B("tu_kgsl_l3_boost", True' "$drirc" || die "L3 boost is not on by default"
    grep -q "size_class_has_swaps" src/freedreno/vulkan/tu_image.cc || die "mutable tiling patch missing"
    grep -q "drirc.perf.mutable_ubwc" src/freedreno/vulkan/tu_image.cc || die "mutable UBWC patch missing"
    grep -q "TU_MUTABLE_UBWC" src/freedreno/vulkan/tu_device.cc || die "env switches missing"
    grep -q "tu_env_add_debug_flags" src/freedreno/vulkan/tu_util.cc || die "per-app TU_DEBUG patch missing"
    [ "$(grep -c "value=\"$eden\" /> <!-- eden-debug -->" "$conf")" = 1 ] ||
        die "Eden profile does not set tu_debug to '$eden'"
    [ "$(grep -c 'value="profiled" /> <!-- ports-autotune -->' "$conf")" = 2 ] ||
        die "port profiles do not use autotune 'profiled'"
    local cb=true tiling=true
    [ "$VARIANT" = thor-nocb ] && cb=false
    [ "$VARIANT" = thor-safe ] && tiling=false
    [ "$(grep -c "value=\"$cb\" /> <!-- ports-cb -->" "$conf")" = 2 ] ||
        die "port profiles do not set concurrent binning to '$cb'"
    [ "$(grep -c "value=\"$tiling\" /> <!-- ports-tiling -->" "$conf")" = 2 ] ||
        die "port profiles do not set 4-byte mutable tiling to '$tiling'"
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
        thor)
            name="Turnip Thor v5"
            desc="AYN Thor/A740 v5: Mesa main 21bbed37 + shader cache, GPU+L3 boost, mutable tiling, port profiles, TU_MUTABLE_UBWC switch, per-app TU_DEBUG"
            suffix="v5" ;;
        thor-safe)
            name="Turnip Thor v5 Safe"
            desc="AYN Thor/A740 v5 without the opt-in 4-byte mutable tiling in the port profiles"
            suffix="v5-Safe" ;;
        thor-nocb)
            name="Turnip Thor v5 NoCB"
            desc="AYN Thor/A740 v5 without concurrent binning in the port profiles"
            suffix="v5-NoCB" ;;
        thor-eden-sysmem)
            name="Turnip Thor v5 Eden SYSMEM"
            desc="AYN Thor/A740 v5, test build: Eden/yuzu renders every pass in system memory (TU_DEBUG=sysmem for that app only)"
            suffix="v5-Eden-SYSMEM" ;;
        thor-eden-nolrz)
            name="Turnip Thor v5 Eden NOLRZ"
            desc="AYN Thor/A740 v5, test build: Eden/yuzu without LRZ (TU_DEBUG=nolrz for that app only)"
            suffix="v5-Eden-NOLRZ" ;;
        upstream)
            name="Turnip Thor Upstream"
            desc="AYN Thor/A740: Mesa main 21bbed37 without patches (control for A/B tests)"
            suffix="Upstream" ;;
    esac

    cd "$OUT"
    cat > meta.json <<EOF
{
  "schemaVersion": 1,
  "name": "$name",
  "description": "$desc (build $BUILD_VERSION)",
  "author": "Mesa + AYN Thor patches",
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
