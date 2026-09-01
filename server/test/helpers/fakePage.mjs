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
 *
 * The photo view's open/closed state is modelled by `page.openedAriaLabel`
 * (non-null == a photo is open): set when a tile is clicked (openTileInFake),
 * cleared by Escape and by a successful trash. Two selectors are gated on it
 * (see photoOpen() below), matching the live DOM behaviour worker.mjs's
 * closeAnyOpenPhoto fix depends on (2026-09-01): TRASH_SELECTOR is a
 * photo-view-only control (visible ONLY while a photo is open, the sole
 * signal closeAnyOpenPhoto now uses), and a result tile's IDENTITY-scoped
 * locator (tileLocatorFor's `[aria-label="..."]:visible`, what openTile()
 * actually clicks) resolves to nothing while a photo covers the grid. The
 * SEARCH BOX is deliberately NOT gated this way by default -- matching the
 * live trap the fix targets, it stays visible whether or not a photo is
 * open, which is exactly why the OLD closeAnyOpenPhoto (search-box-only)
 * never actually closed anything.
 */


/**
 * The worker addresses tiles by identity now:
 *   a[href^="./search/"][aria-label="Photo - Portrait - Aug 5, 2026, 6:54:07 PM"]
 * Pull the label back out so the fake grid can resolve it the same way the
 * real DOM would, rather than by array position.
 */
function ariaLabelFromSelector(selector) {
  const m = /\[aria-label="((?:[^"\\]|\\.)*)"\]/.exec(selector || '');
  return m ? m[1].replace(/\\(.)/g, '$1') : null;
}

/**
 * True when `selector` is an identity-scoped result-link selector built by
 * worker.mjs's tileLocatorFor (`a[href^="./search/"][aria-label="..."]`),
 * as opposed to the plain `a[href^="./search/"]` selector .all() resolves
 * against. Both contain the `./search/` substring, so this also requires an
 * aria-label to be present, to avoid misrouting the plain selector's
 * count/visible checks into the tile-lookup path.
 */
function isTileIdentitySelector(selector) {
  return typeof selector === 'string' && selector.includes('./search/') && ariaLabelFromSelector(selector) != null;
}

/**
 * All tiles currently "in the grid" for the active query: the base
 * searchResults plus whatever scroll has revealed so far, minus anything
 * already trashed. Shared by the identity-selector count/visible/click
 * checks below and by FakeTileLink so both addressing paths (by position via
 * .all(), by identity via tileLocatorFor) see the same grid.
 */
function tilesInGrid(page) {
  const query = page.activeQuery;
  const base = page.config.searchResults[query] ?? [];
  const reveals = page.config.scrollReveals[query] ?? [];
  const revealedBatches = reveals.slice(0, page.revealedCount).flat();
  return [...base, ...revealedBatches].filter((tile) => {
    const label = typeof tile === 'string' ? tile : tile.ariaLabel;
    return !page.trashedLabels.has(label);
  });
}

/**
 * VIRTUALIZED MODEL (config.windowSize): unlike the plain `tilesInGrid`
 * above -- which keeps every revealed tile "mounted" forever, matching the
 * existing (additive-only) `scrollReveals` fixtures -- a real Google Photos
 * grid only ever keeps a WINDOW of tiles mounted at a time. Scrolling
 * further mounts new tiles and can unmount ones that scrolled off the top,
 * so the on-screen tile COUNT can stay constant across a scroll even though
 * the actual SET of on-screen labels moved on entirely. This is exactly the
 * live bug worker.mjs had: it judged "did this scroll find anything new" by
 * comparing counts, which is blind to a windowed swap.
 *
 * BIDIRECTIONAL (2026-09-01): the window's start position (`page.windowStart`,
 * an index into `tilesInGrid`'s full list) can move BOTH ways now, not just
 * grow with `revealedCount`. This is what lets a test express worker.mjs's
 * upward-recovery path (scrollResultsUp -> a negative page.mouse.wheel delta,
 * see the `mouse.wheel` handler below): a tile the walk already knows about
 * (tracked in `seen`) but which scrolled out of the mounted window as later
 * content loaded is reachable again once the window scrolls back over it,
 * exactly like a real scrollable grid -- distinct from a tile that hasn't
 * loaded at all, which no amount of scrolling back up can produce. Downward
 * scrolling still snaps the window to the tail on every reveal (unchanged
 * from the original tail-slice behaviour), so every pre-existing windowSize
 * fixture -- which never scrolls up -- keeps working exactly as before.
 * Omitting `windowSize` entirely (the default) => unchanged, unwindowed
 * behaviour, so every fixture without it is untouched.
 */
