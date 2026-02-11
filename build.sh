#!/bin/bash
# Build script for Pebble QEMU 10.x
# Overlays Pebble device model files onto QEMU 10.0, patches build system, and builds.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QEMU_SRC="/Users/eric/dev/qemu-10.0"
BUILD_DIR="${QEMU_SRC}/build"
VENV_DIR="${SCRIPT_DIR}/.venv"

if [ ! -d "${QEMU_SRC}" ]; then
    echo "Error: QEMU 10.0 source not found at ${QEMU_SRC}"
    exit 1
fi

echo "=== Overlaying Pebble files onto QEMU 10.0 ==="

# Copy include files
mkdir -p "${QEMU_SRC}/include/hw/arm"
cp "${SCRIPT_DIR}/include/hw/arm/stm32_common.h" "${QEMU_SRC}/include/hw/arm/"
cp "${SCRIPT_DIR}/include/hw/arm/pebble.h" "${QEMU_SRC}/include/hw/arm/"
cp "${SCRIPT_DIR}/include/hw/arm/stm32_clktree.h" "${QEMU_SRC}/include/hw/arm/"

# Copy hw source files (including headers in source dirs)
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
    # --forward skips already-applied patches; || true so we don't fail
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
# Helper: append to meson file if marker not present
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

# hw/arm/meson.build - insert before the hw_arch line
patch_meson "${QEMU_SRC}/hw/arm/meson.build" "CONFIG_PEBBLE" \
"arm_ss.add(when: 'CONFIG_PEBBLE', if_true: files(
  'pebble.c',
  'pebble_robert.c',
  'pebble_silk.c',
  'pebble_control.c',
  'pebble_stm32f4xx_soc.c',
))"

# hw/misc/meson.build - RCC, clktree, common, EXTI, SYSCFG, ADC, PWR, CRC, flash, dummy, I2C
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

# hw/timer/meson.build - timers AND RTC (RTC is in timer dir)
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

# hw/char/meson.build - Pebble's own UART (type "stm32-uart", no conflict
# with mainline's "stm32f2xx-usart"). Do NOT include stm32_pebble_usart.c
# (the agent-ported version) since its type name conflicts with mainline.
patch_meson "${QEMU_SRC}/hw/char/meson.build" "stm32_pebble_uart" \
"system_ss.add(when: 'CONFIG_PEBBLE', if_true: files('stm32_pebble_uart.c'))"

echo ""
echo "=== Building ==="

# Ensure venv
if [ ! -d "${VENV_DIR}" ]; then
    python3 -m venv "${VENV_DIR}"
    "${VENV_DIR}/bin/pip" install meson ninja distlib tomli
fi

cd "${QEMU_SRC}"

# Reconfigure to pick up new files (delete build.ninja to force)
rm -f "${BUILD_DIR}/build.ninja"

# Activate venv so meson/ninja are on PATH, then run configure
export PATH="${VENV_DIR}/bin:$PATH"
"${QEMU_SRC}/configure" \
    --target-list=arm-softmmu \
    --python="${VENV_DIR}/bin/python3" \
    --enable-sdl 2>&1 | tail -5

cd "${BUILD_DIR}"
ninja -j$(sysctl -n hw.ncpu 2>/dev/null || nproc) qemu-system-arm 2>&1

echo ""
echo "=== Build complete ==="
echo "Binary: ${BUILD_DIR}/qemu-system-arm"
