import { chromium } from 'playwright';
const browser = await chromium.launch({ headless: true });
const page = await (await browser.newContext()).newPage();
const lines = [];
page.on('console', msg => {
    lines.push(msg.text());
    if (msg.text().includes('pebble') || msg.text().includes('stellaris')) {
        console.log('FOUND:', msg.text());
    }
});
await page.goto('http://localhost:8080/?fw=sdk&auto&shift=3', { waitUntil: 'domcontentloaded' });
await page.waitForTimeout(15000);
console.log('\n=== All machine-related output ===');
lines.filter(l => l.includes('machine') || l.includes('Supported') || l.includes('pebble') || l.includes('stellaris') || l.includes('vexpress') || l.includes('none')).forEach(l => console.log(l));
console.log('\n=== Total lines:', lines.length, '===');
await browser.close();
