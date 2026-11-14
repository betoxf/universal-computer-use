// JXA backend for ucu's `safari` and `chrome` tools.
//   osascript -l JavaScript browser.js '<json request>'   ->  prints a JSON reply
// A request names its browser ("safari" or "chrome") and addresses a tab as {window_id, tab_index} (1-based index).
// In Safari a chat's tabs are in the user's own windows, where indexes change as the user opens, closes and moves
// tabs, so a request for one of them carries `own`: the tab's mark, where it last was, and what its window held.
// The tab is found again first, and the reply's `own` says where it is now (see ownTab and settle).
// Nothing here activates the browser, except that Chrome comes forward when it makes a window: ucu-window puts the
// user's app back. So a chat's Chrome window is made once, and stays when its tabs close. Operations in a page need
// Allow JavaScript from Apple Events (Safari: Develop menu; Chrome: View > Developer), and every one needs Automation
// access to the browser.
ObjC.import("AppKit");

const BLANK = /^(about:blank|favorites:|chrome:\/\/newtab)/;
const MARK = "ucu-tab";  // where a page's session storage holds the mark of the chat whose tab it is in
const CHUNK = 1 << 20;  // characters of a file's base64 that go to a page at a time

const BROWSERS = {
  safari: {
    app: () => Application("com.apple.Safari"),
    // Safari's Downloads and other panels are windows too, without a document.
    windows: (b) => b.windows().filter((w) => {
      try { return w.document() !== null; } catch (e) { return false; }
    }),
    id: (w) => w.id(),
    minimized: (w) => w.miniaturized(),
    currentIndex: (w) => w.currentTab.index(),
    select: (w, tab) => { w.currentTab = tab; },
    title: (tab) => tab.name(),
    js: (b, tab, code) => b.doJavaScript(code, { in: tab }),
  },
  chrome: {
    app: () => Application("com.google.Chrome"),
    windows: (b) => b.windows(),
    id: (w) => Number(w.id()),
    minimized: (w) => w.minimized(),
    tabId: (tab) => Number(tab.id()),  // Safari's tabs have none
    currentIndex: (w) => w.activeTabIndex(),
    select: (w, tab, index) => { w.activeTabIndex = index; },
    title: (tab) => tab.title(),
    js: (b, tab, code) => b.execute(tab, { javascript: code }),
  },
};

let B = null, browser = null;

function run(argv) {
  const request = JSON.parse(argv[0]);
  try {
    B = BROWSERS[request.browser || "safari"];
    if (!B) throw new Error(`Unknown browser ${request.browser}`);
    browser = B.app();
    const op = (request.browser === "chrome" && CHROME_OPS[request.op])
      || (request.browser === "safari" && SAFARI_OPS[request.op]) || OPS[request.op];
    if (!op) throw new Error(`Unknown operation ${request.op}`);
    if (request.own) {
      request.at = ownTab(request.own);
      request.window_id = B.id(request.at.win);
      request.tab_index = request.at.index;
    }
    const reply = { ok: true, result: op(request) };
    if (request.at) reply.own = settle(request);
    if (request.away) handBack(windowById(request.window_id));
    return JSON.stringify(reply);
  } catch (error) {
    const reply = { ok: false, error: String(error && error.message || error) };
    if (error && error.candidate !== undefined) reply.lost = { candidate: error.candidate };
    return JSON.stringify(reply);
  }
}

function windowById(id) {
  const match = B.windows(browser).find((w) => B.id(w) === id);
  if (!match) throw new Error(`No window with id ${id}`);
  return match;
}

function tabOf(req) {
  const win = windowById(req.window_id);
  const count = win.tabs.length;
  if (!(req.tab_index >= 1 && req.tab_index <= count)) {
    throw new Error(`Window ${req.window_id} has ${count} tab(s); tab_index ${req.tab_index} is out of range`);
  }
  return { win, tab: win.tabs[req.tab_index - 1] };
}

function js(tab, code) {
  return B.js(browser, tab, code);
}

