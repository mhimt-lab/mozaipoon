// Make testdata/screen.mov: a 9 s iPhone-like screen recording (886×1920, 30 fps) of a chat
// with made-up personal information (scripts/screen-sample/phone.html), for the screen-text mode.
// It stays still (0–2 s), scrolls (2–5 s), and shows a notification (5.5–7.8 s).
//   node scripts/make-screen-sample.mjs [output]   (default testdata/screen.mov; needs Google Chrome, Playwright and ffmpeg)
// Playwright is resolved from $PLAYWRIGHT_DIR (default ~/node_modules/playwright).
import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync } from 'node:fs';
import { createRequire } from 'node:module';
import { homedir, tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT_DIR ?? join(homedir(), 'node_modules/playwright'));
const page = resolve('scripts/screen-sample/phone.html');
const out = resolve(process.argv[2] ?? 'testdata/screen.mov');
mkdirSync(dirname(out), { recursive: true });
const frames = mkdtempSync(join(tmpdir(), 'screen-sample-'));
const fps = 30, seconds = 9;

const browser = await chromium.launch({ channel: 'chrome' });
try {
  const p = await browser.newPage({ viewport: { width: 393, height: 852 }, deviceScaleFactor: 2.25 });
  await p.goto(pathToFileURL(page).href);
  await p.evaluate(() => document.fonts.ready);
  for (let i = 0; i < fps * seconds; i++) {
    await p.evaluate(t => setT(t), i / fps);
    await p.screenshot({ path: join(frames, String(i).padStart(4, '0') + '.png') });
  }
} finally {
  await browser.close();
}
execFileSync('ffmpeg', ['-v', 'error', '-y', '-framerate', String(fps), '-i', join(frames, '%04d.png'),
  '-vf', 'scale=886:1920:flags=lanczos', '-c:v', 'libx264', '-preset', 'slow', '-crf', '16', '-pix_fmt', 'yuv420p', out]);
rmSync(frames, { recursive: true });
console.log(`VIDEO=${out}`);
