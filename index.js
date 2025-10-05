#!/usr/bin/env node
/**
 * Simple HN /newest scraper (Playwright + Chromium)
 * Flags:
 *   --count=N     How many posts (default 100)
 *   --head        Show the browser (default headless). Also accepts --headed.
 *   --json        Output JSON instead of a list
 *   --max-pages=N Limit pages to visit (default 15)
 */
const { chromium } = require('playwright');

const BASE = 'https://news.ycombinator.com';
const START = `${BASE}/newest`;
const MAX_PAGES_DEFAULT = 15;
const WAIT_SELECTOR = 'tr.athing';
const WAIT_TIMEOUT_MS = 20_000; // more forgiving
const SOFT_RELOAD_DELAY_MS = 500;

function parseArgs(argv) {
    const args = { count: 100, head: false, json: false, maxPages: MAX_PAGES_DEFAULT };
    for (const a of argv.slice(2)) {
        if (a.startsWith('--count=')) args.count = Math.max(1, parseInt(a.split('=')[1], 10) || 100);
        else if (a === '--head' || a === '--headed') args.head = true;
        else if (a === '--json') args.json = true;
        else if (a.startsWith('--max-pages=')) args.maxPages = Math.max(1, parseInt(a.split('=')[1], 10) || MAX_PAGES_DEFAULT);
    }
    return args;
}

function fmtItem(i, it) {
    return `${String(i).padStart(3, ' ')}. ${it.iso || '(no-iso)'}  ${it.id || '(no-id)'}  -  ${it.title || ''}`;
}

async function scrapePage(page) {
    // Prefer 'attached' so we don’t require visibility; some machines render slowly.
    try {
        await page.waitForSelector(WAIT_SELECTOR, { timeout: WAIT_TIMEOUT_MS, state: 'attached' });
    } catch { /* fall through and try to parse anyway */ }

    return await page.evaluate(() => {
        const out = [];
        const rows = Array.from(document.querySelectorAll('tr.athing'));
        for (const tr of rows) {
            const id = tr.getAttribute('id') || '';
            const titleEl = tr.querySelector('span.titleline a');
            const title = titleEl ? titleEl.textContent.trim() : '';
            const ageEl = tr.nextElementSibling?.querySelector('span.age');
            const isoAttr = ageEl?.getAttribute('title') || '';
            const iso = isoAttr || (ageEl?.textContent?.trim() || '');
            if (id && title && iso) out.push({ id, title, iso });
        }
        const moreEl = document.querySelector('a.morelink');
        const moreHref = moreEl ? moreEl.getAttribute('href') : null;
        return { items: out, moreHref };
    });
}

(async () => {
    const args = parseArgs(process.argv);
    const want = args.count;
    const maxPages = args.maxPages;

    const browser = await chromium.launch({ headless: !args.head });
    const page = await browser.newPage();
    let url = START;

    const seen = new Set();
    const collected = [];
    let pages = 0;

    try {
        while (collected.length < want && pages < maxPages) {
            await page.goto(url, { waitUntil: 'domcontentloaded' });

            // First scrape
            let { items, moreHref } = await scrapePage(page);

            // Soft reload once if nothing found (slow paint or transient hiccup)
            if (items.length === 0) {
                await page.waitForTimeout(SOFT_RELOAD_DELAY_MS);
                await page.reload({ waitUntil: 'domcontentloaded' });
                ({ items, moreHref } = await scrapePage(page));
            }

            for (const it of items) {
                if (!seen.has(it.id)) {
                    seen.add(it.id);
                    collected.push(it);
                    if (collected.length >= want) break;
                }
            }
            pages++;

            if (collected.length >= want) break;
            if (!moreHref) break; // no more pages

            url = moreHref.startsWith('http') ? moreHref : `${BASE}/${moreHref.replace(/^\//, '')}`;
        }

        const ok = collected.length >= want;

        if (args.json) {
            console.log(JSON.stringify({
                ok,
                summary: { requested: want, collected: collected.length, pages, maxPages },
                items: collected.slice(0, want),
            }, null, 2));
        } else {
            console.log('Timestamps (newest → oldest, raw ISO from HN):');
            collected.slice(0, want).forEach((it, i) => console.log(' ', fmtItem(i + 1, it)));
            console.log(`Collected: ${collected.length} | Pages: ${pages} | Dups: ${seen.size - collected.length}`);
            console.log(ok ? 'true' : `Only ${collected.length}/${want}. Consider increasing --max-pages.`);
        }

        process.exitCode = ok ? 0 : 1;
    } catch (err) {
        if (args.json) {
            console.log(JSON.stringify({
                ok: false,
                summary: { requested: want, collected: collected.length, pages, maxPages },
                error: err.message || String(err),
                items: collected,
            }, null, 2));
        } else {
            console.error(err);
            console.log('false');
        }
        process.exitCode = 1;
    } finally {
        await browser.close();
    }
})().catch(err => {
    console.error('Unhandled error:', err);
    process.exit(1);
});