// Run a page-side function with JSON arguments; the function returns a JSON-serialisable value.
function page(tab, fn, args) {
  const code = `(function(){try{return JSON.stringify({v:(${fn})(${JSON.stringify(args || {})})})}catch(e){return JSON.stringify({e:String(e&&e.message||e)})}})()`;
  const raw = js(tab, code);
  if (raw === undefined || raw === null) throw new Error("The page returned nothing (is it still loading, or a non-HTML page?)");
  const reply = JSON.parse(raw);
  if (reply.e) throw new Error(reply.e);
  return reply.v;
}

function urlOf(tab) {
  try { return tab.url(); } catch (e) { return null; }
}

function tabUrls(win) {
  return win.tabs.url().map((url) => url || null);
}

// A value as it is written in script source: JSON, with the characters escaped that JSON leaves alone but that end a
// line or a script there.
const UNSAFE = { "<": "\\u003C", ">": "\\u003E", "/": "\\u002F", "\u2028": "\\u2028", "\u2029": "\\u2029" };
function literal(value) {
  return JSON.stringify(value).replace(/[<>\/\u2028\u2029]/g, (char) => UNSAFE[char]);
}

// A mark lasts while its tab stays on one site: Safari gives each site its own session storage, and clears a
// window's name too when its page goes to another site.
function markOf(tab) {
  try {
    return js(tab, `(function(){try{return sessionStorage.getItem(${literal(MARK)})}catch(e){return null}})()`) || null;
  } catch (e) {
    return null;  // a page that runs no script
  }
}

function stamp(tab, mark) {
  const put = `(function(m){try{sessionStorage.setItem(${literal(MARK)},m)}catch(e){}})(${literal(mark)})`;
  try { js(tab, put); } catch (e) { /* a page that runs no script */ }
}

function lostTab(message, home, candidate) {
  const holds = home ? ` Its window now holds: ${OPS.list({ window_id: B.id(home) })[0].tabs.map((tab) =>
    `${tab.tab_index} ${JSON.stringify(tab.title || "")} ${tab.url || ""}`).join("; ")}.` : "";
  const error = new Error(message + holds);
  error.candidate = candidate;
  return error;
}

// The chat's tab, wherever the user moved it: where it was, or else the tab of its window, or one elsewhere with the
// address it had, that carries its mark. Nothing in the tab shows the user that it is an agent's. When its page went
// to another site the mark is gone. Then it is the tab in its old place if every other tab of the window is as it
// was, and it came there from the chat's page, or the agent says it is its own (`claim`). Anything less proves
// nothing, and the step fails without touching a tab that may be the user's.
function ownTab(own) {
  const windows = B.windows(browser);
  const home = windows.find((w) => B.id(w) === own.window_id) || null;
  const marked = (w, index) => markOf(w.tabs[index - 1]) === own.mark;
  if (home && own.tab_index <= home.tabs.length && marked(home, own.tab_index)) {
    return { win: home, index: own.tab_index, before: tabUrls(home) };
  }
  const last = (own.known || [])[own.tab_index - 1] || null;
  for (const w of home ? [home].concat(windows.filter((other) => other !== home)) : windows) {
    const urls = tabUrls(w);
    for (let index = 1; index <= urls.length; index++) {
      if ((w === home || (last && urls[index - 1] === last)) && marked(w, index)) return { win: w, index, before: urls };
    }
  }
  if (!home) throw lostTab("Your tab can't be found, and its window is gone: `open` the page again.", null, null);
  const urls = tabUrls(home), known = own.known || [];
  const others = urls.length === known.length && urls.every((url, i) => i === own.tab_index - 1 || url === known[i]);
  if (!others) {
    throw lostTab("Your tab can't be found: the user may have closed it, or changed the window's tabs while its page "
      + "went to another site. `open` the page again.", home, null);
  }
  let from = null;
  try { from = js(home.tabs[own.tab_index - 1], "document.referrer"); } catch (e) { /* a page that runs no script */ }
  if (own.claim !== own.tab_index && !(own.origin && from && from.indexOf(own.origin) === 0)) {
    throw lostTab(`Your tab's page went to another site, and nothing proves which tab it is now. Tab ${own.tab_index} `
      + `is where yours was, and shows ${urls[own.tab_index - 1] || "no page"}: if that is the page you expect, pass `
      + `tab_index ${own.tab_index}; if not, it is the user's, and you \`open\` yours again.`, home, own.tab_index);
  }
  return { win: home, index: own.tab_index, before: urls, proven: true };
}

