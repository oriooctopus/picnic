/**
 * Minimal fake of the slice of the Playwright `page` API worker.mjs
 * actually calls (locator/keyboard/goto/bringToFront/url), driven by a
 * small config object instead of a real browser. Selector matching is by
 * regex against the CSS/text selector string worker.mjs passes to
 * page.locator(...) — this mirrors how Playwright itself would resolve
 * those selectors, just against fake data instead of a real DOM, so the
 * same worker.mjs code path (date search -> tiles -> info panel -> "View
 * next photo" -> trash) runs unmodified in tests.
 *
 * Model: a search ("August 5, 2026") resolves to a fixed list of result
 * tiles (`searchResults[query]`, each `{ ariaLabel }` — real tiles and
 * decoy chips alike, exactly like the live grid) and a fixed, ordered
 * sequence of info-panel texts (`photoSequence[query]`) reached by opening
 * the first tile and then repeatedly clicking "View next photo". The fake
 * doesn't try to line up tiles[i] with photoSequence[i] — worker.mjs only
 * ever opens tiles[0] and then walks forward via "next", matching how the
 * real UI works (the panel is what advances, not re-clicking tiles).
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
    await this.page.onClick?.(this.selector);
  }
  async count() {
    return this.page.countFor(this.selector);
  }
  async all() {
    return this.page.allFor(this.selector);
  }
  async textContent() {
    return this.page.textFor(this.selector);
  }
  async getAttribute(name) {
    return this.page.attrFor(this.selector, name);
  }
  async waitFor() {
    if (this.page.shouldTimeout(this.selector)) {
      throw new Error(`fakePage: configured timeout for selector ${this.selector}`);
    }
  }
  async scrollIntoViewIfNeeded() {
    this.page.log.push(`scroll:${this.selector}`);
  }
  async isVisible() {
    return this.page.visibleFor(this.selector);
  }
}

/** One result-grid tile, as returned by `.all()` on the result-link selector. */
class FakeTileLink {
  async isVisible() {
    return this.hidden !== true;
  }
  constructor(page, ariaLabel, index) {
    this.page = page;
    this.ariaLabel = ariaLabel;
    this.index = index;
  }
  async getAttribute(name) {
    return name === 'aria-label' ? this.ariaLabel : null;
  }
  async scrollIntoViewIfNeeded() {
    this.page.log.push(`scroll:tile:${this.index}`);
  }
  async click() {
    this.page.log.push(`tile-click:${this.index}`);
    this.page.openedTileIndex = this.index;
  }
}

/**
 * @param config {{
 *   bodyText?: string,                          // what assertNoFriction sees (default: benign)
 *   searchResults?: Record<string, Array<{ariaLabel: string}|string>>, // query -> tiles (real + decoy)
 *   photoSequence?: Record<string, string[]>,    // query -> ordered raw info-panel texts, walked via "View next photo"
 *   infoButtonFound?: boolean,                   // whether the "Open info" button is present
 * }}
 */
export function createFakePage(config = {}) {
  const page = {
    config: {
      bodyText: 'Your photos, organized. Search your library.',
      searchResults: {},
      photoSequence: {},
      infoButtonFound: true,
      ...config,
    },
    log: [],
    searchLog: [], // every date-search query actually submitted, in order
    activeQuery: null,
    photoIndex: 0,
    openedTileIndex: null,
    keyboard: {
      async press(key) {
        page.log.push(`key:${key}`);
        if (key === 'Escape') page.escapePresses = (page.escapePresses ?? 0) + 1;
        if (key === 'ArrowRight') {
          // Real UI: ArrowRight is what actually advances the photo (the
          // "View next photo" button is present but not reliably clickable).
          const seq = page.config.photoSequence[page.activeQuery] ?? [];
          if (page.photoIndex + 1 < seq.length) page.photoIndex += 1;
        }
        if (key === 'Enter') {
          page.activeQuery = page.pendingTypedText ?? null;
          page.photoIndex = 0;
          page.openedTileIndex = null;
          if (page.activeQuery != null) page.searchLog.push(page.activeQuery);
        }
      },
      async type(text) {
        page.log.push(`type:${text}`);
        page.pendingTypedText = text;
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
    async bringToFront() {
      page.log.push('bringToFront');
    },
    async evaluate() {
      // Mirrors readPanelText(): returns the current photo's info-panel text.
      page.log.push('evaluate:panelText');
      const seq = page.config.photoSequence[page.activeQuery] ?? [];
      return seq[page.photoIndex] ?? '';
    },
    async goBack() {
      page.goBackCalls = (page.goBackCalls ?? 0) + 1;
      page.log.push('goBack');
    },
    url() {
      return page._url ?? 'https://photos.google.com';
    },
    countFor(selector) {
      if (/aria-label="Open info"/i.test(selector)) {
        return page.config.infoButtonFound ? 1 : 0;
      }
      if (/aria-label="View next photo"/i.test(selector)) {
        const seq = page.config.photoSequence[page.activeQuery] ?? [];
        return page.photoIndex + 1 < seq.length ? 1 : 0;
      }
      if (/aria-label="Move to trash"/i.test(selector)) {
        return 1;
      }
      // The panel-open signal: present once the info panel has been opened.
      if (/aria-label="Close info"/i.test(selector)) {
        return page.config.infoButtonFound ? 1 : 0;
      }
      return 0;
    },
    allFor(selector) {
      if (selector.includes('./search/')) {
        const results = page.config.searchResults[page.activeQuery] ?? [];
        return results.map((tile, i) => new FakeTileLink(page, typeof tile === 'string' ? tile : tile.ariaLabel, i));
      }
      return [];
    },
    attrFor() {
      return null; // tiles resolve their own aria-label via FakeTileLink
    },
    textFor(selector) {
      if (selector === 'body') return page.config.bodyText;
      if (/aria-label="Close info"/i.test(selector)) {
        const seq = page.config.photoSequence[page.activeQuery] ?? [];
        return seq[page.photoIndex] ?? '';
      }
      if (/aria-label="Info"|role="complementary"/i.test(selector)) {
        const seq = page.config.photoSequence[page.activeQuery] ?? [];
        return seq[page.photoIndex] ?? '';
      }
      return '';
    },
    shouldTimeout() {
      return false;
    },
    /**
     * Visibility, used by closeAnyOpenPhoto() and the info-panel fallback.
     * `searchBoxHiddenUntilEscape` models the real behaviour the live run hit:
     * after walking a date the photo view covers the search box until Escape.
     */
    visibleFor(selector) {
      if (/aria-label\*?="Search|placeholder\*?="Search/i.test(selector)) {
        if (!page.config.searchBoxHiddenUntilEscape) return true;
        return page.escapePresses > 0;
      }
      if (/aria-label="Open info"/i.test(selector)) {
        return Boolean(page.config.infoButtonVisible);
      }
      return false;
    },
    async onClick(selector) {
      if (/aria-label="View next photo"/i.test(selector)) {
        page.photoIndex += 1;
      }
    },
  };
  return page;
}
