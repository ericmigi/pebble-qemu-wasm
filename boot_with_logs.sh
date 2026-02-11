#!/bin/bash
# Boot Pebble QEMU 10.x with live PebbleOS logs
#
# Usage:
#   bash boot_with_logs.sh [--sdk|--full]
#
# Firmware options:
#   --full  Full PebbleOS firmware (default)
#   --sdk   SDK PebbleOS firmware (from Pebble SDK 4.9.77)

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
echo "  Firmware: ${FW_VARIANT} PebbleOS"
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
  >"$DEBUG_LOG" 2>&1 &

QEMU_PID=$!
trap cleanup EXIT

sleep 0.5

# Stream both QEMU stderr and firmware UART logs with timestamps
python3 -u -c '
import sys, time, os, datetime

serial_path = sys.argv[1]
debug_path = sys.argv[2]

serial_fd = os.open(serial_path, os.O_RDONLY)
debug_fd = os.open(debug_path, os.O_RDONLY)
serial_buf = b""
debug_buf = b""

SYNC = b"\x03\x50\x21"
MARKER = b"\x2a\x2a"

def ts():
    return datetime.datetime.now().strftime("%H:%M:%S.%f")[:-3]

QEMU_NOISE = [
    "write 0x", "read 0x",              # register access spam
    "DMA:", "dma:",                      # DMA transfer details
    "unimp",                             # unimplemented stubs
    "guest_errors",                      # harmless guest errors
    "CPU AS read",                       # CPU address space reads
    "DEBUG: CPU AS",                     # CPU address space debug
    "CS changed to",                     # display chip-select toggles
    "cmd=", "cmd_set=",                  # display command details
    "ps_display_execute_current_cmd",    # display command dispatch
    "state change from",                 # display state machine transitions
    "Frame data start",                  # frame data start
    "Asserting done interrupt",          # display interrupt
    "Resetting state to accept",         # display state reset
    "received scene ID",                 # scene details
    "pebble_control_write: bytes:",      # control protocol hex dumps
    "pebble_control_write: qemu_chr",    # control write confirmations
]

# Display commands we DO want to log (one line per meaningful event)
DISPLAY_SHOW = [
    "Executing command:",
    "Exiting programming mode",
    "determine_command_set:",
    "Got last byte in frame",
]

last_frame = -1

def emit(source, text):
    print(f"{ts()} {source:4s} | {text}", flush=True)

# Drain QEMU debug stderr line by line
def process_debug():
    global debug_buf, last_frame
    chunk = os.read(debug_fd, 4096)
    if not chunk:
        return
    debug_buf += chunk
    while b"\n" in debug_buf:
        line, debug_buf = debug_buf.split(b"\n", 1)
        text = line.decode("utf-8", errors="replace").strip()
        if not text:
            continue

        # Condense frame renders to one line
        if "Got last byte in frame" in text:
            # Extract frame number from nearby state change
            # Just emit a compact frame line
            if "bytes:" in text:
                bytes_str = text.split("bytes:")[-1].strip()
                emit("QEMU", f"Display: frame rendered ({bytes_str} total bytes)")
            continue

        # Show select display events without the prefix spam
        if "PEBBLE_SNOWY_DISPLAY:" in text:
            if any(s in text for s in DISPLAY_SHOW):
                # Strip the verbose prefix
                msg = text.replace("PEBBLE_SNOWY_DISPLAY: ", "Display: ")
                emit("QEMU", msg)
            elif any(noise in text for noise in QEMU_NOISE):
                continue
            else:
                emit("QEMU", text)
            continue

        # Show select control events
        if "PEBBLE_CONTROL:" in text:
            if "Sending packet" in text:
                msg = text.replace("PEBBLE_CONTROL: pebble_control_write: ", "Control: ")
                emit("QEMU", msg)
            elif any(noise in text for noise in QEMU_NOISE):
                continue
            else:
                emit("QEMU", text)
            continue

        if any(noise in text for noise in QEMU_NOISE):
            continue
        emit("QEMU", text)

# Parse firmware UART protocol frames
def process_serial():
    global serial_buf
    chunk = os.read(serial_fd, 4096)
    if not chunk:
        return
    serial_buf += chunk

    while True:
        idx = serial_buf.find(SYNC)
        if idx < 0:
            if len(serial_buf) > 512:
                serial_buf = serial_buf[-512:]
            break

        star = serial_buf.find(MARKER, idx)
        if star < 0:
            break

        # Extract tag (uppercase letters before \x01+\x03**)
        tag = ""
        pre = serial_buf[idx:star]
        j = len(pre) - 1
        while j >= 0 and pre[j] in (0x01, 0x03):
            j -= 1
        k = j
        while k >= 0 and 0x41 <= pre[k] <= 0x5a:
            k -= 1
        if j > k >= 0:
            tag = pre[k+1:j+1].decode("ascii", errors="replace")

        # Skip \x01 padding after **
        pos = star + 2
        while pos < len(serial_buf) and serial_buf[pos] == 0x01:
            pos += 1
        if pos >= len(serial_buf):
            break

        # Find end of frame
        next_sync = serial_buf.find(SYNC, pos)
        if next_sync < 0:
            if len(serial_buf) - pos > 4096:
                serial_buf = serial_buf[pos:]
            break

        end = next_sync
        while end > pos and serial_buf[end-1] == 0x55:
            end -= 1
        if end - pos >= 4:
            end -= 3

        payload = serial_buf[pos:end]
        serial_buf = serial_buf[next_sync:]

        text = ""
        for b in payload:
            if 32 <= b <= 126 or b in (9, 10, 13):
                text += chr(b)
        text = text.strip()

        if text and len(text) >= 2:
            label = tag if tag else "FIRM"
            emit("FIRM", text)

while True:
    process_debug()
    process_serial()
    time.sleep(0.02)
' "$SERIAL_LOG" "$DEBUG_LOG" &

wait "$QEMU_PID" 2>/dev/null || true
