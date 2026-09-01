/**
 * Minimal fake of the slice of the Playwright `page` API worker.mjs
 * actually calls (locator/keyboard/goto/waitForLoadState/url), driven by a
 * small config object instead of a real browser. Selector matching is by
 * regex against the CSS/text selector string worker.mjs passes to
 * page.locator(...) / infoPanel.locator(...) — this mirrors how Playwright
 * itself would resolve those selectors, just against fake data instead of
 * a real DOM, so the same worker.mjs code path (search box -> tiles ->
 * info panel -> back/trash buttons) runs unmodified in tests.
 */

class FakeLocator {
  constructor(page, selector) {
    this.page = page;
    this.selector = selector;
  }
  locator(selector) {
    return new FakeLocator(this.page, selector);
  }
  first() {
    return this;
  }
  async click() {
    this.page.log.push(`click:${this.selector}`);
    this.page.onClick?.(this.selector);
  }
  async fill(value) {
    this.page.log.push(`fill:${this.selector}:${value}`);
  }
  async count() {
    return this.page.countFor(this.selector);
  }
  async all() {
    return this.page.allFor(this.selector);
  }
  async textContent() {
    const value = this.page.textFor(this.selector);
    if (value === undefined) throw new Error(`fakePage: no text configured for selector ${this.selector}`);
    return value;
  }
  async waitFor() {
    if (this.page.shouldTimeout(this.selector)) {
      throw new Error(`fakePage: configured timeout for selector ${this.selector}`);
    }
  }
}

class FakeTile {
  constructor(page, index) {
    this.page = page;
    this.index = index;
  }
  async click() {
    this.page.currentTileIndex = this.index;
    this.page.log.push(`tile-click:${this.index}`);
  }
}

/**
 * @param config {{
 *   bodyText?: string,               // what assertNoFriction sees (default: benign)
 *   tiles?: number,                  // how many search-result tiles searchCandidates finds
 *   candidates?: Array<{filenameText, dateText, dimsText}>, // per-tile info panel contents, indexed by tile order
 *   backButtonFound?: boolean,       // whether returnToResults finds an in-app close/back control
 * }}
 */
export function createFakePage(config = {}) {
  const page = {
    config: {
      bodyText: 'Your photos, organized. Search your library.',
      tiles: 0,
      candidates: [],
      backButtonFound: true,
      ...config,
    },
    log: [],
    currentTileIndex: 0,
    goBackCalls: 0,
    keyboard: {
      async press(key) {
        page.log.push(`key:${key}`);
      },
      async type(text) {
        page.log.push(`type:${text}`);
      },
    },
    locator(selector) {
      return new FakeLocator(page, selector);
    },
    async goto(url) {
      page.log.push(`goto:${url}`);
      page._url = url;
    },
    async waitForLoadState() {
      page.log.push('waitForLoadState');
    },
    async goBack() {
      page.goBackCalls += 1;
      page.log.push('goBack');
    },
    url() {
      return page._url ?? 'https://photos.google.com';
    },
    countFor(selector) {
      if (/aria-label="Back"|aria-label="Close"/i.test(selector)) {
        return page.config.backButtonFound ? 1 : 0;
      }
      return 0;
    },
    allFor(selector) {
      if (/data-latest-bg/.test(selector)) {
        return Array.from({ length: page.config.tiles }, (_, i) => new FakeTile(page, i));
      }
      return [];
    },
    textFor(selector) {
      if (selector === 'body') return page.config.bodyText;
      const candidate = page.config.candidates[page.currentTileIndex] ?? {};
      // Selector strings here are the literal ones worker.mjs passes to
      // page/infoPanel.locator(...) — matched by the distinctive substring
      // each one contains (filename's char-class, the date aria-label, the
      // dims digit pattern), same as Playwright would resolve them against
      // a real DOM, just against this config instead.
      if (selector.includes('[A-Za-z0-9]{2,4}')) return candidate.filenameText ?? '';
      if (/aria-label\*="date"/i.test(selector)) return candidate.dateText ?? '';
      if (selector.includes('\\d+')) return candidate.dimsText ?? '';
      return '';
    },
    shouldTimeout() {
      return false;
    },
  };
  return page;
}