function windowedTiles(page) {
  const windowSize = page.config.windowSize;
  const all = tilesInGrid(page);
  if (!windowSize) return all;
  // Clamp defensively: `all` can shrink (a trash removes a tile from
  // tilesInGrid) even though windowStart was set against a longer list.
  const maxStart = Math.max(0, all.length - windowSize);
  const start = Math.min(page.windowStart, maxStart);
  return all.slice(start, start + windowSize);
}

function findTileByLabel(page, label) {
  return windowedTiles(page).find((t) => (typeof t === 'string' ? t : t.ariaLabel) === label) ?? null;
}

/**
 * True when `label` names a tile worker.mjs's collectResultTiles() can see
 * (it's on-screen, real, and in the positional `.all()` walk) but which the
 * identity-scoped selector (tileLocatorFor, what openTile() actually clicks)
 * can NEVER resolve -- models a tile the live grid genuinely refuses to
 * mount, distinct from one merely scrolled out of the current window.
 * `config.unopenableLabels` is an array or Set of such labels.
 */
function isUnopenable(page, label) {
  const set = page.config.unopenableLabels;
  if (!set) return false;
  return set instanceof Set ? set.has(label) : Array.isArray(set) && set.includes(label);
}

/**
 * True while a photo is open in the fake -- worker.mjs has clicked a tile
 * and not yet Escaped away from it (or trashed it) -- mirrors the real DOM
 * signal worker.mjs's closeAnyOpenPhoto fix relies on: TRASH_SELECTOR is a
 * photo-view-only control, and the grid's own result tiles are NOT :visible
 * while a photo covers them (verified live 2026-09-01 -- see worker.mjs's
 * TRASH_SELECTOR / closeAnyOpenPhoto comments). `page.openedAriaLabel` is
 * already exactly this signal: set by openTileInFake when a tile is clicked,
 * cleared by Escape and by a successful trash (see keyboard.press/performTrash
 * below) and by starting a fresh search.
 */
function photoOpen(page) {
  return page.openedAriaLabel != null;
}

/**
 * Shared "a tile was opened" side effect: records the click in the log,
 * points the (sticky) info panel at this tile, and simulates the browser
 * tab closing after `closeAfterTiles` opens. Used by BOTH addressing paths --
 * FakeTileLink.click() (tiles from .all(), positional) and FakeLocator.click()
 * for an identity-scoped selector (worker.mjs's tileLocatorFor) -- so a real
 * click has the same effect regardless of which selector shape found the
 * tile, same as it would on the real DOM (it's the same element either way).
 */
