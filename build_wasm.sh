#!/bin/bash
# Build Pebble QEMU for WebAssembly using Emscripten (via Docker)
# Uses QEMU 10.1 with native WASM/TCI support + Pebble device model overlay
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QEMU_SRC="${QEMU_SRC:-/Users/eric/dev/qemu-10.1.0}"
DOCKER_IMAGE="qemu101-wasm-base"
CONTAINER_NAME="build-pebble-wasm"
WEB_DIR="${SCRIPT_DIR}/web"

if [ ! -d "${QEMU_SRC}" ]; then
    echo "Error: QEMU 10.1 source not found at ${QEMU_SRC}"
    echo "Download from https://download.qemu.org/qemu-10.1.0.tar.xz"
    exit 1
fi

# Check Docker image exists
if ! docker image inspect "${DOCKER_IMAGE}" &>/dev/null; then
    echo "Error: Docker image '${DOCKER_IMAGE}' not found."
    echo "Build it first:"
    echo "  docker build --progress=plain -t ${DOCKER_IMAGE} - < ${QEMU_SRC}/tests/docker/dockerfiles/emsdk-wasm32-cross.docker"
    exit 1
fi

echo "=== Starting WASM build container ==="

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

# hw/arm/meson.build — QEMU 10.1 uses arm_common_ss (not arm_ss)
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
python3 /pebble/scripts/patch_wasm.py /qemu-rw

# Clone dtc subproject (needed, source is tarball not git repo)
if [ ! -d subprojects/dtc/libfdt ]; then
    echo "  Cloning dtc subproject..."
    rm -rf subprojects/dtc
    git clone --depth 1 https://github.com/dgibson/dtc.git subprojects/dtc
fi

# Install tomli (needed by QEMU 10.1 configure)
pip3 install tomli 2>&1 | tail -1

echo "  Pebble overlay complete."
'

echo "=== Configuring and building ==="

docker exec "${CONTAINER_NAME}" bash -c '
set -ex
cd /build

# Configure QEMU for WASM with arm-softmmu + TCI
emconfigure /qemu-rw/configure \
    --static \
    --target-list=arm-softmmu \
    --without-default-features \
    --enable-system \
    --enable-tcg-interpreter \
    --disable-tools \
    --disable-docs \
    --disable-pie \
    --extra-cflags="-DSTM32_UART_NO_BAUD_DELAY -DTCI_INSTRUMENT -flto -msimd128" \
    --extra-ldflags="-flto"

# Build — Emscripten outputs .js extension, so target is qemu-system-arm.js
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
echo "=== WASM build complete ==="
ls -lh "${WEB_DIR}/qemu-system-arm"*
