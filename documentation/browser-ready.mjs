// Starts Playwright Chromium once, so that check.sh can tell a browser that is
// not installed (exit 3) from one that does not start (exit 4), usually for
// missing system libraries, before browser-check.mjs needs it.
import { chromium } from 'playwright';

try {
  const browser = await chromium.launch();
  await browser.close();
} catch (error) {
  const missing = /Executable doesn't exist at (\S+)/.exec(error.message);
  if (missing) {
    console.error(`documentation: Playwright Chromium is not installed (no ${missing[1]}).`);
    process.exit(3);
  }
  const detail = error.message.split('\n').filter(line => line.trim()).slice(0, 8).join('\n  ');
  console.error(`documentation: Playwright Chromium is installed but does not start, usually because system libraries are missing:\n  ${detail}`);
  process.exit(4);
}
