// Check TCI instrumentation output and profile the WORKER thread
// (QEMU runs on a pthread worker due to PROXY_TO_PTHREAD)
import { chromium } from 'playwright';

const url = 'http://localhost:8080/?fw=sdk&auto&shift=3';
const BOOT_WAIT = 180;
const RUN_TIME = 60;

console.log(`=== TCI Instrumentation + Worker Profile ===\n`);

const browser = await chromium.launch({ headless: true });
const context = await browser.newContext();
const page = await context.newPage();

let displayActive = false;
const startTime = Date.now();
const tciMessages = [];

function elapsed() {
    return ((Date.now() - startTime) / 1000).toFixed(0);
}

// Capture main page console
page.on('console', msg => {
    const text = msg.text();
    if (text.includes('[tci]')) {
        tciMessages.push(text);
        console.log(`  [${elapsed()}s] [main/tci] ${text}`);
    }
    if (text.includes('Display active')) {
        displayActive = true;
        console.log(`  [${elapsed()}s] ${text}`);
    }
    if (text.startsWith('[fps]')) {
        console.log(`  [${elapsed()}s] ${text}`);
    }
    // stderr from worker may arrive as warnings
    if (msg.type() === 'warning' || msg.type() === 'error') {
        if (text.includes('tci') || text.includes('Mops') || text.includes('ops/s')) {
            console.log(`  [${elapsed()}s] [stderr] ${text}`);
            tciMessages.push(text);
        }
    }
});

// Capture worker console messages
page.on('worker', worker => {
    console.log(`  [${elapsed()}s] Worker created: ${worker.url().split('/').pop()}`);
    // Workers don't have a direct console event in Playwright,
    // but we can try CDP
});

console.log('Booting emulator...');
await page.goto(url);

// Wait for display active
const bootStart = Date.now();
while (!displayActive && (Date.now() - bootStart) < BOOT_WAIT * 1000) {
    await page.waitForTimeout(1000);
}

if (!displayActive) {
    console.log('ERROR: Display never became active');
    await browser.close();
    process.exit(1);
}

console.log(`\nDisplay active at ${elapsed()}s. Navigating to timeline...`);
await page.waitForTimeout(5000);
await page.keyboard.down('ArrowDown');
await page.waitForTimeout(100);
await page.keyboard.up('ArrowDown');
await page.waitForTimeout(3000);

// Use CDP to find and profile worker threads
const cdp = await context.newCDPSession(page);

// Get all targets including workers
const browserCdp = await browser.newBrowserCDPSession();
const { targetInfos } = await browserCdp.send('Target.getTargets');

console.log(`\nAll targets:`);
const workerTargets = [];
for (const t of targetInfos) {
    const label = `${t.type}: ${t.title || t.url.split('/').pop() || '(none)'}`;
    console.log(`  ${label}`);
    if (t.type === 'worker' || t.type === 'service_worker') {
        workerTargets.push(t);
    }
}

// Try to attach to worker and profile it
let workerProfile = null;
for (const wt of workerTargets) {
    try {
        const { sessionId } = await browserCdp.send('Target.attachToTarget', {
            targetId: wt.targetId,
            flatten: true,
        });
        console.log(`\nAttached to worker: ${wt.url.split('/').pop()}`);

        // Enable console on worker to capture TCI stderr
        await browserCdp.send('Runtime.enable', {}, sessionId);

        // Listen for console messages from worker
        browserCdp.on('Runtime.consoleAPICalled', (params) => {
            if (params.sessionId === sessionId) {
                const text = params.args.map(a => a.value || a.description || '').join(' ');
                if (text.includes('[tci]') || text.includes('Mops')) {
                    tciMessages.push(text);
                    console.log(`  [${elapsed()}s] [worker/tci] ${text}`);
                }
            }
        });

        // Start CPU profiler on worker
        await browserCdp.send('Profiler.enable', {}, sessionId);
        await browserCdp.send('Profiler.start', {}, sessionId);
        console.log(`CPU profiler started on worker at ${elapsed()}s`);

        // Run animation
        console.log(`\nRunning animation for ${RUN_TIME}s...`);
        const animStart = Date.now();
        while ((Date.now() - animStart) < RUN_TIME * 1000) {
            await page.keyboard.down('ArrowUp');
            await page.waitForTimeout(100);
            await page.keyboard.up('ArrowUp');
            await page.waitForTimeout(500);
            await page.keyboard.down('ArrowDown');
            await page.waitForTimeout(100);
            await page.keyboard.up('ArrowDown');
            await page.waitForTimeout(2300);
        }

        // Stop profiler
        const result = await browserCdp.send('Profiler.stop', {}, sessionId);
        workerProfile = result.profile;
        break;
    } catch (err) {
        console.log(`  Failed to attach to worker: ${err.message}`);
    }
}

// If no worker found, fall back to main thread profile
if (!workerProfile) {
    console.log('\nNo worker profiled. Running main thread profile...');
    await cdp.send('Profiler.enable');
    await cdp.send('Profiler.start');

    const animStart = Date.now();
    while ((Date.now() - animStart) < RUN_TIME * 1000) {
        await page.keyboard.down('ArrowUp');
        await page.waitForTimeout(100);
        await page.keyboard.up('ArrowUp');
        await page.waitForTimeout(500);
        await page.keyboard.down('ArrowDown');
        await page.waitForTimeout(100);
        await page.keyboard.up('ArrowDown');
        await page.waitForTimeout(2300);
    }

    const { profile } = await cdp.send('Profiler.stop');
    workerProfile = profile;
}

// Analyze profile
if (workerProfile) {
    const nodes = workerProfile.nodes;
    const samples = workerProfile.samples;
    const timeDeltas = workerProfile.timeDeltas;

    const nodeMap = new Map();
    for (const node of nodes) {
        nodeMap.set(node.id, node);
    }

    const nodeTimes = new Map();
    for (let i = 0; i < samples.length; i++) {
        const nodeId = samples[i];
        const delta = timeDeltas[i] || 0;
        nodeTimes.set(nodeId, (nodeTimes.get(nodeId) || 0) + delta);
    }

    const sortedNodes = [...nodeTimes.entries()]
        .sort((a, b) => b[1] - a[1])
        .slice(0, 30);

    const totalTime = timeDeltas.reduce((s, d) => s + d, 0);

    console.log(`\n=== Worker CPU Profile (${(totalTime / 1e6).toFixed(1)}s) ===`);
    console.log(`Top 30 functions by self-time:\n`);
    console.log(`${'%Self'.padStart(7)}  ${'Time(ms)'.padStart(9)}  Function`);
    console.log(`${'─'.repeat(7)}  ${'─'.repeat(9)}  ${'─'.repeat(60)}`);

    for (const [nodeId, time] of sortedNodes) {
        const node = nodeMap.get(nodeId);
        const fn = node.callFrame;
        const pct = (time / totalTime * 100).toFixed(1);
        const timeMs = (time / 1000).toFixed(0);
        const name = fn.functionName || '(anonymous)';
        console.log(`${pct.padStart(7)}%  ${timeMs.padStart(9)}  ${name}`);
    }
}

// TCI stats
console.log(`\n=== TCI Instrumentation ===`);
if (tciMessages.length > 0) {
    for (const m of tciMessages) {
        console.log(`  ${m}`);
    }
} else {
    console.log('  No TCI messages captured.');
    console.log('  (stderr from PROXY_TO_PTHREAD worker may not reach page console)');
    console.log('  Consider checking browser DevTools manually or modifying TCI');
    console.log('  output to use emscripten_log() instead of fprintf(stderr).');
}

await browser.close();
console.log('\nDone');
