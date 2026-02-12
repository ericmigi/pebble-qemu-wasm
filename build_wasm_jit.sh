#!/bin/bash
# Build Pebble QEMU for WebAssembly with TCG-to-WASM JIT backend
# Uses ktock/qemu-wasm wasm64-tcg-b branch + Pebble device model overlay
# JIT compiles hot translation blocks to native WASM modules for ~5-10x speedup
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QEMU_SRC="${QEMU_SRC:-/Users/eric/dev/ktock-qemu-wasm}"
DOCKER_IMAGE="qemu-wasm-jit"
CONTAINER_NAME="build-pebble-wasm-jit"
WEB_DIR="${SCRIPT_DIR}/web"

if [ ! -d "${QEMU_SRC}" ]; then
    echo "Error: ktock qemu-wasm source not found at ${QEMU_SRC}"
    echo "Clone it: git clone --single-branch --branch wasm64-tcg-b --depth 1 https://github.com/ktock/qemu-wasm.git ${QEMU_SRC}"
    exit 1
fi

# Check Docker image exists
if ! docker image inspect "${DOCKER_IMAGE}" &>/dev/null; then
    echo "Error: Docker image '${DOCKER_IMAGE}' not found."
    echo "Build it first:"
    echo "  docker build --progress=plain -t ${DOCKER_IMAGE} -f ${SCRIPT_DIR}/Dockerfile.wasm-jit ${SCRIPT_DIR}"
    exit 1
fi

echo "=== Starting WASM JIT build container ==="

# Stop any existing container
docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true

# Start container with both QEMU source and Pebble overlay mounted read-only
docker run --rm --init -d \
    --name "${CONTAINER_NAME}" \
    -v "${QEMU_SRC}:/qemu-src:ro" \
    -v "${SCRIPT_DIR}:/pebble:ro" \
    "${DOCKER_IMAGE}" \
    sleep infinity

echo "=== Preparing QEMU source with Pebble overlay ==="

# Inside container: copy QEMU source to writable dir and overlay Pebble files
docker exec "${CONTAINER_NAME}" bash -c '
set -ex

# Copy QEMU source to writable location
cp -a /qemu-src /qemu-rw
cd /qemu-rw

# Copy Pebble include files
mkdir -p include/hw/arm
cp /pebble/include/hw/arm/stm32_common.h include/hw/arm/
cp /pebble/include/hw/arm/pebble.h include/hw/arm/
cp /pebble/include/hw/arm/stm32_clktree.h include/hw/arm/

