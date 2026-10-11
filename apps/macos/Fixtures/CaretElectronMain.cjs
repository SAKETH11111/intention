// Runs only the local synthetic page passed by the guarded caret lab.
const { app, BrowserWindow, session } = require('electron');
const path = require('node:path');
const fs = require('node:fs');
const { pathToFileURL } = require('node:url');
const args = process.argv;
const value = key => args[args.indexOf(key) + 1];
const page = value('--fixture-page');
const output = value('--fixture-output');
const title = value('--fixture-title');
if (!args.includes('--fixture-page') || !args.includes('--fixture-output') ||
    !/^Intention caret lab [0-9A-F-]{36} electron-/i.test(title || '') ||
    !path.isAbsolute(page) || !path.isAbsolute(output) || path.dirname(page) !== output ||
    !fs.existsSync(page)) process.exit(2);
const state = stage => fs.writeFileSync(path.join(output, 'electron-runtime.json'), JSON.stringify({stage, pid: process.pid, electron: process.versions.electron, chrome: process.versions.chrome}));
state('arguments-accepted');
app.setName('Intention Electron Fixture');
app.setPath('userData', path.join(output, 'electron-profile'));
app.setPath('sessionData', path.join(output, 'electron-session'));
app.setPath('crashDumps', path.join(output, 'electron-crashes'));
app.commandLine.appendSwitch('disable-background-networking');
app.commandLine.appendSwitch('disable-component-update');
const url = pathToFileURL(page).href;
app.whenReady().then(async () => {
  state('app-ready');
  session.defaultSession.webRequest.onBeforeRequest({ urls: ['http://*/*', 'https://*/*', 'ws://*/*', 'wss://*/*'] }, (_, callback) => callback({ cancel: true }));
  session.defaultSession.setPermissionRequestHandler((_, __, callback) => callback(false));
  app.setAccessibilitySupportEnabled(true);
  const window = new BrowserWindow({ width: 600, height: 360, x: 180, y: 220, title,
    show: false, webPreferences: { nodeIntegration: false, contextIsolation: true, sandbox: true } });
  window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  window.webContents.on('will-navigate', (event, target) => { if (target !== url) event.preventDefault(); });
  await window.loadURL(url);
  state('page-loaded');
  // Build smoke check starts a renderer but never shows or focuses a window.
  if (args.includes('--fixture-smoke')) {
    // Inspect only the local page built for this process. No window, input
    // event or screen capture is needed to verify the real editor mounted.
    const result = await window.webContents.executeJavaScript(`new Promise(resolve => {
      const deadline = performance.now() + 3000;
      const check = () => {
        const field = document.getElementById('field');
        if ((!field?.isContentEditable || !field.getAttribute('aria-label')) && performance.now() < deadline) {
          setTimeout(check, 20); return;
        }
        resolve({ framework: document.body.dataset.engine || 'plain',
          editable: field?.isContentEditable === true,
          receipt: field?.getAttribute('aria-label') || null,
          focused: document.activeElement === field,
          networkResources: performance.getEntriesByType('resource').filter(e => /^https?:/.test(e.name)).length });
      };
      check();
    })`);
    fs.writeFileSync(path.join(output, 'editor-smoke.json'), JSON.stringify(result));
    if (!result.editable || !result.receipt?.startsWith('Intention fixture keys=') || result.networkResources !== 0) process.exitCode = 1;
    app.quit(); return;
  }
  window.show(); window.focus(); app.focus({ steal: true });
  state('shown');
  setTimeout(() => app.quit(), 90000);
}).catch(error => { state('failed-' + error.name); app.quit(); });
app.on('window-all-closed', () => app.quit());
