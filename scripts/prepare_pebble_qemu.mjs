// Overlay the preserved Pebble sources on ktock's QEMU 10.2 WASM fork.
// Usage: node scripts/prepare_pebble_qemu.mjs <pebble-source> <wasm-source>
import fs from 'node:fs';
import path from 'node:path';

const [source, target] = process.argv.slice(2).map(p => path.resolve(p));
if (!source || !target || source === target) throw new Error('Two distinct source directories required');
for (const root of [source, target]) {
  if (!fs.existsSync(path.join(root, 'VERSION'))) throw new Error(`Not a QEMU source tree: ${root}`);
}
const read = (root, file) => fs.readFileSync(path.join(root, file), 'utf8');
const deviceDirs = ['arm', 'misc', 'display', 'gpio', 'char', 'ssi', 'dma', 'timer', 'block'];
// Fail before copying anything if the target already contains an overlay.
for (const dir of deviceDirs) {
  if (read(target, `hw/${dir}/meson.build`).includes("when: 'CONFIG_PEBBLE'")) {
    throw new Error(`Already overlaid: hw/${dir}/meson.build`);
  }
}
const write = (file, content) => {
  fs.mkdirSync(path.dirname(path.join(target, file)), {recursive: true});
  fs.writeFileSync(path.join(target, file), content);
};
const coreHeaders = ['sysbus', 'irq', 'qdev-properties', 'qdev-properties-system',
  'qdev-clock', 'boards', 'loader', 'clock'];
function port(text) {
  for (const name of coreHeaders) text = text.replaceAll(`"hw/${name}.h"`, `"hw/core/${name}.h"`);
  return text.replaceAll('"hw/qdev-core.h"', '"hw/core/qdev.h"')
    .replaceAll('"audio/audio.h"', '"qemu/audio.h"')
    .replaceAll('CharBackend', 'CharFrontend');
}
let copied = 0;
for (const top of ['hw', 'include/hw']) {
  for (const entry of fs.readdirSync(path.join(source, top), {recursive: true, withFileTypes: true})) {
    if (!entry.isFile() || !/^(?:pebble|stm32_pebble|stm32_common|stm32_clktree).*\.[ch]$/.test(entry.name)) continue;
    const parent = entry.parentPath ?? entry.path;
    const rel = path.relative(source, path.join(parent, entry.name));
    write(rel, port(read(source, rel)));
    copied++;
  }
}
// AudioBackend replaced QEMUSoundCard in QEMU 10.2.
const audioPath = 'hw/misc/pebble_audio.c';
let audio = read(target, audioPath)
  .replace('QEMUSoundCard card;', 'AudioBackend *audio_be;')
  .replaceAll('&s->card', 's->audio_be')
  .replace('AUD_register_card("pebble-audio", s->audio_be, errp)', 'AUD_backend_check(&s->audio_be, errp)')
  .replace('DEFINE_AUDIO_PROPERTIES(PblAudio, card)', 'DEFINE_AUDIO_PROPERTIES(PblAudio, audio_be)')
  .replace('AUD_set_volume_out(s->voice, 0, vol, vol)', 'AUD_set_volume_out_lr(s->voice, false, vol, vol)');
write(audioPath, audio);
// Machine enumeration is target-specific in QEMU 10.2.
const machinePath = 'hw/arm/pebble_generic.c';
write(machinePath, read(target, machinePath)
  .replace('#include "hw/arm/boot.h"', '#include "hw/arm/boot.h"\n#include "hw/arm/machines-qom.h"')
  .replace('.abstract      = true,', '.abstract      = true,\n    .interfaces    = arm_machine_interfaces,'));
for (const dir of deviceDirs) {
  const file = `hw/${dir}/meson.build`;
  const blocks = read(source, file).match(/\w+\.add\(when: 'CONFIG_PEBBLE', if_true: files\([\s\S]*?\)\)/g) ?? [];
  let text = read(target, file);
  if (text.includes("when: 'CONFIG_PEBBLE'")) throw new Error(`Already overlaid: ${file}`);
  write(file, text + '\n' + blocks.join('\n\n') + '\n');
}
write('hw/arm/Kconfig', read(target, 'hw/arm/Kconfig') + '\n' + read(source, 'hw/arm/Kconfig').split('\nconfig PEBBLE\n')[1].replace(/^/, 'config PEBBLE\n'));
console.log(`Copied ${copied} Pebble source/header files; preserved Pebble audio IRQ and realtime timer changes.`);