// After a step in a chat's tab, its mark goes back on where the page changed, and the reply says where the tab
// is and what its window holds. A page the step itself loaded is the chat's if the window's other tabs stayed put
// meanwhile, since an index means another tab once the user closes one before it.
function settle(request) {
  const { win, index, before } = request.at, mark = request.own ? request.own.mark : request.mark;
  const tab = win.tabs[index - 1], urls = tabUrls(win);
  let origin = request.own ? request.own.origin || null : null;
  const steady = urls.length === before.length && urls.every((url, i) => i === index - 1 || url === before[i]);
  if (markOf(tab) === mark || ((request.at.loaded || request.at.proven) && steady)) {
    stamp(tab, mark);
    try { origin = js(tab, "location.origin") || origin; } catch (e) { /* a page that runs no script */ }
  }
  return { mark, window_id: B.id(win), tab_index: index, known: urls, origin };
}

// Whether a window is on one of the user's screens, not on an agent's desktop, where a chat's window is for a moment.
function onUsersScreen(win) {
  try {
    const at = win.bounds(), x = at.x + at.width / 2, y = at.y + 10;
    const screens = $.NSScreen.screens, height = screens.objectAtIndex(0).frame.size.height;
    for (let i = 0; i < screens.count; i++) {
      const screen = screens.objectAtIndex(i), frame = screen.frame, top = height - frame.origin.y - frame.size.height;
      if (x >= frame.origin.x && x < frame.origin.x + frame.size.width && y >= top && y < top + frame.size.height) {
        return ObjC.unwrap(screen.localizedName) !== "UCU Agent Desktop";
      }
    }
  } catch (e) { /* window closing */ }
  return false;
}

// The user's windows a chat's tab can join: the one in front first, and those in the Dock last.
function usersWindows() {
  const open = [], docked = [];
  for (const w of B.windows(browser)) {
    let minimized = false, visible = false;
    try { minimized = B.minimized(w); visible = w.visible(); } catch (e) { continue; }
    if (minimized && onUsersScreen(w)) docked.push(w);
    else if (visible && onUsersScreen(w)) open.push(w);
  }
  return open.concat(docked);
}

// While a chat's page is in a window of its own on the agent's desktop, Safari can put a link the user clicks in
// another app there, as a tab beside it, where they would never see it. Such a tab goes to a window of theirs.
function handBack(win) {
  for (let index = win.tabs.length; index >= 2; index--) {
    const url = urlOf(win.tabs[index - 1]), theirs = usersWindows()[0];
    if (url && theirs) theirs.tabs.push(browser.Tab({ url }));
    else if (url) browser.Document({ url }).make();
    win.tabs[index - 1].close();
  }
}

// A new window, found by a mark that tells it from one the user or another chat opens at the same moment.
function newWindow(mark) {
  const url = `about:blank#ucu-${mark}`;
  browser.Document({ url }).make();
  for (let i = 0; i < 200; i++) {
    const win = browser.windows().find((w) => {
      try { return w.currentTab.url() === url; } catch (e) { return false; }
    });
    if (win) return win;
    delay(0.01);
  }
  throw new Error("Safari did not create a window");
}

// The window the user is in, while the browser is the app in front, and null while it isn't.
function usersWindow(except) {
  if (!browser.frontmost()) return null;
  return B.windows(browser).find((w) => w.visible() && B.id(w) !== except) || null;
}

