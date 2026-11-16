// 컴퓨터용 다이어리 앱 껍데기 (Electron): 창 테두리·배경 없이 책만 화면에 띄움.
// 내용은 실제 사이트를 그대로 불러오므로, 사이트를 고치면 이 앱에도 바로 반영됨.
// 책만 보이게 하는 모양(투명 배경, 끌기 손잡이, 닫기 버튼, 양옆 넘기기)은 index.html 의 .shell 규칙이 맡음.
// 설치: 이 폴더(main.js, package.json)와 favicon.ico(icon.ico 로)를 %LOCALAPPDATA%\DiaryApp 에 복사하고 거기서 `npm install electron`.
//       (OneDrive 안에 node_modules 를 두지 않으려고 따로 둠)
const { app, BrowserWindow, screen, shell } = require('electron');
const path = require('path');
const fs = require('fs');
const SITE = process.env.DIARY_URL || 'https://chittang08.github.io/-diary/';   // DIARY_URL: 미리보기 서버로 시험할 때만

// 시험 계정으로 항상 로그인 (선택): 실행할 때 --as=a 나 --as=b 를 주고 같은 폴더에 accounts.json 이 있으면 그 계정으로 로그인해 둠.
// accounts.json({ a:{email,password}, b:{…} })은 이 컴퓨터에만 두고 git 에는 올리지 않음.
// 계정마다 저장 공간을 따로 써서 두 계정을 동시에 띄울 수 있음.
const AS = app.commandLine.getSwitchValue('as');
let account = null;
if (AS) {
  try { account = JSON.parse(fs.readFileSync(path.join(__dirname, 'accounts.json'), 'utf8'))[AS] || null; }
  catch (e) { console.error('accounts.json 을 못 읽음:', e.message); }
  app.setPath('userData', app.getPath('userData') + '-' + AS);
}

app.setAppUserModelId('diary.desktop' + (AS ? '.' + AS : ''));
if (!app.requestSingleInstanceLock()) app.quit();   // 이미 떠 있으면 새로 띄우지 않음
else {
  let win = null;
  app.on('second-instance', () => { if (win) { if (win.isMinimized()) win.restore(); win.focus(); } });
  app.whenReady().then(() => {
    // 창을 책 크기에 딱 맞춤: 높이는 화면에 맞추고, 너비는 책 비율(0.74) + 스프링·책갈피 여백 (index.html 의 .shell 과 같은 숫자)
    const h = Math.min(screen.getPrimaryDisplay().workAreaSize.height - 40, 960);
    const w = Math.round((h - 54) * 0.74) + 74;
    win = new BrowserWindow({
      width: w, height: h, useContentSize: true, title: '다이어리',
      frame: false, transparent: true, hasShadow: false,
      resizable: false, maximizable: false, fullscreenable: false,
      icon: path.join(__dirname, 'icon.ico'),
    });
    if (AS === 'b') { const [x, y] = win.getPosition(); win.setPosition(x + 140, y); }   // 둘을 같이 띄웠을 때 완전히 겹치지 않게
    win.loadURL(SITE);
    if (account) win.webContents.on('did-finish-load', () => {
      // 다른 계정이거나 로그아웃 상태면 정해진 계정으로 다시 로그인 (.claude/dev-login.js 와 같은 방식)
      win.webContents.executeJavaScript(`(async () => {
        if (!window.sb) return;
        const want = ${JSON.stringify({ email: account.email, password: account.password })};
        const cur = (await sb.auth.getSession()).data.session;
        if (cur && cur.user.email === want.email) return;
        if (cur) await sb.auth.signOut({ scope: 'local' });
        const r = await sb.auth.signInWithPassword(want);
        if (r.error) console.warn('자동 로그인 실패:', r.error.message);
      })()`).catch(() => {});
    });
    // 다이어리 밖으로 나가는 링크는 이 창이 아니라 평소 쓰는 브라우저에서 열림
    const outside = (url) => !url.startsWith(SITE);
    const openOutside = (url) => { if (/^https?:/.test(url)) shell.openExternal(url); };
    win.webContents.setWindowOpenHandler(({ url }) => { if (outside(url)) openOutside(url); return { action: 'deny' }; });
    win.webContents.on('will-navigate', (e, url) => { if (outside(url)) { e.preventDefault(); openOutside(url); } });
  });
  app.on('window-all-closed', () => app.quit());
}
