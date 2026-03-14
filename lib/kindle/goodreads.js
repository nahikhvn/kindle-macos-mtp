#!/usr/bin/env node
// Goodreads Playwright automation for kindle sync
// Usage:
//   node goodreads.js login --session <path>
//   node goodreads.js push  --session <path> --book-id <id> [--shelf <name>] [--rating <1-5>] [--percent <0-100>]
//
// Exit codes: 0=success, 1=error, 2=session expired

const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

function parseArgs(args) {
  const result = {};
  for (let i = 0; i < args.length; i++) {
    if (args[i].startsWith('--')) {
      const key = args[i].slice(2);
      const val = args[i + 1] && !args[i + 1].startsWith('--') ? args[++i] : true;
      result[key] = val;
    } else if (!result._cmd) {
      result._cmd = args[i];
    }
  }
  return result;
}

async function login(sessionPath) {
  const browser = await chromium.launch({ headless: false });
  const context = await browser.newContext();
  const page = await context.newPage();

  await page.goto('https://www.goodreads.com/user/sign_in');

  process.stderr.write('Log in to Goodreads in the browser window.\nWaiting for login to complete...\n');

  // Wait until user lands on a Goodreads page that isn't part of the auth flow
  try {
    await page.waitForURL(url => {
      const u = new URL(url);
      // Stay waiting while on any sign-in / auth / SSO page
      if (u.pathname.includes('/sign_in')) return false;
      if (u.pathname.includes('/ap/signin')) return false;
      if (u.pathname.includes('/ap/mfa')) return false;
      if (u.pathname.includes('/ap/cvf')) return false;
      if (u.pathname.includes('/ap-handler')) return false;
      // Must be on goodreads.com to count as logged in
      return u.hostname.includes('goodreads.com');
    }, { timeout: 300000 }); // 5 min timeout
  } catch (err) {
    // Browser was closed by user before login completed
    if (err.message.includes('Target page, context or browser has been closed')) {
      process.stderr.write('Browser closed before login completed. Please try again and complete login in the Playwright browser.\n');
      process.exit(1);
    }
    throw err;
  }

  // Save session state
  const state = await context.storageState();
  fs.mkdirSync(path.dirname(sessionPath), { recursive: true });
  fs.writeFileSync(sessionPath, JSON.stringify(state, null, 2));

  process.stderr.write('Login successful. Session saved.\n');
  console.log(JSON.stringify({ ok: true }));

  await browser.close();
}

function headlessLaunchOptions() {
  return {
    headless: false,
    args: ['--headless=new', '--disable-blink-features=AutomationControlled'],
  };
}

async function getCSRFToken(context) {
  const page = await context.newPage();
  await page.goto('https://www.goodreads.com', { waitUntil: 'load', timeout: 60000 });
  await page.waitForTimeout(2000);

  const url = page.url();
  if (url.includes('/user/sign_in') || url.includes('/ap/signin')) {
    await page.close();
    return null; // session expired
  }

  // Check for Cloudflare challenge
  const title = await page.title();
  if (title.includes('Cloudflare') || title.includes('Just a moment')) {
    process.stderr.write('Cloudflare challenge detected. Try again or re-login: kindle sync goodreads-login\n');
    await page.close();
    return null;
  }

  const token = await page.evaluate(() => {
    const meta = document.querySelector('meta[name="csrf-token"]');
    return meta ? meta.getAttribute('content') : null;
  }).catch(() => null);

  await page.close();
  return token;
}

async function push(args) {
  const { session: sessionPath, 'book-id': bookId, shelf, rating, percent } = args;

  if (!bookId) {
    process.stderr.write('Error: --book-id required\n');
    process.exit(1);
  }

  if (!fs.existsSync(sessionPath)) {
    process.stderr.write('Error: session file not found. Run: kindle sync goodreads-login\n');
    process.exit(2);
  }

  const state = JSON.parse(fs.readFileSync(sessionPath, 'utf-8'));
  const browser = await chromium.launch(headlessLaunchOptions());
  const context = await browser.newContext({
    storageState: state,
    userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
  });

  const csrfToken = await getCSRFToken(context);
  if (!csrfToken) {
    console.log(JSON.stringify({ ok: false, error: 'session_expired' }));
    await browser.close();
    process.exit(2);
  }

  const results = {};
  const headers = {
    'X-CSRF-Token': csrfToken,
    'X-Requested-With': 'XMLHttpRequest',
  };

  // 1. Update shelf
  if (shelf) {
    try {
      const resp = await context.request.post('https://www.goodreads.com/shelf/add_to_shelf', {
        form: { book_id: bookId, name: shelf },
        headers,
      });
      results.shelf = { ok: resp.ok(), status: resp.status() };
    } catch (err) {
      results.shelf = { ok: false, error: err.message };
    }
  }

  // 2. Update progress
  if (percent !== undefined && percent !== 'undefined') {
    try {
      const resp = await context.request.post('https://www.goodreads.com/user_status.json', {
        form: {
          'user_status[book_id]': bookId,
          'user_status[percent]': percent,
        },
        headers,
      });
      results.progress = { ok: resp.ok(), status: resp.status() };
    } catch (err) {
      results.progress = { ok: false, error: err.message };
    }
  }

  // 3. Update rating
  if (rating) {
    try {
      const ratingNum = parseInt(rating, 10);
      if (ratingNum >= 1 && ratingNum <= 5) {
        const resp = await context.request.post(
          `https://www.goodreads.com/book/rate/${bookId}`,
          {
            form: { rating: ratingNum.toString(), authenticity_token: csrfToken },
            headers,
          }
        );
        results.rating = { ok: resp.ok(), status: resp.status() };
      }
    } catch (err) {
      results.rating = { ok: false, error: err.message };
    }
  }

  console.log(JSON.stringify({ ok: true, results }));
  await browser.close();
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const cmd = args._cmd;
  const sessionPath = args.session;

  if (!cmd) {
    process.stderr.write('Usage: node goodreads.js <login|push> --session <path> [...]\n');
    process.exit(1);
  }

  if (!sessionPath) {
    process.stderr.write('Error: --session <path> required\n');
    process.exit(1);
  }

  try {
    switch (cmd) {
      case 'login':
        await login(sessionPath);
        break;
      case 'push':
        await push(args);
        break;
      default:
        process.stderr.write(`Unknown command: ${cmd}\n`);
        process.exit(1);
    }
  } catch (err) {
    process.stderr.write(`Error: ${err.message}\n`);
    process.exit(1);
  }
}

main();
