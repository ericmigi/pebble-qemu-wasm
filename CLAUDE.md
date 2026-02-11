# Project: pebble-qemu-wasm

## Environment
- Shell: fish
- Python: use venv (not pyenv, not system python)

## Building QEMU 2.5.0-pebble8

### Prerequisites

```fish
# brew deps (most already installed)
brew install autoconf pyenv sdl2 zlib pixman glib gettext pcre2

# Python 2.7 (QEMU 2.5 configure requires it)
pyenv install 2.7.18
# Binary ends up at: ~/.pyenv/versions/2.7.18/bin/python
```

### DTC submodule

Must be fetched before configure:
```fish
cd ~/dev/qemu
git submodule update --init dtc
```

### Configure

```fish
cd ~/dev/qemu
./configure \
  --with-coroutine=gthread \
  --disable-werror \
  --disable-mouse \
  --disable-cocoa \
  --enable-debug \
  --enable-sdl \
  --with-sdlabi=2.0 \
  --target-list=arm-softmmu \
  --extra-cflags=-DSTM32_UART_NO_BAUD_DELAY \
  --extra-ldflags=-g \
  --disable-vnc-jpeg \
  --disable-vnc-png \
  --disable-curses \
  --disable-gnutls \
  --disable-nettle \
  --disable-libssh2 \
  --disable-vnc-sasl \
  --disable-gcrypt \
  --disable-bzip2 \
  --disable-lzo \
  --disable-libusb \
  --python=$HOME/.pyenv/versions/2.7.18/bin/python
```