function waitForLoad(tab, previousHref, timeoutSeconds) {
  const deadline = Date.now() + (timeoutSeconds || 20) * 1000;
  while (Date.now() < deadline) {
    try {
      const href = js(tab, "location.href");
      if (href && href !== previousHref && !BLANK.test(href) && js(tab, "document.readyState") === "complete") return true;
    } catch (e) { /* page between documents */ }
    delay(0.1);
  }
  return false;
}

// Chrome says whether a tab is loading, so waiting needs no JavaScript there.
function chromeLoaded(tab, previousHref, timeoutSeconds) {
  const started = Date.now(), deadline = started + (timeoutSeconds || 20) * 1000;
  let seen = false;
  while (Date.now() < deadline) {
    try {
      const url = tab.url() || "";
      if (tab.loading()) seen = true;
      else if (!BLANK.test(url) && (seen || url !== previousHref || Date.now() - started > 1000)) return true;
    } catch (e) { /* tab between documents */ }
    delay(0.1);
  }
  return false;
}

function loaded(tab, previousHref, timeoutSeconds) {
  return B === BROWSERS.chrome ? chromeLoaded(tab, previousHref, timeoutSeconds) : waitForLoad(tab, previousHref, timeoutSeconds);
}

function describe(win, tab, index) {
  let title = null;
  try { title = B.title(tab); } catch (e) {}
  return { window_id: B.id(win), tab_index: index, url: urlOf(tab), title };
}

