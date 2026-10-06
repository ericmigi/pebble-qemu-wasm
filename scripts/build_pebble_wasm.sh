#!/usr/bin/env bash
# Build the prepared Pebble overlay separately from the shipped WASM binary.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QEMU_SRC="${QEMU_SRC:-$(dirname "$PROJECT_DIR")/ktock-qemu-wasm}"
IMAGE="${QEMU_WASM_IMAGE:-qemu-wasm-jit}"
JOBS="${QEMU_WASM_JOBS:-8}"
INSTALL="${1:-}"
if [[ -n "$INSTALL" && "$INSTALL" != --install ]]; then
  echo "Usage: $0 [--install]" >&2
  exit 2
fi
test -f "$QEMU_SRC/VERSION"
docker image inspect "$IMAGE" >/dev/null
# The base commit adds these files. Existing Pebble sources may include
# subsequent bridge edits, so do not reverse-check an entire added C file.
if [[ ! -f "$QEMU_SRC/hw/arm/pebble_generic.c" ]]; then
  git -C "$QEMU_SRC" apply --check "$PROJECT_DIR/patches/pebble14_base.patch"
  git -C "$QEMU_SRC" apply "$PROJECT_DIR/patches/pebble14_base.patch"
fi
PATCH="$PROJECT_DIR/patches/pebble_wasm_bridges.patch"
if git -C "$QEMU_SRC" apply --check "$PATCH" 2>/dev/null; then
  git -C "$QEMU_SRC" apply "$PATCH"
else
  git -C "$QEMU_SRC" apply --reverse --check "$PATCH"
fi
mkdir -p "$QEMU_SRC/build/pebble-wasm"
docker run --rm --init \
  -v "$QEMU_SRC:/qemu" -w /qemu/build/pebble-wasm \
  -e BUILD_JOBS="$JOBS" "$IMAGE" bash -euc '
    if [ ! -f build.ninja ]; then
      emconfigure /qemu/configure \
        --static --cpu=wasm64 --target-list=arm-softmmu \
        --without-default-features --enable-system \
        --disable-tools --disable-docs --disable-pie --disable-werror \
        --extra-cflags="-O3 -msimd128 -sMEMORY64=2" \
        --extra-ldflags="-sMEMORY64=2 -sMODULARIZE=1" \
        --enable-wasm64-32bit-address-limit
    fi
    # Meson retains cross-file options across reconfiguration. Synchronize
    # the runtime exports explicitly when rebuilding an existing directory.
    pyvenv/bin/python - <<"PY"
import ast, json, pathlib, subprocess
args = ["meson", "configure"]
for line in pathlib.Path("/qemu/configs/meson/emscripten.txt").read_text().splitlines():
    if line.startswith(("c_link_args =", "cpp_link_args =")):
        name, value = line.split("=", 1)
        args.append("-D" + name.strip() + "=" + json.dumps(ast.literal_eval(value.strip())))
subprocess.run(args, check=True)
PY
    ninja -j"$BUILD_JOBS" qemu-system-arm.js
  '
echo "Build artifacts: $QEMU_SRC/build/pebble-wasm/"
if [[ "$INSTALL" == --install ]]; then
  cp "$QEMU_SRC/build/pebble-wasm/qemu-system-arm.js" "$PROJECT_DIR/qemu-system-arm.js"
  cp "$QEMU_SRC/build/pebble-wasm/qemu-system-arm.js" "$PROJECT_DIR/qemu-system-arm.mjs"
  cp "$QEMU_SRC/build/pebble-wasm/qemu-system-arm.wasm" "$PROJECT_DIR/qemu-system-arm.wasm"
  echo "Installed generic WASM artifacts in $PROJECT_DIR"
fi
