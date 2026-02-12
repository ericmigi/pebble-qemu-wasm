// Profile QEMU WASM worker thread using Chrome Tracing API
// Tracing captures ALL threads (unlike CDP Profiler which is per-target)
import { chromium } from 'playwright';

const url = 'http://localhost:8080/?fw=sdk&auto&shift=3';
const BOOT_WAIT = 120;
const PROFILE_TIME = 30;

console.log(`=== WASM Worker Thread Profile ===\n`);

const browser = await chromium.launch({ headless: true });
const context = await browser.newContext();
const page = await context.newPage();

let displayActive = false;
const startTime = Date.now();
const elapsed = () => ((Date.now() - startTime) / 1000).toFixed(0);

page.on('console', msg => {
    const text = msg.text();
    if (text.includes('Display active')) {
        displayActive = true;
        console.log(`  [${elapsed()}s] ${text}`);
    }
    if (text.startsWith('[fps]')) {
        console.log(`  [${elapsed()}s] [fps] ${text.replace('[fps] ', '')}`);
    }
});

console.log('Booting emulator...');
await page.goto(url);

// Wait for display
const bootStart = Date.now();
while (!displayActive && (Date.now() - bootStart) < BOOT_WAIT * 1000) {
    await page.waitForTimeout(1000);
}
if (!displayActive) {
    console.log('ERROR: Display never became active');
    await browser.close();
    process.exit(1);
}

// Let firmware settle
console.log(`\nDisplay active at ${elapsed()}s. Waiting 15s for firmware to settle...`);
await page.waitForTimeout(15000);

// Navigate to timeline (animate something)
console.log('Navigating to timeline...');
await page.keyboard.down('ArrowDown');
await page.waitForTimeout(100);
await page.keyboard.up('ArrowDown');
await page.waitForTimeout(3000);

// Start Chrome Tracing (captures ALL threads)
const cdp = await context.newCDPSession(page);

const traceEvents = [];
cdp.on('Tracing.dataCollected', ({ value }) => {
    traceEvents.push(...value);
});

console.log(`\nStarting trace at ${elapsed()}s (${PROFILE_TIME}s)...`);
await cdp.send('Tracing.start', {
    categories: [
        'v8.cpu_profiler',
        'devtools.timeline',
        'disabled-by-default-v8.cpu_profiler',
    ].join(','),
    options: 'sampling-frequency=1000',
});

// Animate during profiling
const profileStart = Date.now();
while ((Date.now() - profileStart) < PROFILE_TIME * 1000) {
    await page.keyboard.down('ArrowUp');
    await page.waitForTimeout(100);
    await page.keyboard.up('ArrowUp');
    await page.waitForTimeout(500);
    await page.keyboard.down('ArrowDown');
    await page.waitForTimeout(100);
    await page.keyboard.up('ArrowDown');
    await page.waitForTimeout(2300);
}

// Stop tracing
const traceEnd = new Promise(r => cdp.once('Tracing.tracingComplete', r));
await cdp.send('Tracing.end');
await traceEnd;

console.log(`\nCollected ${traceEvents.length} trace events`);

// Analyze: find all threads
const threadNames = new Map();
for (const e of traceEvents) {
    if (e.name === 'thread_name' && e.args?.name) {
        threadNames.set(e.tid, e.args.name);
    }
}

console.log('\n=== Threads ===');
for (const [tid, name] of threadNames) {
    console.log(`  tid=${tid}: ${name}`);
}

// Find Profile and ProfileChunk events (V8 CPU profiler data)
const profiles = traceEvents.filter(e => e.name === 'Profile' || e.name === 'ProfileChunk');
console.log(`\nProfile events: ${profiles.length}`);

// Group by thread
const profilesByThread = new Map();
for (const e of profiles) {
    const tid = e.tid;
    if (!profilesByThread.has(tid)) {
        profilesByThread.set(tid, { profiles: [], chunks: [] });
    }
    if (e.name === 'Profile') {
        profilesByThread.get(tid).profiles.push(e);
    } else {
        profilesByThread.get(tid).chunks.push(e);
    }
}