const OPS = {
  // With window_id, only that window, with where it is and its tabs' ids: for the agent's window while the user has
  // it on their screen, where they move it and change its tabs. With `marks`, the tabs that carry one of them say so:
  // a chat's own tabs among the user's, looked for in the windows it knows them in (`homes`).
  list(req) {
    const one = req.window_id !== undefined, marks = req.marks || [], homes = req.homes || [];
    return B.windows(browser).filter((w) => !one || B.id(w) === req.window_id).map((w) => {
      let current = null;
      try { current = B.currentIndex(w); } catch (e) {}
      const tabs = [];
      const count = w.tabs.length, home = marks.length > 0 && homes.indexOf(B.id(w)) >= 0;
      for (let i = 0; i < count; i++) {
        const tab = describe(w, w.tabs[i], i + 1);
        if (one && B.tabId) tab.id = B.tabId(w.tabs[i]);
        const mark = home ? markOf(w.tabs[i]) : null;
        if (marks.indexOf(mark) >= 0) Object.assign(tab, { yours: true, mark });
        tabs.push(tab);
      }
      const found = { window_id: B.id(w), visible: w.visible(), current_tab_index: current, tabs };
      if (one) found.bounds = w.bounds();
      return found;
    });
  },

  // Create a hidden window (no focus change; the window can flash for a moment when created).
  create_window(req) {
    const win = newWindow(req.mark);
    win.visible = false;
    return { window_id: win.id() };
  },

  // Open a URL in a new tab at the end of a window, or in its only tab while that is blank.
  open_tab(req) {
    const win = windowById(req.window_id);
    let tab, index;
    const count = win.tabs.length;
    const first = count === 1 ? win.tabs[0] : null;
    const firstUrl = first ? urlOf(first) : null;
    if (req.reuse_blank && first && (!firstUrl || BLANK.test(firstUrl))) {
      tab = first; index = 1;
      tab.url = req.url;
    } else {
      win.tabs.push(browser.Tab({ url: req.url }));
      index = win.tabs.length;
      tab = win.tabs[index - 1];
    }
    const done = req.wait === false ? null : loaded(tab, null, req.timeout_seconds);
    return Object.assign(describe(win, tab, index), { loaded: done });
  },

  navigate(req) {
    const { win, tab } = tabOf(req);
    let previous = null;
    try { previous = B === BROWSERS.chrome ? tab.url() : js(tab, "location.href"); } catch (e) {}
    tab.url = req.url;
    const done = req.wait === false ? null : loaded(tab, previous === req.url ? null : previous, req.timeout_seconds);
    return Object.assign(describe(win, tab, req.tab_index), { loaded: done });
  },

  // The agent's window outlives its last tab: making another shows for a moment, and brings Chrome forward.
  close_tab(req) {
    const { win, tab } = tabOf(req);
    if (req.keep_window && win.tabs.length === 1) return OPS.clear_window(req);
    tab.close();
    return { closed: true };
  },

  // Close the agent's tabs but keep its window, with one blank tab for the next page.
  clear_window(req) {
    const win = windowById(req.window_id);
    win.tabs.push(B === BROWSERS.chrome ? browser.Tab() : browser.Tab({ url: "about:blank" }));
    for (let i = win.tabs.length - 2; i >= 0; i--) win.tabs[i].close();
    return { closed: true, blank: true };
  },

  close_window(req) {
    const win = windowById(req.window_id);
    win.close();
    return { closed: true };
  },

  // Show a hidden window on the agent's desktop. While the user is in the browser, that takes their keyboard, so the
  // window they are in gets it back right away. Behind another app there is no keyboard to take, and bringing their
  // window forward would lift it over the other apps' windows.
  show_window(req) {
    const win = windowById(req.window_id);
    const theirs = usersWindow(req.window_id);
    win.bounds = req.bounds;
    win.visible = true;
    if (theirs) theirs.index = 1;
    return { shown: true };
  },

  // After a turn the window goes out of sight, unless it has left the agent's desktop: then the user has it. It also
  // goes out of sight when the agent takes it back from the user's screen.
  hide_window(req) {
    const win = windowById(req.window_id);
    const at = win.bounds();
    if (req.only_at && (Math.abs(at.x - req.only_at.x) > 4 || Math.abs(at.y - req.only_at.y) > 4)) {
      return { hidden: false, moved: true };
    }
    win.visible = false;
    return { hidden: true };
  },

  // The user asked to see the agent's tab: its window comes to their screen, the one with the menu bar, in front.
  // They can use it there, and the agent keeps working in it, as its tabs need no window in front.
  show_to_user(req) {
    const { win, tab } = tabOf(req);
    if (B.currentIndex(win) !== req.tab_index) B.select(win, tab, req.tab_index);
    const screen = $.NSScreen.screens.objectAtIndex(0), full = screen.frame, area = screen.visibleFrame;
    const width = Math.min(1280, area.size.width - 80), height = Math.min(900, area.size.height - 80);
    win.bounds = { x: area.origin.x + 40, y: full.size.height - area.origin.y - area.size.height + 40, width, height };
    win.visible = true;
    win.index = 1;
    browser.activate();
    return { shown: true };
  },

  // Where a tab is and whether its window shows it now, which a screenshot of it needs.
  locate(req) {
    const { win, tab } = tabOf(req);
    return Object.assign(describe(win, tab, req.tab_index), {
      current: B.currentIndex(win) === req.tab_index, visible: win.visible(), minimized: B.minimized(win),
      bounds: win.bounds() });
  },

  // The user asked to see a chat's tab in their window: it becomes the tab in front, of the window and app in front.
  show_tab(req) {
    const { win, tab } = tabOf(req);
    if (B.minimized(win)) win.miniaturized = false;
    if (B.currentIndex(win) !== req.tab_index) B.select(win, tab, req.tab_index);
    win.index = 1;
    browser.activate();
    return { shown: true };
  },

  // A screenshot shows a window's current tab. Only the agent's own window gets here.
  select_tab(req) {
    const { win, tab } = tabOf(req);
    const changed = B.currentIndex(win) !== req.tab_index;
    if (changed) B.select(win, tab, req.tab_index);
    return { changed };
  },

  eval(req) {
    const { tab } = tabOf(req);
    return page(tab, `function(){ ${req.script} }`, {});
  },

  read(req) {
    const { win, tab } = tabOf(req);
    const result = page(tab, function (a) {
      const root = a.selector ? document.querySelector(a.selector) : document.body || document.documentElement;
      if (!root) throw new Error("No element matches " + a.selector);
      const clip = (s) => (s.length > a.max_chars ? s.slice(0, a.max_chars) + "\n[truncated]" : s);
      if (a.what === "html") return clip(root.outerHTML);
      if (a.what === "links") {
        return Array.from(root.querySelectorAll("a[href]")).slice(0, 500)
          .map((el) => ({ text: (el.innerText || el.title || "").trim().slice(0, 120), href: el.href }));
      }
      if (a.what === "interactive") {
        const selector = "a[href],button,input,select,textarea,summary,[role=button],[role=link],[role=checkbox],[role=tab],[role=menuitem],[contenteditable=true],[onclick]";
        const out = [];
        let n = 0;
        for (const el of root.querySelectorAll(selector)) {
          const style = getComputedStyle(el);
          // Pages often hide their file input behind a button of their own; `upload` still needs it.
          if ((style.display === "none" || style.visibility === "hidden") && el.type !== "file" || el.disabled) continue;
          const id = "c" + (++n);
          el.setAttribute("data-ucu-ref", id);
          out.push({
            ref: id, tag: el.tagName.toLowerCase(), type: el.type || el.getAttribute("role") || undefined,
            text: (el.innerText || el.value || el.getAttribute("aria-label") || el.placeholder || el.title || el.name || "").trim().slice(0, 100),
            href: el.href || undefined,
          });
          if (out.length >= 300) break;
        }
        return out;
      }
      return clip((root.innerText || "").replace(/\n{3,}/g, "\n\n"));
    }, { what: req.what || "text", selector: req.selector || null, max_chars: req.max_chars || 20000 });
    return Object.assign(describe(win, tab, req.tab_index), { content: result });
  },

  click(req) {
    const { tab } = tabOf(req);
    return page(tab, function (a) {
      let el = null;
      if (a.ref) el = document.querySelector(`[data-ucu-ref="${a.ref}"]`);
      else if (a.selector) el = document.querySelector(a.selector);
      else if (a.text) {
        const want = a.text.trim().toLowerCase();
        const candidates = document.querySelectorAll("a,button,input[type=submit],input[type=button],[role=button],[role=link],summary,label");
        el = Array.from(candidates).find((c) => (c.innerText || c.value || "").trim().toLowerCase() === want)
          || Array.from(candidates).find((c) => (c.innerText || c.value || "").trim().toLowerCase().includes(want));
      }
      if (!el) throw new Error("No element found for " + JSON.stringify(a));
      el.scrollIntoView({ block: "center" });
      const r = el.getBoundingClientRect();
      const at = { bubbles: true, cancelable: true, view: window, clientX: r.x + r.width / 2, clientY: r.y + r.height / 2 };
      for (const type of ["pointerdown", "mousedown", "pointerup", "mouseup"]) {
        el.dispatchEvent(type.startsWith("pointer") ? new PointerEvent(type, at) : new MouseEvent(type, at));
      }
      el.click();
      return { clicked: el.tagName.toLowerCase(), text: (el.innerText || el.value || "").trim().slice(0, 100) };
    }, { ref: req.ref || null, selector: req.selector || null, text: req.text || null });
  },

  type(req) {
    const { tab } = tabOf(req);
    return page(tab, function (a) {
      const el = a.ref ? document.querySelector(`[data-ucu-ref="${a.ref}"]`) : document.querySelector(a.selector);
      if (!el) throw new Error("No element found for " + (a.ref || a.selector));
      el.focus();
      if (el.isContentEditable) {
        if (a.clear) el.textContent = "";
        el.textContent += a.text;
        el.dispatchEvent(new InputEvent("input", { bubbles: true, data: a.text, inputType: "insertText" }));
      } else {
        const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : el instanceof HTMLSelectElement ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
        const setter = Object.getOwnPropertyDescriptor(proto, "value").set;  // works with React-controlled inputs
        setter.call(el, (a.clear ? "" : el.value) + a.text);
        el.dispatchEvent(new InputEvent("input", { bubbles: true, data: a.text, inputType: "insertText" }));
        el.dispatchEvent(new Event("change", { bubbles: true }));
      }
      if (a.submit) {
        const key = { key: "Enter", code: "Enter", keyCode: 13, which: 13, bubbles: true, cancelable: true };
        const proceed = el.dispatchEvent(new KeyboardEvent("keydown", key));
        el.dispatchEvent(new KeyboardEvent("keyup", key));
        if (proceed && el.form) { el.form.requestSubmit ? el.form.requestSubmit() : el.form.submit(); }
      }
      return { typed: a.text.length, value: el.isContentEditable ? el.textContent.slice(0, 200) : String(el.value).slice(0, 200) };
    }, { ref: req.ref || null, selector: req.selector || null, text: req.text, clear: req.clear !== false, submit: !!req.submit });
  },

  // Give a page local files without its file picker, which needs the browser in front: they go into a file input as
  // if chosen there, or are dropped on any other element, such as a drop zone. The files are read here, so their
  // contents never pass through the command line, and go to the page in pieces.
  upload(req) {
    const { tab } = tabOf(req);
    js(tab, "window.__ucuFiles = []");
    req.files.forEach((file, index) => {
      const data = $.NSData.dataWithContentsOfFile($(file.path));
      if (!data || data.isNil()) throw new Error(`Can't read ${file.path}`);
      const text = data.base64EncodedStringWithOptions(0).js;
      js(tab, `window.__ucuFiles[${index}] = ''`);
      for (let at = 0; at < text.length; at += CHUNK) {
        js(tab, `window.__ucuFiles[${index}] += '${text.slice(at, at + CHUNK)}'`);
      }
    });
    return page(tab, function (a) {
      const el = a.ref ? document.querySelector(`[data-ucu-ref="${a.ref}"]`) : document.querySelector(a.selector || "input[type=file]");
      if (!el) throw new Error("No element found for " + (a.ref || a.selector || "input[type=file]"));
      const transfer = new DataTransfer();
      a.files.forEach((file, index) => {
        const raw = atob(window.__ucuFiles[index]);
        const bytes = new Uint8Array(raw.length);
        for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
        transfer.items.add(new File([bytes], file.name, { type: file.type }));
      });
      delete window.__ucuFiles;
      const names = a.files.map((file) => file.name);
      if (el instanceof HTMLInputElement && el.type === "file") {
        el.files = transfer.files;
        el.dispatchEvent(new Event("input", { bubbles: true }));
        el.dispatchEvent(new Event("change", { bubbles: true }));
        return { uploaded: names, into: "input", accept: el.accept || undefined };
      }
      for (const type of ["dragenter", "dragover", "drop"]) {
        el.dispatchEvent(new DragEvent(type, { bubbles: true, cancelable: true, dataTransfer: transfer }));
      }
      return { uploaded: names, into: "drop" };
    }, { ref: req.ref || null, selector: req.selector || null, files: req.files.map((f) => ({ name: f.name, type: f.type })) });
  },

  wait_for(req) {
    const { tab } = tabOf(req);
    const deadline = Date.now() + (req.timeout_seconds || 10) * 1000;
    while (Date.now() < deadline) {
      try {
        const found = page(tab, function (a) {
          if (a.selector) return !!document.querySelector(a.selector);
          return (document.body && document.body.innerText || "").includes(a.text);
        }, { selector: req.selector || null, text: req.text || null });
        if (found) return { found: true };
      } catch (e) { /* navigating */ }
      delay(0.2);
    }
    return { found: false };
  },
};

