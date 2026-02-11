#!/bin/bash
# Boot Pebble QEMU 10.x with live PebbleOS logs
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QEMU="${SCRIPT_DIR}/../qemu-10.0/build/qemu-system-arm"
FW_DIR="${SCRIPT_DIR}/firmware"
SERIAL_LOG="/tmp/pebble_serial.log"
DEBUG_LOG="/tmp/pebble_debug.log"

rm -f "$SERIAL_LOG" "$DEBUG_LOG"
touch "$SERIAL_LOG" "$DEBUG_LOG"

cleanup() {
    echo ""
    echo "Stopping QEMU (pid $QEMU_PID)..."
    kill "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
    kill $(jobs -p) 2>/dev/null || true
    echo "Done. Raw logs: $SERIAL_LOG  Debug: $DEBUG_LOG"
}

echo "=== Starting Pebble QEMU 10.x (emery) ==="
echo "  Press Ctrl-C to stop"
echo ""

"$QEMU" \
  -machine pebble-snowy-emery-bb \
  -kernel "${FW_DIR}/qemu_micro_flash.bin" \
  -drive if=none,id=spi-flash,file="${FW_DIR}/qemu_spi_flash.bin",format=raw \
  -serial null \
  -serial null \
  -serial file:"${SERIAL_LOG}" \
  -d unimp -D /tmp/qemu_unimp.log \
  2>"$DEBUG_LOG" &

QEMU_PID=$!
trap cleanup EXIT

sleep 0.5

# Stream PebbleOS UART logs, extracting readable text from binary protocol frames
python3 -u -c '
import sys, time, os

path = sys.argv[1]
fd = os.open(path, os.O_RDONLY)
buf = b""

while True:
    chunk = os.read(fd, 4096)
    if not chunk:
        time.sleep(0.05)
        continue
    buf += chunk

    # Extract runs of printable ASCII (len >= 4), emit as log lines
    i = 0
    while i < len(buf):
        # Find start of printable run
        if 32 <= buf[i] <= 126:
            j = i
            while j < len(buf) and 32 <= buf[j] <= 126:
                j += 1
            if j == len(buf):
                # Might be incomplete, keep in buffer
                buf = buf[i:]
                break
            run = buf[i:j].decode("ascii", errors="replace")
            if len(run) >= 4:
                # Clean up common framing artifacts
                run = run.strip()
                if run:
                    print(run, flush=True)
            i = j
        else:
            i += 1
    else:
        buf = b""
' "$SERIAL_LOG" &

wait "$QEMU_PID" 2>/dev/null || true
