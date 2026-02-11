#!/usr/bin/env python3
"""Patch QEMU source for WASM cross-compilation.

1. Add exe_wrapper = ['node'] to configure's cross-file generation
2. Remove -sEXPORT_ES6=1 from emscripten.txt (we use script tag loading)
"""
import sys
import os

qemu_dir = sys.argv[1] if len(sys.argv) > 1 else '/qemu-rw'

# 1. Patch configure to add exe_wrapper
configure_path = os.path.join(qemu_dir, 'configure')
with open(configure_path, 'r') as f:
    content = f.read()

target = 'echo "strip = [$(meson_quote $strip)]" >> $cross'
if 'exe_wrapper' not in content:
    replacement = target + "\n  echo \"exe_wrapper = ['node']\" >> $cross"
    content = content.replace(target, replacement, 1)
    with open(configure_path, 'w') as f:
        f.write(content)
    print('Patched configure for exe_wrapper')
else:
    print('configure already has exe_wrapper')

# 2. Remove EXPORT_ES6 from emscripten.txt
ems_path = os.path.join(qemu_dir, 'configs/meson/emscripten.txt')
with open(ems_path, 'r') as f:
    content = f.read()

if '-sEXPORT_ES6=1' in content:
    content = content.replace("'-sEXPORT_ES6=1',", '')
    with open(ems_path, 'w') as f:
        f.write(content)
    print('Removed EXPORT_ES6 from emscripten.txt')
else:
    print('EXPORT_ES6 already removed')