function openTileInFake(page, ariaLabel) {
  page.log.push(`tile-click:${ariaLabel}`);
  page.openedAriaLabel = ariaLabel;
  page.openedTileCount += 1;
  // Simulates the browser tab disappearing right after this tile finished
  // opening -- the NEXT guarded interaction (info panel, trash, escape...)
  // is what throws, same shape as the live failure this models.
  if (page.config.closeAfterTiles != null && page.openedTileCount >= page.config.closeAfterTiles) {
    page._closed = true;
  }
}

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
    // worker.mjs's openTile() no longer clicks a positional locator from
    // .all() -- it builds a fresh identity-scoped locator (tileLocatorFor)
    // and clicks THAT. Without this branch the click resolves but never
    // updates page.openedAriaLabel, so readPanelText() (keyed off
    // openedAriaLabel) stays empty forever and openInfoPanelOnce() times out
    // no matter what the panel fixture says -- this was the actual gap: the
    // earlier version wired up count/visible for the new selector shape but
    // not click, which is the one that matters for reaching the panel text.
    if (isTileIdentitySelector(this.selector)) {
      const label = ariaLabelFromSelector(this.selector);
      if (!isUnopenable(this.page, label) && findTileByLabel(this.page, label)) {
        openTileInFake(this.page, label);
        return;
      }
    }
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
    // Models the actual live bug (see worker.mjs's openTile comment): a
    // POSITIONAL locator held from an earlier .all() call re-resolves the
    // DOM on every call, so a re-render between "we decided to open this
    // tile" and "we clicked it" can silently swap in a different element at
    // the same spot -- observed live as a click meant for a photo landing on
    // the "Back to search" link instead. `staleTileClickTargets` opts a
    // fixture into that race (default: none, so every pre-existing test's
    // FakeTileLink still opens exactly the tile it was built for). Only this
    // POSITIONAL path can drift -- the identity-scoped locator worker.mjs's
    // openTile actually uses now (tileLocatorFor, see FakeLocator.click()
    // above) always resolves fresh by aria-label and is immune, which is
    // the whole point of the fix and what the positional-drift regression
    // test below proves by mutation.
    const driftTarget = this.page.config.staleTileClickTargets?.[this.ariaLabel];
    openTileInFake(this.page, driftTarget ?? this.ariaLabel);
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
 *   staleTileClickTargets?: Record<string, string>, // ariaLabel -> ariaLabel a POSITIONAL tile.locator.click() actually lands on instead (models live re-render drift; the identity-scoped locator is immune -- see FakeTileLink.click())
 *   windowSize?: number,             // only N tiles are "mounted" at once -- models a VIRTUALIZED grid where scrolling swaps the visible window rather than only ever growing it. A positive-dy mouse.wheel (scrollResults) follows the tail forward and loads more; a negative-dy wheel (scrollResultsUp) moves the window back over already-loaded content without loading anything new (see windowedTiles())
 *   unopenableLabels?: string[]|Set<string>, // labels that collectResultTiles() can see (on-screen, real) but the identity-scoped selector openTile() clicks can NEVER resolve -- models a tile the grid refuses to mount, for the "unreachable tile, retried then recorded" behaviour
 *   swallowInfoPressesCount?: number, // first N "i" keypresses across the whole run are silently lost (models the keystroke landing mid-transition, before the photo view existed)
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
    windowStart: 0, // index into tilesInGrid(page) where the mounted window (windowedTiles) currently begins -- see mouse.wheel below
    recollectCount: {},
    escapePresses: 0,
    infoPressesSwallowed: 0, // count of "i" presses dropped so far, capped by config.swallowInfoPressesCount
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
        if (key === 'i') {
          // Models the live-observed lost-keystroke bug: with the mimicry
          // delays removed, "i" could be pressed while the photo view was
          // still opening and simply go nowhere. A fixture opts a fixed
          // number of LEADING presses into being swallowed this way; every
          // press after that toggles normally, proving openInfoPanelOnce's
          // re-press (every 8th poll) is what actually opens the panel.
          const swallowLimit = page.config.swallowInfoPressesCount ?? 0;
          if (page.infoPressesSwallowed < swallowLimit) {
            page.infoPressesSwallowed += 1;
          } else {
            page.infoPanelOpen = !page.infoPanelOpen;
          }
        }
        if (key === '#' && !page.config.swallowTrashShortcut) performTrash(page);
        if (key === 'Enter') {
          page.activeQuery = page.pendingTypedText ?? null;
          page.openedAriaLabel = null;
          page.revealedCount = 0;
          page.windowStart = 0; // fresh grid for the new search -- mounted window resets too
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
      // worker.mjs's scrollResultsUp() passes a NEGATIVE dy (Google Photos'
      // own "scroll up" gesture) -- everything else in the worker still
      // calls scrollResults() with a positive dy, so a missing/positive dy
      // means "down", matching every pre-existing call site and fixture.
      async wheel(dx, dy) {
        page.guard();
        const scrollingUp = typeof dy === 'number' && dy < 0;
        // Keep the plain 'wheel' entry every pre-existing test asserts on
        // (via page.log.includes('wheel')) AND add a directional one so a
        // new test can tell a recovery up-scroll apart from an ordinary
        // down-scroll.
        page.log.push('wheel');
        page.log.push(scrollingUp ? 'wheel:up' : 'wheel:down');
        if (scrollingUp) {
          // Move the mounted window back toward the top of whatever has
          // already loaded. Deliberately does NOT touch revealedCount --
          // scrolling up over already-loaded content must never trigger
          // loading MORE, or an up-scroll would be indistinguishable from a
          // down-scroll and no test could tell them apart.
          if (page.config.windowSize) {
            page.windowStart = Math.max(0, page.windowStart - page.config.windowSize);
          }
          return;
        }
        const reveals = page.config.scrollReveals[page.activeQuery] ?? [];
        if (page.revealedCount < reveals.length) page.revealedCount += 1;
        // A downward scroll also advances the mounted window to keep
        // following the tail -- mirrors the live grid mounting newly-
        // scrolled-into-view tiles while unmounting ones that scrolled off
        // the top (see windowedTiles' header comment). Snapping straight to
        // the tail, rather than advancing by one windowSize step, matches
        // the tail-slice behaviour every pre-existing windowSize fixture
        // (none of which ever scroll up) already relies on.
        if (page.config.windowSize) {
          page.windowStart = Math.max(0, tilesInGrid(page).length - page.config.windowSize);
        }
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
      if (isTileIdentitySelector(selector)) {
        // A tile is only reachable via its identity-scoped `:visible`
        // selector while the GRID is actually showing. While a photo is
        // open the grid sits behind the photo view and this selector counts
        // 0 -- this is the exact live mechanism openTile()'s `count()===0`
        // check depends on to notice a tile it tried to open is gone (see
        // StaleTileError), and it's what proves closeAnyOpenPhoto's fix:
        // under the OLD (search-box-only) condition, a photo left open by a
        // skipped Escape makes the NEXT tile's identity selector count 0 too
        // -- "tile gone from the grid", the exact live failure this models.
        if (photoOpen(page)) return 0;
        // Must check the SAME (possibly windowed) grid that .all() sees, not
        // just the base searchResults -- otherwise a tile that only exists
        // after a scroll reveal (see "scrolling reveals more tiles" in
        // worker.test.mjs) would read as a StaleTileError even though it's
        // genuinely there. `unopenableLabels` models a tile that's on-screen
        // (findTileByLabel would find it) but that the identity-scoped
        // selector can never resolve -- see the "unreachable tile" test.
        const label = ariaLabelFromSelector(selector);
        if (isUnopenable(page, label)) return 0;
        return findTileByLabel(page, label) ? 1 : 0;
      }
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

      let all = windowedTiles(page);

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
      if (isTileIdentitySelector(selector)) {
        // Same "grid is behind the photo view" gating as countFor's identity
        // branch above -- openTile() also calls isVisible() after count(),
        // and both must agree on the tile being unreachable while a photo
        // covers the grid.
        if (photoOpen(page)) return false;
        const label = ariaLabelFromSelector(selector);
        if (isUnopenable(page, label)) return false;
        const hit = findTileByLabel(page, label);
        return hit ? (typeof hit === 'string' ? true : hit.hidden !== true) : false;
      }
      if (/aria-label\*?="Search|placeholder\*?="Search/i.test(selector)) {
        // THE LIVE TRAP (2026-09-01): the search box lives in the header and
        // stays visible WHILE A PHOTO IS OPEN too -- default here (config
        // omitted, as every pre-existing fixture does) is unconditionally
        // visible regardless of photo state, exactly reproducing the bug
        // that made the OLD closeAnyOpenPhoto return without ever pressing
        // Escape. `searchBoxHiddenUntilEscape` remains available for a
        // fixture that wants the OLDER (already-fixed-elsewhere) "hidden
        // until Escape" shape instead.
        if (!page.config.searchBoxHiddenUntilEscape) return true;
        return page.escapePresses > 0;
      }
      if (/aria-label="Open info"/i.test(selector)) {
        return Boolean(page.config.infoButtonVisible);
      }
      if (/aria-label="Move to trash"/i.test(selector)) {
        // The trash control is a PHOTO-VIEW control, not a grid control --
        // only present while a photo is actually open. This is the crux of
        // the live bug closeAnyOpenPhoto's fix targets: the search box
        // (above) stays visible the whole time and so can NEVER be used to
        // detect "a photo is open"; TRASH_SELECTOR can. `trashButtonVisible`
        // stays available as an AND-ed override for a fixture that wants to
        // force it hidden even while a photo is open (e.g. a confirmation
        // dialog covering the toolbar).
        return photoOpen(page) && page.config.trashButtonVisible !== false;
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