# Copy Pebble hw source files
for dir in arm misc char ssi timer dma display gpio; do
    if [ -d "/pebble/hw/${dir}" ]; then
        mkdir -p "hw/${dir}"
        for f in /pebble/hw/${dir}/*; do
            [ -f "$f" ] && cp "$f" "hw/${dir}/" && echo "  -> hw/${dir}/$(basename "$f")"
        done
    fi
done

# Fix API changes for QEMU 10.2
echo "  Fixing include paths and API renames for QEMU 10.2..."
find hw/ include/hw/ \( -name "*.c" -o -name "*.h" \) -exec sed -i \
    -e "s|\"hw/sysbus.h\"|\"hw/core/sysbus.h\"|g" \
    -e "s|\"hw/irq.h\"|\"hw/core/irq.h\"|g" \
    -e "s|\"hw/qdev-properties-system.h\"|\"hw/core/qdev-properties-system.h\"|g" \
    -e "s|\"hw/qdev-properties.h\"|\"hw/core/qdev-properties.h\"|g" \
    -e "s|\"hw/qdev-clock.h\"|\"hw/core/qdev-clock.h\"|g" \
    -e "s|\"hw/boards.h\"|\"hw/core/boards.h\"|g" \
    -e "s|\"hw/loader.h\"|\"hw/core/loader.h\"|g" \
    -e "s|CharBackend|CharFrontend|g" \
    {} +

# Apply source patches
echo "  Applying patches..."
for p in /pebble/patches/*.patch; do
    [ -f "$p" ] || continue
    patch -p1 --forward < "$p" || true
done

# Patch Kconfig
if ! grep -q "CONFIG_PEBBLE" hw/arm/Kconfig; then
    echo "  Patching hw/arm/Kconfig..."
    cat >> hw/arm/Kconfig << KEOF

config PEBBLE
    bool
    default y
    depends on TCG && ARM
    imply ARM_V7M
    select ARM_V7M
    select PFLASH_CFI02
KEOF
fi

# Patch default.mak
if ! grep -q "CONFIG_PEBBLE" configs/devices/arm-softmmu/default.mak; then
    echo "CONFIG_PEBBLE=y" >> configs/devices/arm-softmmu/default.mak
fi

# Helper function to patch meson.build files
patch_meson() {
    local file="$1"
    local marker="$2"
    local content="$3"
    if ! grep -q "${marker}" "${file}"; then
        echo "  Patching ${file}..."
        printf "\n%s\n" "${content}" >> "${file}"
    fi
}

# hw/arm/meson.build — QEMU 10.x uses arm_common_ss
patch_meson hw/arm/meson.build "CONFIG_PEBBLE" \
"arm_common_ss.add(when: '"'"'CONFIG_PEBBLE'"'"', if_true: files(
  '"'"'pebble.c'"'"',
  '"'"'pebble_robert.c'"'"',
  '"'"'pebble_silk.c'"'"',
  '"'"'pebble_control.c'"'"',
  '"'"'pebble_stm32f4xx_soc.c'"'"',
))"

# hw/misc/meson.build
patch_meson hw/misc/meson.build "stm32_pebble" \
"system_ss.add(when: '"'"'CONFIG_PEBBLE'"'"', if_true: files(
  '"'"'stm32_pebble_rcc.c'"'"',
  '"'"'stm32_pebble_clktree.c'"'"',
  '"'"'stm32_pebble_common.c'"'"',
  '"'"'stm32_pebble_exti.c'"'"',
  '"'"'stm32_pebble_syscfg.c'"'"',
  '"'"'stm32_pebble_adc.c'"'"',
  '"'"'stm32_pebble_pwr.c'"'"',
  '"'"'stm32_pebble_crc.c'"'"',
  '"'"'stm32_pebble_flash.c'"'"',
  '"'"'stm32_pebble_dummy.c'"'"',
  '"'"'stm32_pebble_i2c.c'"'"',
))"

# hw/timer/meson.build
patch_meson hw/timer/meson.build "stm32_pebble" \
"system_ss.add(when: '"'"'CONFIG_PEBBLE'"'"', if_true: files(
  '"'"'stm32_pebble_tim.c'"'"',
  '"'"'stm32_pebble_rtc.c'"'"',
))"

# hw/ssi/meson.build
patch_meson hw/ssi/meson.build "stm32_pebble" \
"system_ss.add(when: '"'"'CONFIG_PEBBLE'"'"', if_true: files('"'"'stm32_pebble_spi.c'"'"'))"

# hw/dma/meson.build
patch_meson hw/dma/meson.build "stm32_pebble" \
"system_ss.add(when: '"'"'CONFIG_PEBBLE'"'"', if_true: files('"'"'stm32_pebble_dma.c'"'"'))"

# hw/display/meson.build
patch_meson hw/display/meson.build "pebble_snowy" \
"system_ss.add(when: '"'"'CONFIG_PEBBLE'"'"', if_true: files('"'"'pebble_snowy_display.c'"'"'))"

# hw/gpio/meson.build
patch_meson hw/gpio/meson.build "stm32_pebble" \
"system_ss.add(when: '"'"'CONFIG_PEBBLE'"'"', if_true: files('"'"'stm32_pebble_gpio.c'"'"'))"

# hw/char/meson.build
patch_meson hw/char/meson.build "stm32_pebble_uart" \
"system_ss.add(when: '"'"'CONFIG_PEBBLE'"'"', if_true: files('"'"'stm32_pebble_uart.c'"'"'))"

# === WASM cross-compilation patches ===

# Patch configure to add exe_wrapper = ['node'] for cross-compilation test runs
CONFIGURE="configure"
if ! grep -q "exe_wrapper" "$CONFIGURE"; then
    sed -i '/echo "strip = \[.*\]" >> \$cross/a\  echo "exe_wrapper = ['"'"'node'"'"']" >> $cross' "$CONFIGURE"
    echo "  Added exe_wrapper to configure"
fi

# Remove EXPORT_ES6 (we use script tag loading)
EMSTXT="configs/meson/emscripten.txt"
if grep -q "EXPORT_ES6" "$EMSTXT"; then
    sed -i "s/'"'"'-sEXPORT_ES6=1'"'"',//g" "$EMSTXT"
    echo "  Removed EXPORT_ES6 from emscripten.txt"
fi

# Add -sMEMORY64=2 for wasm32-compatible 64-bit pointers
if ! grep -q "MEMORY64" "$EMSTXT"; then
    sed -i "s|'"'"'-pthread'"'"'|'"'"'-pthread'"'"','"'"'-sMEMORY64=2'"'"'|" "$EMSTXT"
    echo "  Added -sMEMORY64=2 to emscripten.txt"
fi

# Add --profiling-funcs for Chrome DevTools profiling
if ! grep -q "profiling-funcs" "$EMSTXT"; then
    sed -i "s|addFunction,removeFunction,TTY,FS'"'"']|addFunction,removeFunction,TTY,FS'"'"','"'"'--profiling-funcs'"'"']|g" "$EMSTXT"
    echo "  Added --profiling-funcs to emscripten.txt"
fi

# Clone dtc subproject (needed, source is tarball not git repo)
if [ ! -d subprojects/dtc/libfdt ]; then
    echo "  Cloning dtc subproject..."
    rm -rf subprojects/dtc
    git clone --depth 1 https://github.com/dgibson/dtc.git subprojects/dtc
fi

# Install tomli (needed by QEMU 10.x configure)
pip3 install tomli 2>&1 | tail -1

echo "  Pebble overlay complete."
'

echo "=== Configuring and building ==="

docker exec "${CONTAINER_NAME}" bash -c '
set -ex
cd /build

# Configure QEMU for WASM with arm-softmmu + TCG JIT (NOT --enable-tcg-interpreter)
# The TCG wasm64 backend is auto-detected when host_os=emscripten
emconfigure /qemu-rw/configure \
    --static \
    --cpu=wasm64 \
    --target-list=arm-softmmu \
    --without-default-features \
    --enable-system \
    --disable-tools \
    --disable-docs \
    --disable-pie \
    --extra-cflags="-DSTM32_UART_NO_BAUD_DELAY -O3 -msimd128 -sMEMORY64=2" \
    --extra-ldflags="-sMEMORY64=2" \
    --enable-wasm64-32bit-address-limit

# Build — Emscripten outputs .js extension
ninja -j$(nproc) qemu-system-arm.js 2>&1

EXIT_CODE=$?
echo "EXIT_CODE=$EXIT_CODE"

echo "=== Done ==="
ls -lh qemu-system-arm.js qemu-system-arm.wasm qemu-system-arm.worker.js 2>/dev/null || echo "Build output files not found"
'

echo ""
echo "=== Copying build artifacts ==="

mkdir -p "${WEB_DIR}"

# Copy WASM build output
docker cp "${CONTAINER_NAME}:/build/qemu-system-arm.js" "${WEB_DIR}/"
docker cp "${CONTAINER_NAME}:/build/qemu-system-arm.wasm" "${WEB_DIR}/"
docker cp "${CONTAINER_NAME}:/build/qemu-system-arm.worker.js" "${WEB_DIR}/"

echo ""
echo "=== WASM JIT build complete ==="
ls -lh "${WEB_DIR}/qemu-system-arm"*
