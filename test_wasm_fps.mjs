// Test WASM Pebble emulator FPS with timeline animation
// SDK firmware: boot → press Down → timeline sloth animation
// Keep pressing Up then Down every 3s to restart animation
//
// Usage: node test_wasm_fps.mjs [shift_value]

import { chromium } from 'playwright';

const shift = process.argv[2] || '3';
const url = `http://localhost:8080/?fw=sdk&auto&shift=${shift}`;
const BOOT_WAIT = 180;  // max seconds to wait for first frame
const SETTLE_TIME = 30; // seconds after display active before sending keys
const ANIM_DURATION = 90; // seconds to run animation

console.log(`=== WASM FPS Test (shift=${shift}) ===`);
console.log(`URL: ${url}`);

const browser = await chromium.launch({ headless: true });
const context = await browser.newContext();
const page = await context.newPage();

const allFps = [];
const bootFps = [];
const animFps = [];
let phase = 'boot';
let displayActive = false;
const startTime = Date.now();

function elapsed() {
    return ((Date.now() - startTime) / 1000).toFixed(0);
}

page.on('console', msg => {
    const text = msg.text();

    if (text.startsWith('[fps]')) {
        const fps = parseFloat(text.replace('[fps] ', ''));
        const entry = { fps, elapsed: +elapsed(), phase };
        allFps.push(entry);
        if (phase === 'boot') bootFps.push(entry);
        if (phase === 'animation') animFps.push(entry);
        console.log(`  [${elapsed()}s] [${phase}] FPS: ${fps}`);
    }

    if (text.includes('Display active')) {
        displayActive = true;
        console.log(`  [${elapsed()}s] ${text}`);
    }

    if (text.includes('[config] icount')) {
        console.log(`  Config: ${text}`);
    }
});

async function pressKey(key, holdMs = 100) {
    await page.keyboard.down(key);
    await page.waitForTimeout(holdMs);
    await page.keyboard.up(key);
}

console.log(`\nBooting emulator...`);
await page.goto(url);

// Wait for display to become active
const bootStart = Date.now();
while (!displayActive && (Date.now() - bootStart) < BOOT_WAIT * 1000) {
    await page.waitForTimeout(1000);
}

if (!displayActive) {
    console.log('ERROR: Display never became active');
    await browser.close();
    process.exit(1);
}

// Let firmware settle after display active
console.log(`Display active at ${elapsed()}s, waiting ${SETTLE_TIME}s for firmware to settle...`);
await page.waitForTimeout(SETTLE_TIME * 1000);

console.log('\n=== Boot FPS ===');
bootFps.forEach(f => console.log(`  FPS: ${f.fps} at ${f.elapsed}s`));
if (bootFps.length > 0) {
    const avg = bootFps.reduce((s, f) => s + f.fps, 0) / bootFps.length;
    console.log(`  Boot avg: ${avg.toFixed(1)}`);
}

// Navigate: from boot screen, press Down to enter timeline
console.log('\n=== Entering timeline ===');
console.log('Pressing Down (ArrowDown)...');
await pressKey('ArrowDown');
await page.waitForTimeout(5000);

// Start animation phase
phase = 'animation';
console.log(`\n=== Measuring FPS with timeline animation (${ANIM_DURATION}s) ===`);
console.log('(pressing Up then Down every 3s to restart animation)');

const animStart = Date.now();
while ((Date.now() - animStart) < ANIM_DURATION * 1000) {
    await pressKey('ArrowUp');
    await page.waitForTimeout(500);
    await pressKey('ArrowDown');
    await page.waitForTimeout(2500);
}

// Results
console.log('\n=== Animation FPS Results ===');
animFps.forEach(f => console.log(`  FPS: ${f.fps} at ${f.elapsed}s`));

console.log('\n=== Summary ===');
if (bootFps.length > 0) {
    const avg = bootFps.reduce((s, f) => s + f.fps, 0) / bootFps.length;
    console.log(`Boot Average FPS: ${avg.toFixed(1)} (${bootFps.length} readings)`);
}
if (animFps.length > 0) {
    const avg = animFps.reduce((s, f) => s + f.fps, 0) / animFps.length;
    console.log(`Animation Average FPS: ${avg.toFixed(1)} (${animFps.length} readings)`);
} else {
    console.log('No animation FPS readings captured');
}

await browser.close();
console.log('\nDone');
