// Render an icon SVG to a transparent 1024×1024 PNG with Google Chrome (Playwright).
//   node scripts/render-icon.mjs assets/icon/AppIcon.svg assets/icon/AppIcon.png
// Playwright is resolved from $PLAYWRIGHT_DIR (default ~/node_modules/playwright).
import { createRequire } from 'node:module';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const [input, output] = process.argv.slice(2);
if (!input || !output) {
  console.error('usage: render-icon.mjs <icon.svg> <out.png>');
  process.exit(2);
}
const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT_DIR ?? join(homedir(), 'node_modules/playwright'));

const browser = await chromium.launch({ channel: 'chrome' });
try {
  const page = await browser.newPage({ viewport: { width: 1024, height: 1024 }, deviceScaleFactor: 1 });
  const errors = [];
  page.on('pageerror', e => errors.push(e.message));
  page.on('requestfailed', r => errors.push(`request failed: ${r.url()}`));
  await page.goto(pathToFileURL(resolve(input)).href, { waitUntil: 'load' });
  await page.evaluate(() => document.fonts.ready);
  if (errors.length) throw new Error(errors.join('\n'));
  await page.screenshot({ path: resolve(output), omitBackground: true, clip: { x: 0, y: 0, width: 1024, height: 1024 } });
} finally {
  await browser.close();
}
console.log(`IMAGE=${resolve(output)}`);
