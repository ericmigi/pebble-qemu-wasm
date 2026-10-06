// End-to-end boot/install/audio smoke test against the local COOP/COEP server.
// AUDIO_TEST_PBW=/path/to/MorseCodeTrainer.pbw node scripts/test_pebble_audio.mjs
import fs from 'node:fs';
import path from 'node:path';
import {chromium} from 'playwright';

const caches = path.join(process.env.HOME, 'Library/Caches/ms-playwright');
const versions = (fs.existsSync(caches) ? fs.readdirSync(caches) : []).filter(n => /^chromium-\d+$/.test(n))
  .sort((a, b) => Number(b.split('-')[1]) - Number(a.split('-')[1]));
const executablePath = process.env.AUDIO_TEST_CHROMIUM || (versions[0] ? path.join(caches, versions[0],
  'chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing') : undefined);
const browser = await chromium.launch({headless: true, executablePath});
const page = await browser.newPage();
const errors = [];
page.on('pageerror', e => { errors.push(e.message); console.log('[pageerror]', e.message); });
page.on('console', m => {
  if (/\*\*\* ASSERTION FAILED|FreeRTOS assert/.test(m.text())) errors.push(m.text());
  if (/\[audio\]|\[install\]|Ready|Starting Launcher|Connected to the watch|Aborted|abort|signature mismatch/.test(m.text())) console.log('[browser]', m.text());
});
try {
  if (process.env.AUDIO_TEST_MICRO) {
    await page.route('**/firmware/emery/qemu_micro_flash.bin', route =>
      route.fulfill({path: process.env.AUDIO_TEST_MICRO, contentType: 'application/octet-stream'}));
  }
  if (process.env.AUDIO_TEST_SPI) {
    await page.route('**/firmware/emery/qemu_spi_flash.bin', route =>
      route.fulfill({path: process.env.AUDIO_TEST_SPI, contentType: 'application/octet-stream'}));
  }
  await page.goto(process.env.AUDIO_TEST_URL || 'http://127.0.0.1:8087/?board=emery', {timeout: 30000});
  await page.waitForFunction(() => window.__emu && window.qemu?._pebble_wasm_display_frame_count() > 0,
    null, {timeout: 180000});
  console.log('BOOT', await page.evaluate(() => ({status: document.getElementById('status')?.textContent,
    frames: qemu._pebble_wasm_display_frame_count(), size: [qemu._pebble_wasm_display_width(), qemu._pebble_wasm_display_height()]})));
  const pbw = fs.readFileSync(process.env.AUDIO_TEST_PBW || '/tmp/pebble-MorseCodeTrainer.pbw');
  await page.evaluate(async bytes => window.__emu.installPbw(Uint8Array.from(bytes), 'MorseCodeTrainer.pbw'), [...pbw]);
  console.log('INSTALL', await page.locator('#install-status').textContent());
  await page.waitForTimeout(5000);
  await page.screenshot({path: '/tmp/pebble-qemu-audio-app.png'});
  const box = await page.locator('#canvas').boundingBox();
  await page.mouse.move(box.x + box.width * 0.25, box.y + box.height * 0.75);
  await page.mouse.down();
  await page.waitForFunction(() => window.__audioStats?.nonzero > 0, null, {timeout: 30000});
  await page.evaluate(() => {
    const analyser = __audioOutput.context.createAnalyser();
    __audioOutput.node.connect(analyser);
    window.__audioAnalyser = analyser;
  });
  // Inspect the WebAudio graph, in addition to the worklet's PCM counters.
  await page.waitForFunction(() => {
    const data = new Float32Array(__audioAnalyser.fftSize);
    __audioAnalyser.getFloatTimeDomainData(data);
    return data.some(value => Math.abs(value) > 0.001);
  }, null, {timeout: 5000});
  await page.waitForTimeout(Number(process.env.AUDIO_TEST_HOLD_MS || 5000));
  console.log('AUDIO_HOLD', await page.evaluate(() => window.__audioStats));
  await page.mouse.up();
  await page.waitForTimeout(4000);
  const settled = await page.evaluate(() => window.__audioStats);
  await page.waitForTimeout(700);
  const quiet = await page.evaluate(() => window.__audioStats);
  console.log('AUDIO_RELEASE', quiet);
  if (quiet.nonzero !== settled.nonzero || quiet.queued !== 0) {
    throw new Error('Audio did not settle to silence after release');
  }
  // Top half confirms; bottom half generates marks (default layout = 3).
  for (let i = 0; i < 3; i++) {
    await page.mouse.down();
    await page.waitForTimeout(80);
    await page.mouse.up();
    await page.waitForTimeout(160);
  }
  await page.waitForTimeout(4000);
  const dots = await page.evaluate(() => window.__audioStats);
  console.log('AUDIO_DOTS', dots);
  if (dots.nonzero <= quiet.nonzero || dots.maxQueued > 512) {
    throw new Error('Short marks produced no audio or exceeded the PCM queue limit');
  }
  console.log('AUDIO_CLOCK', await page.evaluate(() => ({
    time: __audioOutput.context.currentTime, state: __audioOutput.context.state})));
  console.log('ERRORS', errors);
  if (errors.length) throw new Error('Browser reported runtime errors');
} finally {
  await page.screenshot({path: '/tmp/pebble-qemu-audio-final.png'}).catch(() => {});
  console.log('STATUS', await page.locator('#status').textContent().catch(() => 'unavailable'));
  const log = await page.locator('#console').textContent().catch(() => '');
  fs.writeFileSync('/tmp/pebble-audio-console.log', log);
  console.log('LOG_TAIL', (await page.locator('#console').textContent().catch(() => '')).slice(-1200));
  await browser.close();
}