// Where Chrome differs: its window ids are numbers in text, and making a window brings it forward and shows it where
// the user is, so it goes straight to the agent's desktop, or out of sight. Setting a tab's address brings Chrome
// forward too, so a tab is made without one and goes to its page through the page itself, when the page lets ucu run
// JavaScript. When it doesn't, the caller hears that the address has to be set, and asks for that with `typed` once
// ucu-window knows Chrome is about to come forward, or has ucu's extension set it, which keeps Chrome behind, and
// says `sent`.
function chromeGo(tab, url, typed) {
  const previous = urlOf(tab);
  if (typed) {
    tab.url = url;
    return { previous, went: true };
  }
  let asked = false;
  try { js(tab, `location.assign(${JSON.stringify(url)})`); asked = true; } catch (e) { /* no JavaScript here */ }
  // A page can refuse, such as one of Chrome's own.
  const until = Date.now() + 1500;
  while (asked && Date.now() < until && urlOf(tab) === previous && !tab.loading()) delay(0.05);
  return { previous, went: asked && !(urlOf(tab) === previous && !tab.loading() && previous !== url) };
}

const SAFARI_OPS = {
  // Open a URL in a tab of the chat's own, at the end of a window of the user's and behind the tab they are on: the
  // window the chat's last tab is in, or the one in front. With no window of theirs, Safari gets one, as it would at
  // a click on a link in another app, but without coming forward.
  open_tab(req) {
    let win = (req.near !== undefined && B.windows(browser).find((w) => B.id(w) === req.near)) || usersWindows()[0];
    let index = 1, before = [null];
    if (win) {
      before = tabUrls(win).concat([null]);
      win.tabs.push(browser.Tab({ url: req.url }));
      index = win.tabs.length;
    } else {
      win = newWindow(req.mark);
      win.tabs[0].url = req.url;
    }
    const tab = win.tabs[index - 1];
    const done = req.wait === false ? null : loaded(tab, null, req.timeout_seconds);
    req.at = { win, index, before, loaded: true };
    return Object.assign(describe(win, tab, index), { loaded: done });
  },

  navigate(req) {
    if (req.at) req.at.loaded = true;
    return OPS.navigate(req);
  },

  close_tab(req) {
    const { tab } = tabOf(req);
    tab.close();
    req.at = null;  // nothing left to mark
    return { closed: true };
  },
};

