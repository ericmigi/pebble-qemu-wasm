#!/bin/bash
# Boot Pebble QEMU 10.x with TCP serial ports for pebble-tool connectivity
#
# Usage:
#   bash boot_for_pebble_tool.sh [--sdk|--full]
#
# Firmware options:
#   --full  Full PebbleOS firmware (default)
#   --sdk   SDK PebbleOS firmware (from Pebble SDK 4.9.77)
#
# Then connect pebble-tool:
#   pebble install --qemu localhost:12344 /path/to/app.pbw
#   pebble screenshot --qemu localhost:12344
#   pebble logs --qemu localhost:12344
#
# Environment variables:
#   PEBBLE_QEMU_PORT       - pebble control port (default: 12344)
#   PEBBLE_QEMU_DEBUG_PORT - debug serial port (default: 12345)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QEMU="${SCRIPT_DIR}/../qemu-10.0/build/qemu-system-arm"

# Parse firmware selection (default: full)
FW_VARIANT="full"
for arg in "$@"; do
    case "$arg" in
        --sdk) FW_VARIANT="sdk" ;;
        --full) FW_VARIANT="full" ;;
        *) echo "Unknown option: $arg"; echo "Usage: $0 [--sdk|--full]"; exit 1 ;;
    esac
done

FW_DIR="${SCRIPT_DIR}/firmware/${FW_VARIANT}"

if [ ! -f "${FW_DIR}/qemu_micro_flash.bin" ]; then
    echo "Error: Firmware not found at ${FW_DIR}/"
    echo "Expected: qemu_micro_flash.bin and qemu_spi_flash.bin"
    exit 1
fi

PEBBLE_PORT="${PEBBLE_QEMU_PORT:-12344}"
DEBUG_PORT="${PEBBLE_QEMU_DEBUG_PORT:-12345}"

cleanup() {
    echo ""
    echo "Stopping QEMU (pid $QEMU_PID)..."
    kill "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
    echo "Done."
}

echo "=== Starting Pebble QEMU 10.x (emery) with TCP serial ==="
echo "  Firmware:       ${FW_VARIANT} PebbleOS"
echo "  Pebble control: tcp://localhost:${PEBBLE_PORT}"
echo "  Debug serial:   tcp://localhost:${DEBUG_PORT}"
echo "  Press Ctrl-C to stop"
echo ""

"$QEMU" \
  -machine pebble-snowy-emery-bb \
  -kernel "${FW_DIR}/qemu_micro_flash.bin" \
  -drive if=none,id=spi-flash,file="${FW_DIR}/qemu_spi_flash.bin",format=raw \
  -serial null \
  -serial "tcp::${PEBBLE_PORT},server,nowait" \
  -serial "tcp::${DEBUG_PORT},server,nowait" \
  -d unimp -D /tmp/qemu_unimp.log \
  &

QEMU_PID=$!
trap cleanup EXIT

echo "QEMU started (pid $QEMU_PID). Waiting for boot..."
echo "Connect with: pebble install --qemu localhost:${PEBBLE_PORT} /path/to/app.pbw"
echo ""

wait "$QEMU_PID" 2>/dev/null || true
