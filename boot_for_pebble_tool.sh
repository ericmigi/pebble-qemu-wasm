#!/bin/bash
# Boot Pebble QEMU 10.x with TCP serial ports for pebble-tool connectivity
#
# Usage:
#   bash boot_for_pebble_tool.sh
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
FW_DIR="${SCRIPT_DIR}/firmware"

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
