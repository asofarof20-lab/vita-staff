const { app, BrowserWindow, shell } = require('electron');
const { URL } = require('node:url');
const path = require('node:path');
const APP_URL = 'https://asofarof20-lab.github.io/vita-staff/';

function showConnectionError(win) {
  if (win.isDestroyed()) return;
  const html = '<!doctype html><html lang="ru"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>VITANET</title><body style="margin:0;background:#f5f1e9;color:#263b31;font:16px Arial;display:grid;min-height:100vh;place-items:center"><main style="max-width:520px;padding:32px;text-align:center"><h2>Не удалось подключиться к VITANET</h2><p>Проверьте подключение к интернету и повторите попытку.</p><button onclick="location.href=\'' + APP_URL + '\'" style="padding:12px 24px;background:#24563e;color:white;border:0;border-radius:8px;font-size:16px">Повторить</button></main></body></html>';
  win.loadURL('data:text/html;charset=utf-8,' + encodeURIComponent(html));
}

function createWindow() {
  const win = new BrowserWindow({
    width: 1180, height: 800, minWidth: 760, minHeight: 540, show: false,
    backgroundColor: '#f5f1e9', autoHideMenuBar: true, title: 'VITANET',
    icon: path.join(__dirname, 'vitanet.ico'),
    webPreferences: { contextIsolation: true, nodeIntegration: false, sandbox: true }
  });
  win.once('ready-to-show', () => win.show());
  win.webContents.setWindowOpenHandler(({ url }) => {
    // VITANET opens an about:blank child window to build printable invoices.
    // Keep that window inside Electron so window.print() reaches the OS printer dialog.
    if (url === 'about:blank' || url.startsWith('about:blank#')) {
      return {
        action: 'allow',
        overrideBrowserWindowOptions: {
          width: 900,
          height: 700,
          autoHideMenuBar: true,
          webPreferences: {
            contextIsolation: true,
            nodeIntegration: false,
            sandbox: true
          }
        }
      };
    }
    try { const target = new URL(url); if (target.protocol === 'https:') shell.openExternal(url); } catch (_) {}
    return { action: 'deny' };
  });
  win.webContents.on('did-fail-load', (_event, errorCode, _description, _url, isMainFrame) => {
    if (isMainFrame && errorCode !== -3) showConnectionError(win);
  });
  win.loadURL(APP_URL).catch(() => showConnectionError(win));
}
app.whenReady().then(() => {
  createWindow();
  app.on('activate', () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });
});
app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