const CHROME_OPS = {
  open_tab(req) {
    const win = windowById(req.window_id);
    const first = win.tabs.length === 1 ? win.tabs[0] : null;
    let tab, index;
    if (req.reuse_blank && first && BLANK.test(urlOf(first) || "about:blank")) {
      tab = first; index = 1;
    } else {
      win.tabs.push(browser.Tab());
      index = win.tabs.length;
      tab = win.tabs[index - 1];
    }
    const { previous, went } = chromeGo(tab, req.url, false);
    if (!went) return { window_id: req.window_id, tab_index: index, typed: true, previous };
    const done = req.wait === false ? null : loaded(tab, null, req.timeout_seconds);
    return Object.assign(describe(win, tab, index), { loaded: done });
  },

  navigate(req) {
    const { win, tab } = tabOf(req);
    const { previous, went } = req.sent ? { previous: req.previous, went: true } : chromeGo(tab, req.url, req.typed);
    if (!went) return { window_id: req.window_id, tab_index: req.tab_index, typed: true, previous };
    const done = req.wait === false ? null : loaded(tab, previous === req.url ? null : previous, req.timeout_seconds);
    return Object.assign(describe(win, tab, req.tab_index), { loaded: done });
  },

  create_window(req) {
    const before = new Set(browser.windows().map((w) => w.id()));
    const theirs = usersWindow(null);  // the new window takes their keyboard, so they get it back below
    // Given with the window, the place applies before Chrome draws it where the user is.
    let failure = null;
    try { browser.Window(req.bounds ? { bounds: req.bounds } : { visible: false }).make(); } catch (e) { failure = e; }
    let win = null;
    for (let i = 0; i < 200 && !win; i++) {
      const made = browser.windows().filter((w) => !before.has(w.id()));
      win = made.length ? made[0] : null;  // the front one first: the one just made, if another chat made one too
      if (!win) delay(0.01);
    }
    if (!win) throw failure || new Error("Chrome did not create a window");
    if (req.bounds) win.bounds = req.bounds;
    else win.visible = false;
    if (theirs) theirs.index = 1;
    return { window_id: Number(win.id()) };
  },
};