These flags match the CI in `.github/workflows/build.yaml`. Key choices:
- `--target-list=arm-softmmu` — only build ARM system emulator
- `--enable-sdl --with-sdlabi=2.0` — SDL2 display output
- `--disable-cocoa` — use SDL not native macOS UI
- `-DSTM32_UART_NO_BAUD_DELAY` — skip UART baud rate timing (faster emulation)
- `--with-coroutine=gthread` — gthread coroutine backend (required, default doesn't work)

### Build

```fish
cd ~/dev/qemu
make -j(sysctl -n hw.ncpu)
```

Output: `~/dev/qemu/arm-softmmu/qemu-system-arm` (10MB, arm64 Mach-O)

Some warnings about neon_helper.c constant-conversion are expected and harmless.

## Firmware Files

### Location in SDK

Pebble SDK 4.9.77 firmware lives at:
```
~/Library/Application Support/Pebble SDK/SDKs/4.9.77/sdk-core/pebble/<platform>/qemu/
```

Platforms: aplite, basalt, chalk, diorite, emery, flint

### Preparing emery firmware

```fish
mkdir -p ~/dev/pebble-qemu-wasm/firmware

# Micro flash (bootloader + firmware) — copy as-is
cp ~/Library/Application\ Support/Pebble\ SDK/SDKs/4.9.77/sdk-core/pebble/emery/qemu/qemu_micro_flash.bin \
   ~/dev/pebble-qemu-wasm/firmware/

# SPI flash (filesystem) — stored compressed, must decompress
python3 -c "
import bz2, shutil
with bz2.open('$HOME/Library/Application Support/Pebble SDK/SDKs/4.9.77/sdk-core/pebble/emery/qemu/qemu_spi_flash.bin.bz2', 'rb') as f_in:
    with open('$HOME/dev/pebble-qemu-wasm/firmware/qemu_spi_flash.bin', 'wb') as f_out:
        shutil.copyfileobj(f_in, f_out)
"
```

Result: `qemu_micro_flash.bin` (827KB) + `qemu_spi_flash.bin` (16MB)

## Running the Emulator

### Emery (Pebble Time 2)

```fish
~/dev/qemu/arm-softmmu/qemu-system-arm \
  -rtc base=localtime \
  -serial null \
  -serial tcp::12344,server,nowait \
  -serial tcp::12345,server,nowait \
  -pflash ~/dev/pebble-qemu-wasm/firmware/qemu_micro_flash.bin \
  -gdb tcp::1234,server,nowait \
  -machine pebble-snowy-emery-bb \
  -cpu cortex-m4 \
  -pflash ~/dev/pebble-qemu-wasm/firmware/qemu_spi_flash.bin
```

Serial ports:
- serial 0: null (unused)
- serial 1: TCP 12344 — Pebble Protocol (binary framing: 0xFEED header, 0xBEEF footer)
- serial 2: TCP 12345 — debug/console serial

GDB server on TCP 1234.

SDL window opens at 200x228 (emery display resolution) showing the Pebble UI.

### Platform-to-machine mapping

| Platform | Machine | CPU | SPI flash flag |
|----------|---------|-----|----------------|
| aplite | pebble-bb2 | cortex-m3 | -mtdblock |
| basalt | pebble-snowy-bb | cortex-m4 | -pflash |
| chalk | pebble-s4-bb | cortex-m4 | -pflash |
| diorite | pebble-silk-bb | cortex-m4 | -mtdblock |
| emery | pebble-snowy-emery-bb | cortex-m4 | -pflash |
| flint | pebble-silk-bb | cortex-m4 | -mtdblock |

Note: emery uses `-pflash` for SPI flash, aplite/diorite/flint use `-mtdblock`.

### Boot verification

The SDK's emulator.py (at `~/.local/share/uv/tools/pebble-tool/lib/python3.13/site-packages/pebble_tool/sdk/emulator.py`) waits for these strings on TCP 12344:
- `<SDK Home>`
- `<Launcher>`
- `Ready for communication`

Quick check with netcat:
```fish
nc localhost 12344
```

Or programmatic check:
```python
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(15)
s.connect(('localhost', 12344))
data = s.recv(4096)
# Expect Pebble protocol frames (binary, FEED...BEEF framing)
s.close()
```

### Screenshotting the QEMU window

```fish
# Get window position and size
osascript -e '
tell application "System Events"
    tell process "qemu-system-arm"
        set w to window 1
        set {x, y} to position of w
        set {width, height} to size of w
        return {x, y, width, height}
    end tell
end tell'
# Returns something like: 1022, 855, 200, 256

# Screenshot at that position
screencapture -x -R1022,855,200,256 /tmp/qemu_window.png
```

Note: `screencapture -l <windowID>` doesn't work for QEMU's SDL window (AppleScript can't get the window ID). Use `-R x,y,w,h` with coordinates from AppleScript instead.

## Running on QEMU 10.x (Phase 2 port)

### Build

```fish
cd ~/dev/pebble-qemu-wasm
bash build.sh
```

Binary: `~/dev/qemu-10.0/build/qemu-system-arm`

### Emery boot command (with pebble-tool TCP serial)

```fish
bash boot_for_pebble_tool.sh
```

Or manually:
```fish
~/dev/qemu-10.0/build/qemu-system-arm \
  -machine pebble-snowy-emery-bb \
  -kernel ~/dev/pebble-qemu-wasm/firmware/qemu_micro_flash.bin \
  -drive if=none,id=spi-flash,file=~/dev/pebble-qemu-wasm/firmware/qemu_spi_flash.bin,format=raw \
  -serial null \
  -serial "tcp::12344,server,nowait" \
  -serial "tcp::12345,server,nowait" \
  -d unimp -D /tmp/qemu_unimp.log
```

For standalone debugging with file-based logs instead of TCP:
```fish
bash boot_with_logs.sh
```

Key differences from QEMU 2.5:
- Uses `-kernel` instead of `-pflash` for micro flash (machine doesn't support pflash drive)
- Uses `-drive if=none,id=spi-flash` for SPI NOR flash (same as 2.5)
- No `-cpu cortex-m4` needed (machine sets it automatically)
- Serial port mapping: serial0=null, serial1=pebble control (USART2), serial2=debug (USART3)

### Connecting pebble-tool

pebble-tool connects to QEMU via the `--qemu` flag, speaking the FEED/BEEF protocol over TCP serial1 (port 12344).

```fish
# Install an app
pebble install --qemu localhost:12344 /path/to/app.pbw

# Take a screenshot
pebble screenshot --qemu localhost:12344

# Stream logs
pebble logs --qemu localhost:12344
```

Notes:
- SPI flash (`qemu_spi_flash.bin`) is modified in-place when apps are installed. Back up the file first if needed.
- Wait ~30 seconds after QEMU starts before connecting pebble-tool (firmware needs time to boot).

### Current status (2026-02-10)
- Firmware v4.9.77-3-geb9f6e61 boots successfully
- Display renders frames (bootloader splash, firmware UI)
- TicToc watchface is launched but does not fully render (shows "Install an app to continue")
- Launcher/Watchfaces menu works
- UART serial output works on serial2
- pebble-tool connects via `--qemu localhost:12344` (screenshot, logs, install confirmed working)

## Debugging

### GDB

```fish
arm-none-eabi-gdb ~/Library/Application\ Support/Pebble\ SDK/SDKs/4.9.77/sdk-core/pebble/emery/qemu/emery_sdk_debug.elf
# In GDB:
target remote :1234
```

### QEMU monitor

Add `-monitor stdio` to the QEMU command to get the QEMU monitor on stdin/stdout.
Or add `-monitor tcp::4445,server,nowait` for TCP access.

### Debug serial

```fish
nc localhost 12345
```

### Verbose QEMU logging

Add `-d` flag with categories:
```fish
-d out_asm,in_asm,op,op_opt,int,exec,cpu,pcall,cpu_reset,ioport,unimp,guest_errors
```

### Extra debug compile flags

Rebuild with additional `-extra-cflags`:
```
-DDEBUG_CLKTREE        # Clock tree
-DDEBUG_STM32_RCC      # Reset/clock controller
-DDEBUG_STM32_UART     # UART
-DDEBUG_GIC            # Interrupt controller
```