// Analyze each thread's profile
for (const [tid, data] of profilesByThread) {
    const threadName = threadNames.get(tid) || `Thread ${tid}`;
    const isMainThread = threadName === 'CrRendererMain' || threadName === 'Renderer';

    // Skip main thread (we already know it's idle)
    if (isMainThread) {
        console.log(`\n=== ${threadName} (tid=${tid}) — SKIPPED (main thread) ===`);
        continue;
    }

    console.log(`\n=== ${threadName} (tid=${tid}) ===`);
    console.log(`  Profile events: ${data.profiles.length}, Chunks: ${data.chunks.length}`);

    // Build node map from Profile event
    const nodeMap = new Map();
    for (const p of data.profiles) {
        if (p.args?.data?.nodes) {
            for (const node of p.args.data.nodes) {
                nodeMap.set(node.id, node);
            }
        }
    }

    // Collect samples and time deltas from chunks
    const allSamples = [];
    const allDeltas = [];
    for (const chunk of data.chunks) {
        if (chunk.args?.data?.cpuProfile) {
            const cp = chunk.args.data.cpuProfile;
            if (cp.samples) allSamples.push(...cp.samples);
            if (cp.nodes) {
                for (const node of cp.nodes) {
                    nodeMap.set(node.id, node);
                }
            }
        }
        if (chunk.args?.data?.timeDeltas) {
            allDeltas.push(...chunk.args.data.timeDeltas);
        }
    }

    if (allSamples.length === 0) {
        console.log(`  No samples collected`);
        continue;
    }

    // Compute self-time per node
    const nodeTimes = new Map();
    for (let i = 0; i < allSamples.length; i++) {
        const nodeId = allSamples[i];
        const delta = allDeltas[i] || 0;
        nodeTimes.set(nodeId, (nodeTimes.get(nodeId) || 0) + delta);
    }

    const totalTime = allDeltas.reduce((s, d) => s + d, 0);
    const sortedNodes = [...nodeTimes.entries()]
        .sort((a, b) => b[1] - a[1])
        .slice(0, 30);

    console.log(`  Total time: ${(totalTime / 1000).toFixed(1)}ms, Samples: ${allSamples.length}`);
    console.log(`\n  ${'%Self'.padStart(7)}  ${'Time(ms)'.padStart(9)}  Function`);
    console.log(`  ${'─'.repeat(7)}  ${'─'.repeat(9)}  ${'─'.repeat(60)}`);

    for (const [nodeId, time] of sortedNodes) {
        const node = nodeMap.get(nodeId);
        if (!node) continue;
        const cf = node.callFrame;
        const pct = (time / totalTime * 100).toFixed(1);
        const timeMs = (time / 1000).toFixed(0);
        const name = cf.functionName || '(anonymous)';
        const url = cf.url ? cf.url.split('/').pop() : '';
        const loc = url ? ` [${url}]` : '';
        console.log(`  ${pct.padStart(7)}%  ${timeMs.padStart(9)}  ${name}${loc}`);
    }
}

// Also look for Wasm function compilation events
const wasmEvents = traceEvents.filter(e =>
    e.name && (e.name.includes('wasm') || e.name.includes('Wasm'))
);
if (wasmEvents.length > 0) {
    console.log(`\n=== WASM Events (${wasmEvents.length}) ===`);
    const weCounts = new Map();
    for (const e of wasmEvents) {
        weCounts.set(e.name, (weCounts.get(e.name) || 0) + 1);
    }
    for (const [name, count] of [...weCounts.entries()].sort((a, b) => b[1] - a[1]).slice(0, 10)) {
        console.log(`  ${count}x ${name}`);
    }
}

await browser.close();
console.log('\nDone');
