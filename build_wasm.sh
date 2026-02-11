#!/bin/bash
# Build Pebble QEMU for WebAssembly using Emscripten (via Docker)
# Uses QEMU 10.1 with native WASM support + Pebble device model overlay
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QEMU_SRC="/Users/eric/dev/qemu-10.1.0"
DOCKER_IMAGE="qemu-wasm-base"
CONTAINER_NAME="build-qemu-wasm"
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

echo "=== Overlaying Pebble files onto QEMU 10.1 ==="

# Copy include files
mkdir -p "${QEMU_SRC}/include/hw/arm"
cp "${SCRIPT_DIR}/include/hw/arm/stm32_common.h" "${QEMU_SRC}/include/hw/arm/"
cp "${SCRIPT_DIR}/include/hw/arm/pebble.h" "${QEMU_SRC}/include/hw/arm/"
cp "${SCRIPT_DIR}/include/hw/arm/stm32_clktree.h" "${QEMU_SRC}/include/hw/arm/"

# Copy hw source files
for dir in arm misc char ssi timer dma display gpio; do
    if [ -d "${SCRIPT_DIR}/hw/${dir}" ]; then
        mkdir -p "${QEMU_SRC}/hw/${dir}"
        for f in "${SCRIPT_DIR}/hw/${dir}"/*; do
            [ -f "$f" ] && cp "$f" "${QEMU_SRC}/hw/${dir}/" && echo "  -> hw/${dir}/$(basename "$f")"
        done
    fi
done

# === Apply source patches ===
echo "  Applying patches..."
for p in "${SCRIPT_DIR}/patches/"*.patch; do
    [ -f "$p" ] || continue
    patch -d "${QEMU_SRC}" -p1 --forward < "$p" || true
done

# === Patch Kconfig ===
KCONFIG="${QEMU_SRC}/hw/arm/Kconfig"
if ! grep -q "CONFIG_PEBBLE" "${KCONFIG}"; then
    echo "  Patching hw/arm/Kconfig..."
    cat >> "${KCONFIG}" << 'EOF'

config PEBBLE
    bool
    default y
    depends on TCG && ARM
    imply ARM_V7M
    select ARM_V7M
    select PFLASH_CFI02
EOF
fi

# === Patch default.mak ===
DEFAULT_MAK="${QEMU_SRC}/configs/devices/arm-softmmu/default.mak"
if ! grep -q "CONFIG_PEBBLE" "${DEFAULT_MAK}"; then
    echo "CONFIG_PEBBLE=y" >> "${DEFAULT_MAK}"
fi

# === Patch meson.build files ===
patch_meson() {
    local file="$1"
    local marker="$2"
    local content="$3"
    if ! grep -q "${marker}" "${file}"; then
        echo "  Patching ${file}..."
        echo "" >> "${file}"
        echo "${content}" >> "${file}"
    fi
}

# hw/arm/meson.build — QEMU 10.1 uses arm_common_ss for non-virt ARM devices
# Insert BEFORE the hw_arch line
ARM_MESON="${QEMU_SRC}/hw/arm/meson.build"
if ! grep -q "CONFIG_PEBBLE" "${ARM_MESON}"; then
    echo "  Patching hw/arm/meson.build..."
    sed -i.bak "/^hw_arch += {'arm': arm_ss}/i\\
arm_common_ss.add(when: 'CONFIG_PEBBLE', if_true: files(\\
  'pebble.c',\\
  'pebble_robert.c',\\
  'pebble_silk.c',\\
  'pebble_control.c',\\
  'pebble_stm32f4xx_soc.c',\\
))" "${ARM_MESON}"
fi

# hw/misc/meson.build
patch_meson "${QEMU_SRC}/hw/misc/meson.build" "stm32_pebble" \
"system_ss.add(when: 'CONFIG_PEBBLE', if_true: files(
  'stm32_pebble_rcc.c',
  'stm32_pebble_clktree.c',
  'stm32_pebble_common.c',
  'stm32_pebble_exti.c',
  'stm32_pebble_syscfg.c',
  'stm32_pebble_adc.c',
  'stm32_pebble_pwr.c',
  'stm32_pebble_crc.c',
  'stm32_pebble_flash.c',
  'stm32_pebble_dummy.c',
  'stm32_pebble_i2c.c',
))"

# hw/timer/meson.build
patch_meson "${QEMU_SRC}/hw/timer/meson.build" "stm32_pebble" \
"system_ss.add(when: 'CONFIG_PEBBLE', if_true: files(
  'stm32_pebble_tim.c',
  'stm32_pebble_rtc.c',
))"

# hw/ssi/meson.build
patch_meson "${QEMU_SRC}/hw/ssi/meson.build" "stm32_pebble" \
"system_ss.add(when: 'CONFIG_PEBBLE', if_true: files('stm32_pebble_spi.c'))"

# hw/dma/meson.build
patch_meson "${QEMU_SRC}/hw/dma/meson.build" "stm32_pebble" \
"system_ss.add(when: 'CONFIG_PEBBLE', if_true: files('stm32_pebble_dma.c'))"

# hw/display/meson.build
patch_meson "${QEMU_SRC}/hw/display/meson.build" "pebble_snowy" \
"system_ss.add(when: 'CONFIG_PEBBLE', if_true: files('pebble_snowy_display.c'))"

# hw/gpio/meson.build
patch_meson "${QEMU_SRC}/hw/gpio/meson.build" "stm32_pebble" \
"system_ss.add(when: 'CONFIG_PEBBLE', if_true: files('stm32_pebble_gpio.c'))"

# hw/char/meson.build
patch_meson "${QEMU_SRC}/hw/char/meson.build" "stm32_pebble_uart" \
"system_ss.add(when: 'CONFIG_PEBBLE', if_true: files('stm32_pebble_uart.c'))"

echo ""
echo "=== Building WASM inside Docker ==="

# Stop any existing container
docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true

# Start build container with QEMU source mounted
docker run --rm --init -d \
    --name "${CONTAINER_NAME}" \
    -v "${QEMU_SRC}:/qemu:ro" \
    "${DOCKER_IMAGE}" \
    sleep infinity

# Build inside container
docker exec "${CONTAINER_NAME}" bash -c '
set -ex
cd /build

# Configure QEMU for WASM with arm-softmmu + TCI
emconfigure /qemu/configure \
    --static \
    --target-list=arm-softmmu \
    --without-default-features \
    --enable-system \
    --enable-tcg-interpreter \
    --disable-tools \
    --disable-docs \
    --disable-gtk \
    --disable-sdl \
    --disable-opengl \
    --disable-virglrenderer \
    --disable-vnc \
    --disable-spice \
    --disable-curses \
    --disable-brlapi \
    --disable-vte \
    --disable-pie

# Build
emmake make -j$(nproc) qemu-system-arm 2>&1

echo "=== Build output files ==="
ls -la qemu-system-arm* 2>/dev/null || echo "No output files found"
'

echo ""
echo "=== Copying build artifacts ==="

mkdir -p "${WEB_DIR}"

# Copy WASM build output
docker cp "${CONTAINER_NAME}:/build/qemu-system-arm" "${WEB_DIR}/qemu-system-arm.js" 2>/dev/null || true
docker cp "${CONTAINER_NAME}:/build/qemu-system-arm.js" "${WEB_DIR}/qemu-system-arm.js" 2>/dev/null || true
docker cp "${CONTAINER_NAME}:/build/qemu-system-arm.wasm" "${WEB_DIR}/" 2>/dev/null || true
docker cp "${CONTAINER_NAME}:/build/qemu-system-arm.worker.js" "${WEB_DIR}/" 2>/dev/null || true

# Copy pc-bios files needed by QEMU
docker exec "${CONTAINER_NAME}" bash -c '
mkdir -p /build/pack
cp -r /qemu/pc-bios/*.bin /build/pack/ 2>/dev/null || true
cp -r /qemu/pc-bios/*.rom /build/pack/ 2>/dev/null || true
cp -r /qemu/pc-bios/*.dtb /build/pack/ 2>/dev/null || true
'

# Stop container
docker stop "${CONTAINER_NAME}" 2>/dev/null || true

echo ""
echo "=== WASM build complete ==="
echo "Output: ${WEB_DIR}/"
ls -la "${WEB_DIR}/"
