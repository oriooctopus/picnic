/**
 * Minimal fake of the slice of the Playwright `page` API worker.mjs actually
 * calls (locator/keyboard/mouse/goto/bringToFront/evaluate/url/isClosed),
 * driven by a small config object instead of a real browser. Selector
 * matching is by regex against the CSS/text selector string worker.mjs
 * passes to page.locator(...) — this mirrors how Playwright itself would
 * resolve those selectors, just against fake data instead of a real DOM, so
 * the same worker.mjs code path (date search -> tiles -> open each tile ->
 * info panel -> trash) runs unmodified in tests.
 *
 * Model: a search ("August 5, 2026") resolves to a fixed list of result
 * tiles (`searchResults[query]`, each `{ariaLabel}` — real tiles and decoy
 * chips alike, exactly like the live grid) plus optional additional
 * batches only revealed by scrolling (`scrollReveals[query]`, an array of
 * batches). Each tile's info-panel text is looked up by its OWN aria-label
 * (`panelTextByLabel[query][ariaLabel]`), not by array position — worker.mjs
 * now opens every tile directly rather than stepping through an ordered
 * sequence, and the grid can re-render tiles in a different order between
 * collections, so the fake must resolve content the same way the real DOM
 * would: by which tile was actually clicked.
 *
 * The info panel is modelled as STICKY (`page.infoPanelOpen`), matching the
 * real, live-verified behaviour worker.mjs relies on: once opened it stays
 * open across tiles and across searches, and pressing "i" while open closes
 * it.
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
    this.page.guard();
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
  constructor(page, ariaLabel, index) {
    this.page = page;
    this.ariaLabel = ariaLabel;
    this.index = index;
  }
  async isVisible() {
    return this.hidden !== true;
  }
  async getAttribute(name) {
    return name === 'aria-label' ? this.ariaLabel : null;
  }
  async scrollIntoViewIfNeeded() {
    this.page.log.push(`scroll:tile:${this.ariaLabel}`);
  }
  async click() {
    this.page.guard();
    this.page.log.push(`tile-click:${this.ariaLabel}`);
    this.page.openedAriaLabel = this.ariaLabel;
    this.page.openedTileCount += 1;
    // Simulates the browser tab disappearing right after this tile finished
    // opening -- the NEXT guarded interaction (info panel, trash, escape...)
    // is what throws, same shape as the live failure this models.
    if (this.page.config.closeAfterTiles != null && this.page.openedTileCount >= this.page.config.closeAfterTiles) {
      this.page._closed = true;
    }
  }
}

function performTrash(page) {
  if (page.openedAriaLabel != null) page.trashedLabels.add(page.openedAriaLabel);
  page.openedAriaLabel = null;
}

/**
 * @param config {{
 *   bodyText?: string,
 *   searchResults?: Record<string, Array<{ariaLabel: string}|string>>, // query -> tiles visible without scrolling
 *   scrollReveals?: Record<string, Array<Array<{ariaLabel: string}|string>>>, // query -> batches revealed by successive scrolls
 *   panelTextByLabel?: Record<string, Record<string, string>>, // query -> ariaLabel -> info-panel text for that tile
 *   reorderOnRecollect?: Record<string, boolean>, // query -> flip tile order every other .all() call, simulating a re-rendered grid
 *   infoButtonFound?: boolean,       // whether "Open info"/"Close info" controls resolve at all
 *   infoButtonVisible?: boolean,     // whether the "Open info" fallback button is visible
 *   trashButtonVisible?: boolean,    // default true
 *   swallowTrashShortcut?: boolean,  // "#" keyboard fallback does nothing (models an unconfirmed trash)
 *   searchBoxHiddenUntilEscape?: boolean,
 *   closeAfterTiles?: number,        // browser tab "closes" right after this many tiles have been opened, across the whole run
 * }}
 */
