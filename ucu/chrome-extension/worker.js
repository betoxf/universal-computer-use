// UCU's companion in Chrome. AppleScript, which UCU drives Chrome with, brings Chrome forward when it makes a window
// or sets a tab's address. The extension API does neither, so those two steps come here: from each chat's
// ucu-proxy.py, through the native messaging host scripts/ucu-chrome-host.py, which `ucu install` registers.
// Everything else stays on AppleScript, which sees these windows and tabs under the same ids.
const HOST = "com.ucu.companion";
const SETTLED = 5000;  // ms a connection has to last for a lost one to be worth making again

const OPS = {
  // A window made unfocused doesn't come forward, and one made with its place is never drawn anywhere else.
  async create_window(request) {
    const { x, y, width, height } = request.bounds;
    const made = await chrome.windows.create({ url: "about:blank", focused: false, left: x, top: y, width, height });
    return { window_id: made.id };
  },

  async navigate(request) {
    const [tab] = await chrome.tabs.query({ windowId: request.window_id, index: request.tab_index - 1 });
    if (!tab) throw new Error(`Window ${request.window_id} has no tab ${request.tab_index}`);
    await chrome.tabs.update(tab.id, { url: request.url });
    return { went: true };
  },
};

async function answer(request) {
  try {
    if (!OPS[request.op]) throw new Error(`Unknown operation ${request.op}`);
    return { id: request.id, ok: true, result: await OPS[request.op](request) };
  } catch (error) {
    return { id: request.id, ok: false, error: String(error && error.message || error) };
  }
}

// The open connection keeps this worker running. Without the host there is none, and UCU works as it does without
// the extension, until Chrome or the extension starts again.
function connect() {
  const port = chrome.runtime.connectNative(HOST), since = Date.now();
  port.onMessage.addListener(async (request) => {
    const reply = await answer(request);
    try { port.postMessage(reply); } catch (error) { /* the host went away meanwhile */ }
  });
  port.onDisconnect.addListener(() => {
    void chrome.runtime.lastError;
    if (Date.now() - since > SETTLED) setTimeout(connect, 1000);
  });
}

// Listening for these starts the worker with Chrome, and when the extension is loaded.
chrome.runtime.onStartup.addListener(() => {});
chrome.runtime.onInstalled.addListener(() => {});
connect();
