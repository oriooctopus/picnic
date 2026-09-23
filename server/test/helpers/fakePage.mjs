import { tileIdentity } from '../../lib/matcher.mjs';

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
 * ArrowRight (2026-09-01 traversal rewrite) advances the open photo to the
 * next tile in the date's FULL underlying order (fullOrderedTiles below),
 * not just what's currently "mounted" -- see that function's comment for
 * why. Trashing the current photo can also auto-advance by itself
 * (performTrash), which is why worker.mjs's walkPhotoView checks for that
 * before ever pressing ArrowRight after a trash.
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
 * `tileLocatorFor` (2026-09-12) also pins `[href="..."]` when the tile it was
 * built from carried one -- pull that back out the same way ariaLabelFromSelector
 * pulls the aria-label. `null` (no href attribute in the selector at all) is
 * the back-compat case: match by aria-label alone, exactly like every fixture
 * written before this change.
 */
function hrefFromSelector(selector) {
  const m = /\[href="((?:[^"\\]|\\.)*)"\]/.exec(selector || '');
  return m ? m[1].replace(/\\(.)/g, '$1') : null;
}

/** tileIdentity() (matcher.mjs) expects an object; fixtures can still be bare strings. */
function identityOf(tile) {
  return tileIdentity(typeof tile === 'string' ? { ariaLabel: tile } : tile);
}

/**
 * Find a tile in the currently-mounted grid by aria-label, optionally pinned
 * to a specific href too -- mirrors tileLocatorFor's own two-attribute
 * selector. `href == null` means the selector carried no href constraint
 * (an older, aria-label-only selector, or a bare-string tile fixture) --
 * match by aria-label alone, same as every fixture written before
 * 2026-09-12. A non-null href requires an EXACT match, which is what makes
 * two tiles sharing an aria-label but differing by href independently
 * addressable (Oliver's real duplicate library items -- see
 * dedupeTilesByIdentity's header in matcher.mjs).
 */
function findTile(page, { ariaLabel, href }, pool = windowedTiles(page)) {
  return (
    pool.find((t) => {
      const tAriaLabel = typeof t === 'string' ? t : t.ariaLabel;
      if (tAriaLabel !== ariaLabel) return false;
      if (href == null) return true;
      const tHref = typeof t === 'string' ? undefined : t.href;
      return tHref === href;
    }) ?? null
  );
}

/**
 * True when `selector` is an identity-scoped result-link selector built by
 * worker.mjs's tileLocatorFor (`a[href^="./search/"][aria-label="..."]`),
 * as opposed to the plain `a[href^="./search/"]` selector .all() resolves
 * against. Both contain the `./search/` substring, so this also requires an
 * aria-label to be present, to avoid misrouting the plain selector's
 * count/visible checks into the tile-lookup path.
 *
 * 2026-09-22: also recognizes `./photo/` -- the timeline walk's own
 * tileLocatorFor call (worker.mjs's openTile, passed TIMELINE_TILE_SELECTOR)
 * builds an identically-shaped selector against that prefix instead.
 */
function isTileIdentitySelector(selector) {
  return (
    typeof selector === 'string' &&
    (selector.includes('./search/') || selector.includes('./photo/')) &&
    ariaLabelFromSelector(selector) != null
  );
}

/** True when `selector` addresses the TIMELINE view (worker.mjs's TIMELINE_TILE_SELECTOR), never a date-search result. */
function isTimelineSelector(selector) {
  return typeof selector === 'string' && selector.includes('./photo/');
}

/**
 * True when `selector` is the trash CONFIRM DIALOG's own button (worker.mjs's
 * moveToTrash: `'button:has-text("Move to trash"), button:has-text("Delete"),
 * button:has-text("Move to bin")'`) -- distinct from TRASH_SELECTOR, the
 * TOOLBAR control that OPENS the dialog. Round 5 (2026-09-25) needs to
 * recognize this specific selector to model a click that DETACHES the
 * element it just resolved (config.confirmClickFailuresBeforeSuccess below).
 */