export function createFakePage(config = {}) {
  const page = {
    config: {
      bodyText: 'Your photos, organized. Search your library.',
      searchResults: {},
      scrollReveals: {},
      panelTextByLabel: {},
      infoButtonFound: true,
      ...config,
    },
    log: [],
    searchLog: [], // every date-search query actually submitted, in order
    activeQuery: null,
    openedAriaLabel: null,
    openedTileCount: 0,
    infoPanelOpen: false,
    trashedLabels: new Set(),
    revealedCount: 0,
    recollectCount: {},
    escapePresses: 0,
    _closed: false,
    isClosed() {
      return page._closed === true;
    },
    guard() {
      if (page._closed) {
        throw new Error('Target page, context or browser has been closed');
      }
    },
    keyboard: {
      async press(key) {
        page.guard();
        page.log.push(`key:${key}`);
        if (key === 'Escape') {
          page.escapePresses += 1;
          page.openedAriaLabel = null;
        }
        if (key === 'i') page.infoPanelOpen = !page.infoPanelOpen;
        if (key === '#' && !page.config.swallowTrashShortcut) performTrash(page);
        if (key === 'Enter') {
          page.activeQuery = page.pendingTypedText ?? null;
          page.openedAriaLabel = null;
          page.revealedCount = 0;
          if (page.activeQuery != null) page.searchLog.push(page.activeQuery);
        }
      },
      async type(text) {
        page.guard();
        page.log.push(`type:${text}`);
        page.pendingTypedText = text;
      },
    },
    mouse: {
      async wheel() {
        page.guard();
        page.log.push('wheel');
        const reveals = page.config.scrollReveals[page.activeQuery] ?? [];
        if (page.revealedCount < reveals.length) page.revealedCount += 1;
      },
    },
    locator(selector) {
      return new FakeLocator(page, selector);
    },
    async goto(url) {
      page.log.push(`goto:${url}`);
      page._url = url;
    },
    async bringToFront() {
      page.guard();
      page.log.push('bringToFront');
    },
    async evaluate() {
      // Mirrors readPanelText(): returns the current tile's info-panel text,
      // but only once the (sticky) info panel is actually open.
      page.log.push('evaluate:panelText');
      if (!page.infoPanelOpen || page.openedAriaLabel == null) return '';
      const byLabel = page.config.panelTextByLabel[page.activeQuery] ?? {};
      return byLabel[page.openedAriaLabel] ?? '';
    },
    url() {
      return page._url ?? 'https://photos.google.com';
    },
    countFor(selector) {
      if (/aria-label="Open info"/i.test(selector)) {
        return page.config.infoButtonFound ? 1 : 0;
      }
      if (/aria-label="Move to trash"/i.test(selector)) {
        return 1;
      }
      if (/has-text\("Move to trash"\)|has-text\("Delete"\)/i.test(selector)) {
        return 0; // no confirmation dialog in the fake UI
      }
      return 0;
    },
    allFor(selector) {
      if (!selector.includes('./search/')) return [];
      const query = page.activeQuery;
      page.recollectCount[query] = (page.recollectCount[query] ?? 0) + 1;

      const base = page.config.searchResults[query] ?? [];
      const reveals = page.config.scrollReveals[query] ?? [];
      const revealedBatches = reveals.slice(0, page.revealedCount).flat();
      let all = [...base, ...revealedBatches];

      all = all.filter((tile) => {
        const label = typeof tile === 'string' ? tile : tile.ariaLabel;
        return !page.trashedLabels.has(label);
      });

      // Simulates the grid re-rendering tiles in a different order between
      // collections -- worker.mjs must dedupe/track by aria-label, not index.
      if (page.config.reorderOnRecollect?.[query] && page.recollectCount[query] % 2 === 0) {
        all = [...all].reverse();
      }

      return all.map((tile, i) => new FakeTileLink(page, typeof tile === 'string' ? tile : tile.ariaLabel, i));
    },
    attrFor() {
      return null; // tiles resolve their own aria-label via FakeTileLink
    },
    textFor(selector) {
      if (selector === 'body') return page.config.bodyText;
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
      if (/aria-label="Move to trash"/i.test(selector)) {
        return page.config.trashButtonVisible !== false;
      }
      return false;
    },
    async onClick(selector) {
      if (/aria-label="Open info"/i.test(selector)) page.infoPanelOpen = true;
      if (/aria-label="Move to trash"/i.test(selector)) performTrash(page);
    },
  };
  return page;
}