function isConfirmDialogButtonSelector(selector) {
  return typeof selector === 'string' && (/has-text\("Move to trash"\)/i.test(selector) || /has-text\("Delete"\)/i.test(selector));
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
  // Filtered by IDENTITY (href, falling back to aria-label), not aria-label
  // alone -- 2026-09-12: two of Oliver's real duplicate library items can
  // share an aria-label (identical EXIF capture second) but have distinct
  // hrefs; trashing one must not make BOTH disappear from the grid.
  return [...base, ...revealedBatches].filter((tile) => !page.trashedIdentities.has(identityOf(tile)));
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

/**
 * TIMELINE equivalent of tilesInGrid, REWRITTEN 2026-09-22 for the
 * photo-viewer redesign of `--walk=timeline` (worker.mjs's walkTimeline),
 * and given a LOADED-WINDOW cap again in round 5 (2026-09-25).
 *
 * Round 4 (the comment this replaces) assumed the grid never needed
 * revisiting once the viewer opened its first tile -- true for the ArrowRight
 * traversal ITSELF, but a live run proved the viewer's own ArrowRight can
 * only reach photos the underlying grid has actually MOUNTED (~450 out of a
 * library going back to March), which is a real, load-bearing cap this fake
 * must model or a test can't tell "resumeTimelineAt correctly falls back to
 * the grid and finds more" from "there was never a cap to hit at all".
 *
 * `page.timelineLoadedCount` (mutable, page-level -- see its own init in
 * createFakePage) is how many of `config.timelineTiles` (newest-first) are
 * currently "mounted"; it starts at `config.timelineInitialLoadedCount` if
 * set, else Infinity (unbounded -- every pre-round-5 fixture that never sets
 * this key keeps its old "the whole library is available immediately"
 * behaviour exactly). It only ever GROWS, via a downward `scrollResults()`
 * call while NO photo is open (see the mouse.wheel handler below) -- ArrowRight
 * inside the viewer never grows it, matching the live finding that the
 * viewer itself provides no way to load more.
 */
function loadedTimelineTiles(page) {
  const base = page.config.timelineTiles ?? [];
  return Number.isFinite(page.timelineLoadedCount) ? base.slice(0, page.timelineLoadedCount) : base;
}

function tilesInTimeline(page) {
  return loadedTimelineTiles(page).filter((tile) => !page.trashedIdentities.has(identityOf(tile)));
}

/**
 * worker.mjs's readPanelText() (2026-09-23 rewrite, see selectPanelText's
 * own header in worker.mjs) now expects page.evaluate() to return
 * `{ detailsAndFile, dimsAndFile, fileOnly }` -- three tiers of raw
 * innerText strings -- rather than one already-chosen string. This fake
 * still models everything as ONE opaque string per photo (there is no real
 * DOM here to tier), so this classifies that single string into whichever
 * ONE tier it would have landed in for a real page: containing "Details" +
 * a filename (the tier that also carries the capture-date lines), just
 * dimensions + filename, or filename alone.
 *
 * The FILE check here is DELIBERATELY LOOSER than worker.mjs's own
 * `\b`-suffixed version: production's `\b` only matches on real live text
 * because the info panel's innerText genuinely has a NEWLINE between the
 * filename and whatever follows it (Oliver's live probe, 2026-09-23 --
 * "IMG_2931.HEIC\n12.2MP\n..."), which is a word/non-word transition. This
 * fake's long-established `panelBlock` fixtures predate that finding and
 * are deliberately RUN TOGETHER with no separator at all
 * ("IMG_1433.HEIC7.2MP...", a digit immediately after the extension) --
 * `\b` never matches between two word characters, so production's exact
 * regex would silently classify every one of those existing fixtures as
 * "no filename here" and break ~40 pre-existing tests that have nothing to
 * do with this change (caught by running the suite, not by inspection).
 * Dropping the trailing `\b` keeps this fake's classification step
 * tolerant of both text shapes without touching those fixtures.
 */
function classifyPanelText(text) {
  const empty = { detailsAndFile: [], dimsAndFile: [], fileOnly: [], detailsHeadingOnly: [] };
  if (!text) return empty;
  const DIMS = /\d{3,5}\s*[×x]\s*\d{3,5}/;
  const FILE = /[A-Za-z0-9._-]+\.(HEIC|JPG|JPEG|PNG|MOV|MP4)/i; // no trailing \b -- see header above
  const DETAILS = /Details/;
  if (!FILE.test(text)) {
    // ROUND 8 (2026-09-25 live finding): a visible "Details" heading with NO
    // filename yet is the panel OPEN but still LOADING -- distinct from
    // CLOSED (no Details heading at all). See isPanelOpenButLoading's own
    // header in worker.mjs for the live bug this models: Oliver's probe
    // showed the Details container's innerText was JUST "Details" for up to
    // ~9s after opening before the full panel rendered.
    if (/^Details\b/.test(text.trim())) return { ...empty, detailsHeadingOnly: [text] };
    return empty;
  }
  if (DETAILS.test(text)) return { detailsAndFile: [text], dimsAndFile: [], fileOnly: [], detailsHeadingOnly: [] };
  if (DIMS.test(text)) return { detailsAndFile: [], dimsAndFile: [text], fileOnly: [], detailsHeadingOnly: [] };
  return { detailsAndFile: [], dimsAndFile: [], fileOnly: [text], detailsHeadingOnly: [] };
}

/**
 * Accepts either a plain string (auto-classified via classifyPanelText, the
 * common case -- every pre-existing fixture) OR an explicit candidate-set
 * object (`{ detailsAndFile?, dimsAndFile?, fileOnly? }`, each an array of
 * raw strings) for a fixture that needs to model MULTIPLE distinct DOM
 * elements existing at once for the SAME photo -- e.g. a small
 * filename-only element sitting alongside a separate, larger "Details"
 * container that also carries the capture-date lines (the exact live shape
 * selectPanelText's tiering exists to prefer correctly; see the
 * "date lines outside the filename element" test in worker.test.mjs).
 */
function panelTextCandidateSets(value) {
  const empty = { detailsAndFile: [], dimsAndFile: [], fileOnly: [], detailsHeadingOnly: [] };
  if (value == null) return empty;
  if (typeof value === 'string') return classifyPanelText(value);
  return {
    detailsAndFile: value.detailsAndFile ?? [],
    dimsAndFile: value.dimsAndFile ?? [],
    fileOnly: value.fileOnly ?? [],
    detailsHeadingOnly: value.detailsHeadingOnly ?? [],
  };
}

/**
 * Timeline panel text, with two LIVE-CONFIRMED lag effects modelled
 * (2026-09-23, from a real run of worker.mjs 7565a5d): opening/advancing to
 * a photo can read back EMPTY for the first few polls before the panel
 * actually renders (`config.timelinePanelRenderDelayReads`), and after an
 * ArrowRight/click advance the panel can keep showing the PREVIOUS photo's
 * STALE text for the first few polls before catching up
 * (`config.timelineStaleReadsAfterAdvance`) -- this is what produced the
 * real bug: photo 1 and 2 of a live run both read back "IMG_2932.JPG"
 * because the second read landed during exactly this lag window. Both
 * counters are internally tracked per-photo (reset the moment
 * `page.openedIdentity` changes, detected here rather than by hooking every
 * site that mutates it) so a fixture opts in simply by setting the config
 * key -- no caller needs to know when a transition happened.
 */
function timelinePanelTextFor(page) {
  const currentIdentity = page.openedIdentity ?? page.openedAriaLabel;
  if (page._timelinePanelIdentity !== currentIdentity) {
    // A fresh transition (tile opened, or advanced to a new photo) since the
    // last read -- remember what the PREVIOUS identity's real text was (for
    // the stale-read simulation below) and reset both lag counters. The
    // very first tile of a run has no previous identity, so its stale-read
    // count is always 0 regardless of config (nothing to be stale WITH).
    page._timelinePanelPrevText = page._timelinePanelRealText ?? '';
    page._timelinePanelIdentity = currentIdentity;
    page._timelinePendingRenderDelay = page.config.timelinePanelRenderDelayReads ?? 0;
    page._timelinePendingStaleReads = page._timelinePanelPrevText ? page.config.timelineStaleReadsAfterAdvance ?? 0 : 0;
    // ROUND 8 (2026-09-25 live finding): the first N reads after a transition
    // show the "Details" HEADING rendered but its fields not yet -- see
    // classifyPanelText's own header for the exact live symptom this models.
    // Distinct from timelinePanelRenderDelayReads above, which models
    // nothing being visible AT ALL yet (a closed-looking panel); this models
    // a genuinely OPEN, merely still-loading one.
    page._timelinePendingDetailsOnly = page.config.timelinePanelDetailsOnlyReads ?? 0;
    page._timelinePanelRealText = page.config.timelinePanelTextByLabel?.[page.openedAriaLabel] ?? '';
  }
  // A fixture can configure an OBJECT (explicit candidate-set shape, see
  // panelTextCandidateSets' header) instead of a plain string, to model
  // MULTIPLE distinct DOM elements existing at once for this one photo
  // (e.g. a small filename-only element plus a separate "Details"
  // container). That's a fundamentally different kind of fixture than the
  // render-delay/staleness simulation below, which only makes sense for a
  // single opaque string -- bypass both entirely and hand it straight
  // through.
  if (page._timelinePanelRealText && typeof page._timelinePanelRealText === 'object') {
    return page._timelinePanelRealText;
  }
  if (page._timelinePendingRenderDelay > 0) {
    page._timelinePendingRenderDelay -= 1;
    return '';
  }
  if (page._timelinePendingDetailsOnly > 0) {
    page._timelinePendingDetailsOnly -= 1;
    // An explicit candidate-set object (see panelTextCandidateSets' header)
    // rather than a plain string -- a bare "Details" string would ALSO
    // classify this way via classifyPanelText's own round-8 branch, but
    // returning the object directly here keeps this phase's behaviour
    // independent of that string-classification path entirely.
    return { detailsHeadingOnly: ['Details'] };
  }
  if (page._timelinePendingStaleReads > 0) {
    // A trailing-space marker (not just the raw previous text verbatim)
    // models the REAL live shape of this bug more precisely: the actual
    // failure showed the FILENAME substring staying stale while something
    // else about the read differed (2026-09-23) -- a byte-IDENTICAL stale
    // read would already be caught by any bare "text !== previousText"
    // check, so a mutation-proof against that alone would prove nothing.
    // Appending whitespace (harmless to every FILENAME/DIMS/date regex,
    // all of which tolerate trailing \s) keeps the raw string genuinely
    // different each read while the PARSED filename stays the stale one,
    // which is exactly what worker.mjs's waitForTimelineAdvanceConfirmed
    // must catch by comparing parsed filenames, not raw text.
    page._timelinePendingStaleReads -= 1;
    return `${page._timelinePanelPrevText} `; // trailing space -- raw text differs, parsed filename does not
  }
  return page._timelinePanelRealText;
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
function openTileInFake(page, ariaLabel, href) {
  page.log.push(`tile-click:${ariaLabel}`);
  page.openedAriaLabel = ariaLabel;
  // Separate from openedAriaLabel (used for panel-text lookups, which are
  // legitimately keyed by aria-label since duplicate copies share identical
  // panel content) -- openedIdentity (href, falling back to aria-label) is
  // what performTrash/hasNextPhoto/advanceToNextTile use to find THIS
  // specific element's position in fullOrderedTiles(), so trashing one of
  // two aria-label-sharing duplicates only removes that ONE from the day's
  // order, not both.
  page.openedIdentity = href ?? ariaLabel;
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
      const href = hrefFromSelector(this.selector);
      // 2026-09-22: route to the TIMELINE pool for a TIMELINE_TILE_SELECTOR --
      // same fix as countFor/visibleFor above. Missing this here (while
      // fixing only countFor/visibleFor) is exactly the kind of half-fix that
      // makes openTile() THINK a tile is there (count()===1, isVisible()===
      // true, both correctly pool-routed) and then silently click nothing --
      // openedAriaLabel never gets set, so the info panel poll times out no
      // matter what the panel-text fixture says. Caught by running the new
      // timeline tests, not by inspection.
      const pool = isTimelineSelector(this.selector) ? tilesInTimeline(this.page) : windowedTiles(this.page);
      const tile = findTile(this.page, { ariaLabel: label, href }, pool);
      if (!isUnopenable(this.page, label) && tile) {
        openTileInFake(this.page, label, typeof tile === 'string' ? undefined : tile.href);
        return;
      }
    }
    // ROUND 5 (2026-09-25 live finding): the confirm dialog's OWN button can
    // DETACH mid-click ("element was detached from the DOM, retrying") --
    // see confirmDialog's own header in worker.mjs for the two distinct
    // causes this models, matched by `config.confirmClickAlreadyTrashedOnFailure`:
    //   - unset (default): the button re-rendered/repositioned -- the dialog
    //     stays open (page.dialogOpen untouched), so confirmDialog's retry
    //     re-resolves and clicks again, succeeding once the budget below runs
    //     out.
    //   - true: the FIRST click actually WORKED (performTrash runs here,
    //     exactly as a real successful click would trigger via onClick
    //     below) and it's the dialog's own close animation that detaches the
    //     button out from under the click handler -- confirmDialog must
    //     recognize the toast/panel-change evidence and treat this as
    //     confirmed WITHOUT a further retry.
    // Either way the throw itself is unconditional: a real detach IS a
    // thrown exception from Playwright's click(), which is exactly the
    // shape confirmDialog's try/catch must recover from, not a config value
    // it gets to peek at.
    if (isConfirmDialogButtonSelector(this.selector) && this.page._confirmClickFailuresRemaining > 0) {
      this.page._confirmClickFailuresRemaining -= 1;
      if (this.page.config.confirmClickAlreadyTrashedOnFailure) {
        this.page.dialogOpen = false;
        performTrash(this.page);
      }
      throw new Error('element was detached from the DOM, retrying');
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
  constructor(page, ariaLabel, index, href) {
    this.page = page;
    this.ariaLabel = ariaLabel;
    this.index = index;
    this.href = href; // undefined for fixtures that never set one -- see identityOf()'s fallback to aria-label
  }
  async isVisible() {
    return this.hidden !== true;
  }
  async getAttribute(name) {
    if (name === 'aria-label') return this.ariaLabel;
    if (name === 'href') return this.href ?? null;
    return null;
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
    // above) always resolves fresh by aria-label+href and is immune, which is
    // the whole point of the fix and what the positional-drift regression
    // test below proves by mutation. `staleTileClickTargets` fixtures only
    // ever named an aria-label to drift onto (pre-2026-09-12), so the drift
    // target opens without an href -- exactly like the pre-existing tests
    // that exercise it, which never modelled hrefs at all.
    const driftTarget = this.page.config.staleTileClickTargets?.[this.ariaLabel];
    if (driftTarget) openTileInFake(this.page, driftTarget, undefined);
    else openTileInFake(this.page, this.ariaLabel, this.href);
  }
}

/**
 * The FULL underlying order of the currently open sequence -- base
 * searchResults followed by every scrollReveals batch, regardless of
 * revealedCount/windowStart (unlike tilesInGrid/windowedTiles above, which
 * only see what's currently "mounted"). Models the live fact worker.mjs's
 * traversal rewrite (2026-09-01) depends on: ArrowRight ("View next photo")
 * pages through Google's own underlying search-result order, not through
 * whatever the grid happens to have mounted -- the early working version of
 * this worker walked 27 photos on one date via ArrowRight alone, with no
 * scrolling at all. Trashed labels are excluded (a deleted photo is gone
 * from the results, never revisited).
 *
 * TIMELINE MODE (2026-09-22, photo-viewer redesign): when
 * `config.timelineTiles` is set, THAT flat array is the full order instead
 * -- walkTimeline opens the newest tile once and then walks this exact same
 * ArrowRight machinery (performTrash/hasNextPhoto/advanceToNextTile all
 * call this function), so the timeline needs no separate "full order"
 * concept of its own. ROUND 5: also capped to `page.timelineLoadedCount`
 * (loadedTimelineTiles, tilesInTimeline's own header) -- ArrowRight must
 * NOT be able to walk past what the grid has "mounted", the exact live
 * behaviour resumeTimelineAt exists to work around.
 */
// Returns the raw tile objects (not flattened to aria-label strings) -- see
// performTrash's header for why: two tiles can share an aria-label (Oliver's
// real duplicate library items) but must be independently indexable by
// IDENTITY (href, falling back to aria-label) so trashing one doesn't also
// remove the other from this order.
function fullOrderedTiles(page) {
  const raw =
    page.config.timelineTiles != null
      ? loadedTimelineTiles(page)
      : [...(page.config.searchResults[page.activeQuery] ?? []), ...(page.config.scrollReveals[page.activeQuery] ?? []).flat()];
  return raw
    .map((t) => (typeof t === 'string' ? { ariaLabel: t, href: undefined } : t))
    .filter((t) => !page.trashedIdentities.has(identityOf(t)));
}

/**
 * Trashing the CURRENT photo removes it from the results and -- modelled
 * here to match the live behaviour worker.mjs's traversal rewrite handles
 * explicitly (see walkPhotoView's `advancedByDelete`) -- the view can
 * auto-advance to the next photo in the day BY ITSELF, without any
 * ArrowRight press. The next-tile lookup must run BEFORE marking the current
 * IDENTITY trashed: fullOrderedTiles() filters trashed identities out, so
 * computing "what comes after me" AFTER the filter would never find the
 * current tile at all (findIndex returns -1). If there's no next tile (this
 * was the day's last one), the view closes instead -- openedAriaLabel/
 * openedIdentity go null, same as an ordinary close, which moveToTrash's
 * settled() check already handles (`!now && panelTextBefore` reads as
 * "settled").
 *
 * Uses openedIdentity (href, falling back to aria-label), NOT openedAriaLabel,
 * to find "me" in `ordered` -- two tiles can share an aria-label (Oliver's
 * real duplicate library items), and indexOf-by-label would always find the
 * FIRST such tile regardless of which one is actually open, silently
 * trashing/advancing from the wrong element.
 */
/**
 * True when `label` names a photo that the fake's info panel CLOSES on
 * arrival at, via any of the three ways `page.openedAriaLabel` can change
 * to it as part of an ADVANCE (ArrowRight, the "View next photo" click
 * fallback, or a trash's own auto-advance) -- NOT the very first tile
 * opened this walk, which matches the live finding precisely (2026-09-24,
 * round 3): instrumented live, the info panel was closed on roughly HALF
 * of all ArrowRight advances, forcing worker.mjs's
 * waitForTimelineAdvanceConfirmed to notice the empty read and call
 * openInfoPanelOnce() again. `config.timelinePanelClosesOnLabels` is an
 * array or Set of ariaLabels that trigger this.
 */
function closesInfoPanelOnArrival(page, label) {
  const set = page.config.timelinePanelClosesOnLabels;
  if (!set || label == null) return false;
  return set instanceof Set ? set.has(label) : Array.isArray(set) && set.includes(label);
}

/**
 * Call unconditionally right after `page.openedAriaLabel` changes to
 * `label` as part of an ADVANCE (never the first tile opened) -- a no-op
 * unless `label` is configured to close the panel (closesInfoPanelOnArrival
 * above), in which case it ALSO arms the reopen-failure counter
 * (`config.timelinePanelReopenFailuresBeforeSuccess`) for whatever comes
 * next, keeping both pieces of state in the one place that sets them.
 */
function closeInfoPanelOnArrivalIfConfigured(page, label) {
  if (closesInfoPanelOnArrival(page, label)) {
    page.infoPanelOpen = false;
    page._timelinePanelReopenFailuresRemaining = page.config.timelinePanelReopenFailuresBeforeSuccess ?? 0;
    return;
  }
  // Arriving at a photo NOT configured to close the panel -- any leftover
  // reopen-failure budget from a PREVIOUS closed photo (e.g. one
  // deliberately configured to never recover, per
  // timelinePanelReopenFailuresBeforeSuccess) must not leak forward onto
  // this one. Caught by writing the "permanently unreadable photo does
  // NOT end the walk" test: without this reset, the photo immediately
  // AFTER the unreadable one also read as unreadable, because the fake's
  // failure counter was still sitting at a huge remaining value with
  // nothing left to decrement it back down.
  page._timelinePanelReopenFailuresRemaining = 0;
}

/**
 * Shared by the 'i' keyboard shortcut and the "Open info" button click --
 * both are ways to OPEN a closed info panel. `config.timelinePanelReopenFailuresBeforeSuccess`
 * (2026-09-24, round 4) models EITHER one failing to actually open it for
 * the first N attempts after the panel has closed -- worker.mjs's bounded
 * recovery loop (waitForTimelineAdvanceConfirmed's Phase B) must survive
 * several failed rounds before the panel finally responds, matching the
 * live symptom (activeElement ended up BUTTON[Open info] -- the click
 * path was tried but the panel still hadn't rendered). Defaults to
 * succeeding immediately (0 failures) when unset, so every pre-existing
 * fixture's plain "i opens the panel" behaviour is unchanged.
 */
function attemptOpenInfoPanel(page) {
  if (page._timelinePanelReopenFailuresRemaining > 0) {
    page._timelinePanelReopenFailuresRemaining -= 1;
    return; // this attempt fails -- panel stays closed
  }
  page.infoPanelOpen = true;
}

function performTrash(page) {
  const identity = page.openedIdentity;
  if (identity == null) return;
  const ordered = fullOrderedTiles(page);
  const idx = ordered.findIndex((t) => identityOf(t) === identity);
  page.trashedIdentities.add(identity);
  // Models the real "Moved to trash" toast Google Photos shows immediately
  // after a delete (moveToTrash's settled() checks for it via a `text=/moved
  // to (trash|bin)/i` locator). Needed for the duplicate-copy case
  // (2026-09-12): auto-advancing onto a photo with BYTE-IDENTICAL panel text
  // (a true duplicate of the one just trashed) makes settled()'s
  // content-diff check alone report "not settled" even though the deletion
  // genuinely took -- the toast is the orthogonal, content-independent
  // signal that saves this live. Cleared the moment anything else reads it
  // (visibleFor below), mirroring a real toast that only flashes once.
  page.justTrashedToastVisible = true;
  const next = idx !== -1 && idx + 1 < ordered.length ? ordered[idx + 1] : null;
  page.openedAriaLabel = next ? next.ariaLabel : null;
  page.openedIdentity = next ? identityOf(next) : null;
  if (next) closeInfoPanelOnArrivalIfConfigured(page, next.ariaLabel);
}

/**
 * Advance the open photo to the next one in the date's full underlying order
 * (see fullOrderedTiles above) -- models worker.mjs's ArrowRight navigation.
 * No next tile (already at the last one, or nothing open) leaves
 * openedAriaLabel unchanged, which is exactly the live signal
 * waitForPanelChange relies on: the panel keeps reading the same content, so
 * polling for a CHANGE times out and the walk correctly concludes "end of
 * the day's results" rather than hanging or guessing.
 */
/**
 * Is there a photo after the currently-open one in this date's order?
 *
 * worker.mjs now treats the ABSENCE of the "View next photo" control as the
 * authoritative end-of-day signal, because a panel-change timeout cannot be
 * trusted for that: live, ArrowRight intermittently fails to register (the
 * same date walked 7 photos on one run and 1 on the next), so a timeout means
 * "did not advance", which is NOT the same as "no more photos".
 */
function hasNextPhoto(page) {
  const identity = page.openedIdentity;
  if (identity == null) return false;
  const ordered = fullOrderedTiles(page);
  const idx = ordered.findIndex((t) => identityOf(t) === identity);
  return idx !== -1 && idx + 1 < ordered.length;
}

function advanceToNextTile(page) {
  const identity = page.openedIdentity;
  if (identity == null) return;
  const ordered = fullOrderedTiles(page);
  const idx = ordered.findIndex((t) => identityOf(t) === identity);
  if (idx === -1 || idx + 1 >= ordered.length) return; // unknown position, or already the last tile -- no next photo
  const next = ordered[idx + 1];
  page.openedAriaLabel = next.ariaLabel;
  page.openedIdentity = identityOf(next);
  closeInfoPanelOnArrivalIfConfigured(page, next.ariaLabel);
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
 *   swallowTrashShortcut?: boolean,  // "#" keyboard fallback does nothing at all -- no dialog, no trash (falls through to the toolbar-click fallback)
 *   trashDialogNeverAppears?: boolean, // the toolbar trash-control CLICK resolves but its confirm dialog never renders -- models the confirmed-live B4D8DDA7... false positive (moveToTrash's 2026-09-22 fix)
 *   searchBoxHiddenUntilEscape?: boolean,
 *   closeAfterTiles?: number,        // browser tab "closes" right after this many tiles have been opened, across the whole run
 *   staleTileClickTargets?: Record<string, string>, // ariaLabel -> ariaLabel a POSITIONAL tile.locator.click() actually lands on instead (models live re-render drift; the identity-scoped locator is immune -- see FakeTileLink.click())
 *   windowSize?: number,             // only N tiles are "mounted" at once -- models a VIRTUALIZED grid where scrolling swaps the visible window rather than only ever growing it. A positive-dy mouse.wheel (scrollResults) follows the tail forward and loads more; a negative-dy wheel (scrollResultsUp) moves the window back over already-loaded content without loading anything new (see windowedTiles())
 *   unopenableLabels?: string[]|Set<string>, // labels that collectResultTiles() can see (on-screen, real) but the identity-scoped selector openTile() clicks can NEVER resolve -- models a tile the grid refuses to mount, for the "unreachable tile, retried then recorded" behaviour
 *   swallowInfoPressesCount?: number, // first N "i" keypresses across the whole run are silently lost (models the keystroke landing mid-transition, before the photo view existed)
 *   timelineTiles?: Array<{ariaLabel: string, href?: string}|string>, // 2026-09-22 (photo-viewer redesign): presence alone switches the fake into TIMELINE mode (worker.mjs's walkTimeline) -- the FULL flat underlying order (newest first), exactly like fullOrderedTiles' role for the grid's own ArrowRight traversal. No scroll/reveal/window modelling -- the redesigned walk opens only the first (newest) tile and never touches the grid again.
 *   timelinePanelTextByLabel?: Record<string, string>, // ariaLabel -> info-panel text, FLAT (no query nesting -- the timeline has no active query) -- timeline equivalent of panelTextByLabel
 *   timelinePanelRenderDelayReads?: number, // 2026-09-23: first N reads after opening/advancing to a timeline photo return EMPTY before the real text renders -- see timelinePanelTextFor's header
 *   timelineStaleReadsAfterAdvance?: number, // 2026-09-23: first N reads after an ArrowRight/click ADVANCE (never the first tile) return the PREVIOUS photo's text before catching up -- models the real lag bug that produced two consecutive stale "IMG_2932.JPG" reads in a live run
 *   timelinePanelClosesOnLabels?: string[]|Set<string>, // 2026-09-23/24: the info panel is CLOSED on arrival at any of these labels via an ADVANCE (ArrowRight, click fallback, or a trash's own auto-advance) -- never the first tile opened -- see closeInfoPanelOnArrivalIfConfigured
 *   timelinePanelReopenFailuresBeforeSuccess?: number, // 2026-09-24 (round 4): the first N attempts to reopen a CLOSED panel (via 'i' or the "Open info" button, whichever worker.mjs tries) fail outright; the next one succeeds -- see attemptOpenInfoPanel
 *   timelineFocusLostAfterFallbackClick?: boolean, // 2026-09-23: a toolbar fallback click (trash control OR "View next photo") leaves keyboard focus off the viewer -- ArrowRight/'#' become no-ops until a real click (focusViewerCenter) restores it
 *   timelineInitialLoadedCount?: number, // 2026-09-25 (round 5): how many of timelineTiles are "mounted" at the start -- Infinity (unbounded) when unset -- see loadedTimelineTiles
 *   timelineLoadStep?: number, // 2026-09-25 (round 5): how many MORE tiles a grid-mode (no photo open) downward scroll mounts -- see the mouse.wheel timeline branch
 *   confirmClickFailuresBeforeSuccess?: number, // 2026-09-25 (round 5): the first N clicks on the trash CONFIRM DIALOG's own button throw a detach-style error -- see isConfirmDialogButtonSelector
 *   confirmClickAlreadyTrashedOnFailure?: boolean, // 2026-09-25 (round 5): when a confirm-dialog click is configured to fail (above), also model the FIRST such click having actually worked (performTrash runs, dialogOpen closes) before it throws -- the "gone with the photo already trashed" variant confirmDialog's recovery must recognize
 *   throwOnKeyForLabel?: {label: string, key: string, message?: string}, // 2026-09-25 (round 5): the NEXT press of `key` while `label`'s photo is open throws a generic Error -- models an arbitrary unexpected failure walkTimeline's own per-photo try/catch must recover from, distinct from the confirm-dialog-specific detach above
 *   gotoFailsForUrls?: string[]|Set<string>, // 2026-09-25 (round 9): page.goto() throws (timeout-shaped) for these exact URLs -- see revisitUnreadable's own try/catch in worker.mjs
 *   revisitPanelTextByLabel?: Record<string, string>, // 2026-09-25 (round 9): panel text seen ONLY via a direct page.goto(url) open (the timeline photo URL shape), distinct from timelinePanelTextByLabel -- models a photo reading reliably via direct navigation where the in-viewer walk never resolved it
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
    openedIdentity: null, // href, falling back to aria-label -- see openTileInFake()'s header
    openedTileCount: 0,
    infoPanelOpen: false,
    trashedIdentities: new Set(), // keyed by identity (href, falling back to aria-label), not aria-label alone -- see tilesInGrid()'s header
    revealedCount: 0,
    windowStart: 0, // index into tilesInGrid(page) where the mounted window (windowedTiles) currently begins -- see mouse.wheel below
    // ROUND 5 (2026-09-25): how many of config.timelineTiles are "mounted" --
    // see loadedTimelineTiles' header. Infinity by default (unbounded) so
    // every pre-round-5 fixture that never sets timelineInitialLoadedCount
    // keeps behaving exactly as before; only grows via a grid-mode scroll.
    timelineLoadedCount: config.timelineInitialLoadedCount ?? Infinity,
    // ROUND 5 (2026-09-25): how many leading clicks on the trash confirm
    // DIALOG's own button throw a detach-style error before succeeding --
    // see isConfirmDialogButtonSelector's header. 0 by default (no fixture
    // that never sets confirmClickFailuresBeforeSuccess is affected).
    _confirmClickFailuresRemaining: config.confirmClickFailuresBeforeSuccess ?? 0,
    recollectCount: {},
    escapePresses: 0,
    infoPressesSwallowed: 0, // count of "i" presses dropped so far, capped by config.swallowInfoPressesCount
    justTrashedToastVisible: false, // see performTrash() -- flashes true for exactly one isVisible() read after a trash
    dialogOpen: false, // the "Move to trash"/"Delete"/"Move to bin" confirm dialog -- see the '#' key handler's 2026-09-22 header
    focusLost: false, // 2026-09-23: keyboard focus off the viewer -- see config.timelineFocusLostAfterFallbackClick
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
        // ROUND 5 (2026-09-25): models an arbitrary UNEXPECTED failure mid
        // per-photo processing (distinct from the confirm-dialog-specific
        // detach modelled in FakeLocator.click() above) -- e.g. a genuine
        // '#' keypress failure while pressing Google Photos' own trash
        // shortcut, well before any confirm-dialog button exists to click.
        // Exists to prove walkTimeline's OWN try/catch (worker.mjs, "ROUND 5
        // ... the whole per-photo match/trash/advance step below is now
        // wrapped") recovers from a raw, unrelated exception, not just from
        // the specific bug confirmDialog's own retry logic already handles.
        if (
          page.config.throwOnKeyForLabel &&
          page.openedAriaLabel === page.config.throwOnKeyForLabel.label &&
          key === page.config.throwOnKeyForLabel.key
        ) {
          throw new Error(page.config.throwOnKeyForLabel.message ?? 'simulated unexpected failure');
        }
        if (key === 'Escape') {
          page.escapePresses += 1;
          page.openedAriaLabel = null;
          page.openedIdentity = null;
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
          } else if (page.infoPanelOpen) {
            // Was open -- 'i' always closes it. Unaffected by
            // `timelinePanelReopenFailuresBeforeSuccess` below, which only
            // ever models an OPEN attempt failing, never a close.
            // ROUND 8 (2026-09-25 live finding): toggling an OPEN panel is
            // never correct, whether the panel is fully rendered or still
            // "Details"-only loading -- tracked here (not gated on the
            // loading state specifically) so a test can assert "zero
            // toggles happened at all" while a read is in progress, the
            // exact live bug (waitForTimelineAdvanceConfirmed's recovery
            // loop closing an already-open-but-loading panel every round,
            // so it could never finish rendering).
            page.togglesWhileOpen = (page.togglesWhileOpen ?? 0) + 1;
            page.infoPanelOpen = false;
          } else {
            attemptOpenInfoPanel(page);
          }
        }
        // 2026-09-22: '#' now only OPENS the confirm dialog -- it no longer
        // trashes directly. This mirrors the live two-step flow moveToTrash()
        // drives (press '#' -> dialog appears -> click its confirm button),
        // which is exactly the step the B4D8DDA7... false-positive skipped:
        // the OLD fake (like the old worker.mjs bug) let '#' alone count as a
        // trash, so no fixture could ever exercise "dialog never appeared".
        // `swallowTrashShortcut` keeps its existing meaning (the shortcut
        // does nothing at all -- worker.mjs falls through to the toolbar
        // click fallback, whose own dialog is modelled separately below).
        // `page.focusLost` (2026-09-23, `config.timelineFocusLostAfterFallbackClick`)
        // -- models the live bug where keyboard focus drifted off the
        // viewer after a toolbar fallback click, so NEITHER of these
        // shortcuts reached Google's own handler until a real click
        // (focusViewerCenter -> mouse.click(), which clears this) restored
        // it. See that config flag's own comment on the fallback-click
        // handler below for where it gets set.
        if (key === '#' && !page.config.swallowTrashShortcut && !page.focusLost) page.dialogOpen = true;
        if (key === 'ArrowRight' && !page.focusLost) advanceToNextTile(page);
        if (key === 'Enter') {
          page.activeQuery = page.pendingTypedText ?? null;
          page.openedAriaLabel = null;
          page.openedIdentity = null;
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
    viewportSize() {
      return { width: 1280, height: 800 };
    },
    mouse: {
      async move(x, y) {
        page.log.push(`mouse-move ${x},${y}`);
        page.pointer = { x, y };
      },
      // worker.mjs's focusViewerCenter() (2026-09-23) -- a real click, not
      // just a pointer move, since its whole point is to re-establish
      // KEYBOARD focus on the viewer after it's been lost (see that
      // function's own header). `config.timelineFocusLostAfterFallbackClick`
      // models the live bug it fixes: clears `page.focusLost` the same way
      // a real click restoring focus would.
      async click(x, y) {
        page.log.push(`mouse-click ${x},${y}`);
        page.pointer = { x, y };
        page.focusLost = false;
      },
      // worker.mjs's scrollResultsUp() passes a NEGATIVE dy (Google Photos'
      // own "scroll up" gesture) -- everything else in the worker still
      // calls scrollResults() with a positive dy, so a missing/positive dy
      // means "down", matching every pre-existing call site and fixture.
      async wheel(dx, dy) {
        page.guard();
        // Real Chrome scrolls whatever is under the pointer, and Playwright's
        // pointer starts at (0,0) over Google Photos' header, where a wheel
        // does nothing -- the 2026-09-22 live failure where the timeline walk
        // never moved. Model that: no scroll until the pointer is over the grid.
        if (!page.pointer || page.pointer.y < 100) {
          page.log.push('wheel-ignored');
          return;
        }
        const scrollingUp = typeof dy === 'number' && dy < 0;
        // Keep the plain 'wheel' entry every pre-existing test asserts on
        // (via page.log.includes('wheel')) AND add a directional one so a
        // new test can tell a recovery up-scroll apart from an ordinary
        // down-scroll.
        page.log.push('wheel');
        page.log.push(scrollingUp ? 'wheel:up' : 'wheel:down');
        // TIMELINE MODE, GRID scrolling (round 5, 2026-09-25): the round-4
        // comment this replaces claimed the grid never needs scrolling once
        // the viewer opens its first tile, which was true for ArrowRight
        // ITSELF but missed that the viewer can only reach whatever the grid
        // has actually MOUNTED -- a live run hard-stopped ~450 photos into a
        // library going back to March. resumeTimelineAt (worker.mjs) falls
        // back to the grid specifically to load more, via this exact
        // scrollResults()/wheel call, while NO photo is open (photoOpen(page)
        // false -- both resumeTimelineAt and findTimelineStartTile always
        // goto()/scroll from the base grid, never from inside the viewer).
        // Growth only happens downward and only for an explicit
        // `config.timelineLoadStep` -- a fixture that never sets it keeps
        // timelineLoadedCount at Infinity (unbounded), so every pre-round-5
        // fixture's assumption ("the whole library is available immediately")
        // is completely unaffected by this branch existing.
        if (page.config.timelineTiles != null && !photoOpen(page) && !scrollingUp) {
          const step = page.config.timelineLoadStep ?? Infinity;
          page.timelineLoadedCount = Math.min(page.config.timelineTiles.length, page.timelineLoadedCount + step);
          return;
        }
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
      // ROUND 9 (2026-09-25, revisitUnreadable): models a goto() that TIMES
      // OUT or otherwise throws for a specific URL -- Oliver's own live
      // probe hit a genuine 30s goto timeout on one URL, which is exactly
      // the failure revisitUnreadable's own try/catch must survive without
      // aborting the whole pass. `config.gotoFailsForUrls` is an
      // array/Set of URLs; any other URL navigates normally.
      const fails = page.config.gotoFailsForUrls;
      const shouldFail = fails instanceof Set ? fails.has(url) : Array.isArray(fails) && fails.includes(url);
      if (shouldFail) {
        throw new Error(`ROUND 9 FIXTURE: simulated goto failure (e.g. timeout) for ${url}`);
      }
      page._url = url;
      // A real navigation always leaves the photo viewer, back at the base
      // grid -- resumeTimelineAt (round 5, worker.mjs) explicitly goto()s
      // the library root before scrolling to find its resume target, and
      // the mouse.wheel timeline-load-growth branch above only fires while
      // NO photo is open, so this reset is what actually lets that scroll
      // do anything after a resume's goto.
      page.openedAriaLabel = null;
      page.openedIdentity = null;
      page.infoPanelOpen = false; // a fresh page load never carries over a previously-open panel
      // ROUND 10 (2026-09-25, verifyTrashByUrl): reset on EVERY goto() --
      // set back to true below only when this exact URL names an identity
      // already in trashedIdentities. Models Google's real trash-state
      // banner ("30 days left until permanently deleted", live-verified by
      // Oliver manually trashing a photo then reloading its exact URL).
      page._onTrashedPhotoPage = false;
      // ROUND 9 (2026-09-25, revisitUnreadable): a direct page.goto(url) to
      // one of THIS walk's own timeline photo URLs (exactly the shape
      // page.url() derives below: "https://photos.google.com/photo/
      // <encodeURIComponent(identity)>") lands straight in that photo's
      // viewer, matching the real Google Photos behaviour revisitUnreadable
      // depends on -- opening the SAME tile identity-scoped (openTileInFake)
      // reuses every existing panel-text/lag-simulation fixture unchanged,
      // rather than needing a second, URL-keyed config surface. A trashed
      // identity is skipped (its tile is genuinely gone), leaving the panel
      // closed -- openInfoPanelOnce then correctly times out on it, exactly
      // like a live 404/redirect on an already-deleted photo's URL would.
      //
      // Deliberately scoped to ONLY this photo-URL branch, not every
      // goto() (e.g. resumeTimelineAt's own base-library-root goto): a
      // leftover reopen-failure budget (timelinePanelReopenFailuresBefore-
      // Success, armed when the panel closed on arrival DURING the walk's
      // own ArrowRight traversal) belongs to the OLD render context, and a
      // genuinely fresh navigation has no such "recently failed to reopen"
      // history to inherit -- but resetting it unconditionally on EVERY
      // goto() would have silently changed round 6's resume-by-id behaviour
      // too (its own reopen of the SAME still-failing tile would then
      // spuriously succeed), caught by running the full suite after an
      // earlier draft did exactly that, not by inspection.
      const m = /^https:\/\/photos\.google\.com\/photo\/(.+)$/.exec(url);
      if (m && page.config.timelineTiles != null) {
        const identity = decodeURIComponent(m[1]);
        if (page.trashedIdentities.has(identity)) {
          // ROUND 10: this exact photo IS trashed -- a real Google Photos
          // reload of its URL shows the trash-state banner (verifyTrashByUrl
          // looks for "until permanently deleted"), never the live photo
          // viewer. openTileInFake is deliberately NOT called here -- the
          // tile is genuinely gone from the grid.
          page._onTrashedPhotoPage = true;
        } else {
          const tile = page.config.timelineTiles.find((t) => identityOf(t) === identity);
          if (tile) {
            page._timelinePanelReopenFailuresRemaining = 0;
            openTileInFake(page, tile.ariaLabel, tile.href);
            // ROUND 9: `config.revisitPanelTextByLabel` lets a fixture
            // configure content that's ONLY seen via a direct navigation
            // open, distinct from `timelinePanelTextByLabel` (what the
            // in-viewer ArrowRight walk sees) -- directly models the live
            // finding that the SAME photo read reliably via page.goto()
            // where the walk's own ArrowRight/resume traversal never
            // resolved it at all. Force a fresh "transition" so this
            // overrides whatever state the label carried from earlier in
            // the walk (a prior render-delay/stale-read countdown, etc.).
            if (page.config.revisitPanelTextByLabel?.[tile.ariaLabel] != null) {
              page._timelinePanelIdentity = page.openedIdentity ?? page.openedAriaLabel;
              page._timelinePanelRealText = page.config.revisitPanelTextByLabel[tile.ariaLabel];
              page._timelinePendingRenderDelay = 0;
              page._timelinePendingDetailsOnly = 0;
              page._timelinePendingStaleReads = 0;
            }
          }
        }
      }
    },
    async bringToFront() {
      page.guard();
      page.log.push('bringToFront');
    },
    async evaluate() {
      // Mirrors readPanelText(): returns the current tile's info-panel
      // CANDIDATE SETS (see panelTextCandidateSets' header), but only once
      // the (sticky) info panel is actually open. NOTE: worker.mjs also
      // calls page.evaluate() for a couple of purely diagnostic callbacks
      // (releaseFocus's blur, advanceTimelinePhotoView's VERBOSE-only
      // activeElement check) -- this fake can't tell those apart from the
      // panel-text one (a real Playwright evaluate() serializes and runs
      // whatever callback it's given; this fake ignores it and always
      // answers as if it were the panel-text call), which is harmless
      // since neither of those callers does anything with an unexpected
      // shape beyond an occasional VERBOSE-only log line.
      page.log.push('evaluate:panelText');
      if (!page.infoPanelOpen || page.openedAriaLabel == null) {
        return { detailsAndFile: [], dimsAndFile: [], fileOnly: [], detailsHeadingOnly: [] };
      }
      // 2026-09-22: the timeline has no `activeQuery` to key panel text off
      // (it's never reached via search) -- `timelinePanelTextByLabel` is a
      // flat ariaLabel->text map instead of the grid's query-nested shape.
      if (page.config.timelineTiles != null) {
        return panelTextCandidateSets(timelinePanelTextFor(page));
      }
      const byLabel = page.config.panelTextByLabel[page.activeQuery] ?? {};
      return panelTextCandidateSets(byLabel[page.openedAriaLabel] ?? '');
    },
    url() {
      // 2026-09-22: LIVE-VERIFIED (Oliver's own probe) -- the main timeline
      // gives each open photo its own distinct URL
      // (".../photo/AF1QipMVKN..." -> ".../AF1QipPnpx..." etc, changing on
      // EVERY ArrowRight), unlike the base library URL. Deriving it from
      // `openedIdentity` means it automatically tracks every place that
      // already mutates that field (openTileInFake, advanceToNextTile,
      // performTrash's auto-advance) with no extra wiring -- exactly what
      // walkTimeline's URL-based advance confirmation (worker.mjs,
      // waitForTimelineAdvanceConfirmed) needs to observe changing.
      if (page.config.timelineTiles != null && photoOpen(page)) {
        return `https://photos.google.com/photo/${encodeURIComponent(page.openedIdentity ?? page.openedAriaLabel)}`;
      }
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
        // (findTile would find it) but that the identity-scoped selector can
        // never resolve -- see the "unreachable tile" test.
        const label = ariaLabelFromSelector(selector);
        if (isUnopenable(page, label)) return 0;
        // 2026-09-22: route to the TIMELINE pool for a TIMELINE_TILE_SELECTOR
        // -- the grid and timeline are two independent tile pools now (see
        // tilesInTimeline's header), never conflated.
        const pool = isTimelineSelector(selector) ? tilesInTimeline(page) : windowedTiles(page);
        return findTile(page, { ariaLabel: label, href: hrefFromSelector(selector) }, pool) ? 1 : 0;
      }
      if (/aria-label="Open info"/i.test(selector)) {
        return page.config.infoButtonFound ? 1 : 0;
      }
      if (/aria-label="Move to trash"/i.test(selector)) {
        return 1;
      }
      if (/aria-label="View next photo"/i.test(selector)) {
        return hasNextPhoto(page) ? 1 : 0;
      }
      if (/has-text\("Move to trash"\)|has-text\("Delete"\)/i.test(selector)) {
        // 2026-09-22: the confirm dialog is now a real modelled state
        // (page.dialogOpen), not permanently absent -- see the '#' key
        // handler's header for why.
        return page.dialogOpen ? 1 : 0;
      }
      return 0;
    },
    allFor(selector) {
      // 2026-09-22: the TIMELINE pool is entirely separate from the grid's
      // (no `activeQuery`, no reorderOnRecollect/recollectCount modelling --
      // no fixture needs those for the timeline yet, and adding them unused
      // would just be speculative surface).
      if (isTimelineSelector(selector)) {
        return tilesInTimeline(page).map(
          (tile, i) => new FakeTileLink(page, typeof tile === 'string' ? tile : tile.ariaLabel, i, typeof tile === 'string' ? undefined : tile.href)
        );
      }
      // moveToTrash's fallback loop (`page.locator(TRASH_SELECTOR).all()`,
      // clicking whichever candidate isVisible()) was previously unmodelled
      // here -- every pre-existing full-harness test's '#' shortcut always
      // succeeded, so the click fallback was only ever exercised via a
      // hand-built page mock (moveToTrash's own direct seam tests), never
      // through createFakePage. A single FakeLocator is enough: its
      // isVisible()/click() already route through the SAME visibleFor/
      // onClick handlers the rest of the trash flow uses.
      if (/aria-label="Move to trash"/i.test(selector)) {
        return photoOpen(page) && page.config.trashButtonVisible !== false ? [new FakeLocator(page, selector)] : [];
      }
      // advancePhotoView's/advanceTimelinePhotoView's own click fallback
      // (and their "no control at all = authoritative end of sequence"
      // check) needs the SAME treatment as TRASH_SELECTOR above -- an
      // empty `.all()` here was previously indistinguishable from
      // "genuinely no more photos", which silently defeated the
      // 2026-09-23 focus-loss recovery pass (it never got a chance to run
      // its own ArrowRight retry because the FIRST attempt's `candidates
      // .length === 0` check fired first, on a day that still had more
      // photos).
      if (/aria-label="View next photo"/i.test(selector)) {
        return hasNextPhoto(page) ? [new FakeLocator(page, selector)] : [];
      }
      if (!selector.includes('./search/')) return [];
      const query = page.activeQuery;
      page.recollectCount[query] = (page.recollectCount[query] ?? 0) + 1;

      let all = windowedTiles(page);

      // Simulates the grid re-rendering tiles in a different order between
      // collections -- worker.mjs must dedupe/track by aria-label, not index.
      if (page.config.reorderOnRecollect?.[query] && page.recollectCount[query] % 2 === 0) {
        all = [...all].reverse();
      }

      return all.map(
        (tile, i) => new FakeTileLink(page, typeof tile === 'string' ? tile : tile.ariaLabel, i, typeof tile === 'string' ? undefined : tile.href)
      );
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
      if (/until permanently deleted/i.test(selector)) {
        // ROUND 10 (2026-09-25, verifyTrashByUrl): the trash-state banner --
        // see page._onTrashedPhotoPage's own header (goto()) for when this
        // is set. Not one-shot like the toast below: a real reload of an
        // already-trashed photo's URL keeps showing this banner on every
        // subsequent read, not just the first.
        return Boolean(page._onTrashedPhotoPage);
      }
      if (/moved to/i.test(selector)) {
        // One-shot: the real toast fades after a moment, and worker.mjs's
        // settled() only needs to catch it once. Clearing here (rather than
        // on a timer) keeps this deterministic for the fake.
        const wasVisible = page.justTrashedToastVisible;
        page.justTrashedToastVisible = false;
        return wasVisible;
      }
      if (isTileIdentitySelector(selector)) {
        // Same "grid is behind the photo view" gating as countFor's identity
        // branch above -- openTile() also calls isVisible() after count(),
        // and both must agree on the tile being unreachable while a photo
        // covers the grid.
        if (photoOpen(page)) return false;
        const label = ariaLabelFromSelector(selector);
        if (isUnopenable(page, label)) return false;
        const pool = isTimelineSelector(selector) ? tilesInTimeline(page) : windowedTiles(page);
        const hit = findTile(page, { ariaLabel: label, href: hrefFromSelector(selector) }, pool);
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
      if (/has-text\("Move to trash"\)|has-text\("Delete"\)/i.test(selector)) {
        // The confirm dialog's own button -- see the '#'/onClick handlers'
        // 2026-09-22 header for why this is now a real modelled state.
        return Boolean(page.dialogOpen);
      }
      return false;
    },
    async onClick(selector) {
      if (/aria-label="Open info"/i.test(selector)) {
        // ROUND 8 (2026-09-25 live finding): the "Open info" button is a
        // TOGGLE just like 'i' -- clicking it while the panel is already
        // open closes it (see the 'i' keyboard handler's identical
        // togglesWhileOpen tracking, above, for the live bug this models).
        // Pre-round-8 this branch only ever modelled a genuinely-closed
        // panel being opened, since no earlier fixture needed the toggle-
        // closes-an-open-panel behaviour exercised via the BUTTON path.
        if (page.infoPanelOpen) {
          page.togglesWhileOpen = (page.togglesWhileOpen ?? 0) + 1;
          page.infoPanelOpen = false;
        } else {
          attemptOpenInfoPanel(page);
        }
      }
      // Toolbar fallback click ALSO only opens the dialog now -- see the '#'
      // handler's comment above. `trashDialogNeverAppears` models the
      // confirmed-live false positive (job B4D8DDA7...): the click resolves
      // (so moveToTrash's fallback loop doesn't error) but Google genuinely
      // never renders a confirm dialog, so nothing should ever count as
      // trashed via this path either.
      if (/aria-label="Move to trash"/i.test(selector) && !page.config.trashDialogNeverAppears) {
        page.dialogOpen = true;
        // `config.timelineFocusLostAfterFallbackClick` (2026-09-23) -- see
        // the '#'/ArrowRight keyboard handler's comment for the live bug
        // this models: a toolbar CLICK (as opposed to the '#' shortcut)
        // leaves keyboard focus off the viewer, so subsequent shortcuts do
        // nothing until a real click (focusViewerCenter) restores it.
        if (page.config.timelineFocusLostAfterFallbackClick) page.focusLost = true;
      }
      if (/has-text\("Move to trash"\)|has-text\("Delete"\)/i.test(selector) && page.dialogOpen) {
        page.dialogOpen = false;
        performTrash(page);
      }
      // "View next photo" toolbar click fallback (advanceTimelinePhotoView's
      // /advancePhotoView's last resort) -- was previously unmodelled since
      // every pre-existing test's ArrowRight always succeeded and the fake
      // never needed this path exercised; the SAME focus-loss flag applies
      // here as the trash control, since it is the identical kind of
      // toolbar click live evidence showed loses focus.
      if (/aria-label="View next photo"/i.test(selector)) {
        advanceToNextTile(page);
        if (page.config.timelineFocusLostAfterFallbackClick) page.focusLost = true;
      }
    },
  };
  return page;
}
