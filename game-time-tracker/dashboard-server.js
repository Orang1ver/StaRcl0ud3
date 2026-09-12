const http = require('http');
const fs = require('fs');
const path = require('path');
const { spawnSync, spawn } = require('child_process');

const PORT = 8770;
function detectRoot() {
  if (process.pkg) return path.dirname(process.execPath);
  try {
    if (require('node:sea').isSea()) return path.dirname(process.execPath);
  } catch (e) { /* normal node run */ }
  return __dirname;
}
const ROOT = detectRoot();
const CSV_FILE = path.join(ROOT, 'activity.csv');
const HTML_FILE = path.join(ROOT, 'dashboard.html');
const AVATAR_DIR = path.join(ROOT, 'avatars');
const GAME_LIST_FILE = path.join(ROOT, 'games.txt');
const CUSTOM_FILE = path.join(ROOT, 'games.json');
const LOG_FILE = path.join(ROOT, 'tracker.log');

// 记录器和看门任务都会写这个日志；排查「为什么今天没记上」先看它
const LOG_CRLF = String.fromCharCode(13) + String.fromCharCode(10);
const LOG_CR = String.fromCharCode(13);
const LOG_LF = String.fromCharCode(10);
const LOG_SPLIT = new RegExp(LOG_CR + '?' + LOG_LF);

function logTracker(msg) {
  try {
    const line = new Date().toLocaleString('zh-CN', { hour12: false }) + '  ' + msg;
    fs.appendFileSync(LOG_FILE, line + LOG_CRLF, 'utf8');
    const size = fs.statSync(LOG_FILE).size;
    if (size > 200 * 1024) {
      const parts = fs.readFileSync(LOG_FILE, 'utf8').split(LOG_SPLIT);
      fs.writeFileSync(LOG_FILE, parts.slice(-200).join(LOG_CRLF), 'utf8');
    }
  } catch (e) { /* 日志写不了也不能影响统计 */ }
}

const GAME_NAMES = {
  yuanshen: '原神',
  genshinimpact: '原神',
  starrail: '崩坏：星穹铁道',
  zenlesszonezero: '绝区零',
  minecraft: '我的世界'
};

const BUILTIN_AVATAR = {
  yuanshen: 'genshin.png',
  genshinimpact: 'genshin.png',
  starrail: 'starrail.png',
  zenlesszonezero: 'zzz.png',
  minecraft: 'minecraft.png'
};

function splitCsvLine(line) {
  const out = [];
  let cur = '';
  let quoted = false;
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (quoted) {
      if (ch === '"') {
        if (line[i + 1] === '"') { cur += '"'; i++; }
        else quoted = false;
      } else cur += ch;
    } else if (ch === '"') {
      quoted = true;
    } else if (ch === ',') {
      out.push(cur);
      cur = '';
    } else {
      cur += ch;
    }
  }
  out.push(cur);
  return out;
}

function readRows() {
  if (!fs.existsSync(CSV_FILE)) return [];
  const text = fs.readFileSync(CSV_FILE, 'utf8').replace(/^\uFEFF/, '');
  const rows = [];
  const lines = text.split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line) continue;
    const parts = splitCsvLine(line);
    if (parts.length < 3) continue;
    if (!/^\d{4}-\d{2}-\d{2}/.test(parts[0])) continue;
    const start = new Date(parts[0].replace(' ', 'T'));
    const end = new Date(parts[1].replace(' ', 'T'));
    if (isNaN(start.getTime()) || isNaN(end.getTime())) continue;
    const minutes = (end - start) / 60000;
    if (minutes <= 0) continue;
    rows.push({ process: (parts[2] || 'unknown').toLowerCase(), start, end, minutes });
  }
  return rows;
}

function readCustomGames() {
  if (!fs.existsSync(CUSTOM_FILE)) return {};
  try {
    const parsed = JSON.parse(fs.readFileSync(CUSTOM_FILE, 'utf8'));
    return parsed && typeof parsed === 'object' ? parsed : {};
  } catch (e) {
    return {};
  }
}

function getDisplayName(processName, custom) {
  if (GAME_NAMES[processName]) return GAME_NAMES[processName];
  const c = custom[processName];
  return (c && c.name) || processName;
}

function getAvatarUrl(processName, custom) {
  const c = custom[processName];
  if (c && c.avatar) return '/avatars/' + c.avatar;
  const builtin = BUILTIN_AVATAR[processName];
  return builtin ? '/avatars/' + builtin : '';
}

function readConfiguredGames(custom) {
  if (!fs.existsSync(GAME_LIST_FILE)) return [];
  const lines = fs.readFileSync(GAME_LIST_FILE, 'utf8').split(/\r?\n/);
  const order = [];
  const groups = new Map();
  for (const raw of lines) {
    const processName = raw.trim().toLowerCase();
    if (!processName || processName.startsWith('#')) continue;
    const gameName = getDisplayName(processName, custom);
    if (!groups.has(gameName)) {
      const item = { process: processName, name: gameName, aliases: [], avatar: getAvatarUrl(processName, custom) };
      groups.set(gameName, item);
      order.push(item);
    }
    const item = groups.get(gameName);
    if (!item.aliases.includes(processName)) item.aliases.push(processName);
  }
  return order.map(item => ({
    process: item.process,
    name: item.name,
    avatar: item.avatar,
    aliases: item.aliases.length > 1 ? item.aliases.join(' / ') : ''
  }));
}

function dayKey(date) {
  return date.getFullYear() + '-' +
    String(date.getMonth() + 1).padStart(2, '0') + '-' +
    String(date.getDate()).padStart(2, '0');
}

function hm(date) {
  return String(date.getHours()).padStart(2, '0') + ':' + String(date.getMinutes()).padStart(2, '0');
}

function buildSessions(rows, custom, minMinutes) {
  const byProcess = new Map();
  for (const row of rows) {
    if (!byProcess.has(row.process)) byProcess.set(row.process, []);
    byProcess.get(row.process).push(row);
  }
  const sessions = [];
  for (const list of byProcess.values()) {
    list.sort((a, b) => a.start - b.start);
    let current = null;
    for (const row of list) {
      if (current && (row.start - current.end) <= 120000) {
        if (row.end > current.end) current.end = row.end;
        current.minutes += row.minutes;
      } else {
        current = {
          process: row.process,
          name: getDisplayName(row.process, custom),
          avatar: getAvatarUrl(row.process, custom),
          start: row.start,
          end: row.end,
          minutes: row.minutes
        };
        sessions.push(current);
      }
    }
  }
  const keepAbove = Number(minMinutes);
  if (!Number.isFinite(keepAbove) || keepAbove <= 0) return sessions;
  return sessions.filter(s => s.minutes >= keepAbove - 1e-6);
}

function uniqueMinutes(sessions, from, to) {
  const spans = [];
  const fromMs = from ? from.getTime() : -Infinity;
  const toMs = to ? to.getTime() : Infinity;
  for (const s of sessions) {
    const a = Math.max(s.start.getTime(), fromMs);
    const b = Math.min(s.end.getTime(), toMs);
    if (b <= a) continue;
    spans.push([a, b]);
  }
  spans.sort((x, y) => x[0] - y[0]);
  let totalMs = 0;
  let curStart = null;
  let curEnd = null;
  for (const [a, b] of spans) {
    if (curStart === null || a > curEnd) {
      if (curStart !== null) totalMs += curEnd - curStart;
      curStart = a;
      curEnd = b;
    } else if (b > curEnd) {
      curEnd = b;
    }
  }
  if (curStart !== null) totalMs += curEnd - curStart;
  return totalMs / 60000;
}

function buildData() {
  const rows = readRows();
  const custom = readCustomGames();
  const settings = readSettings();
  const totals = new Map();
  const byDay = new Map();
  const now = new Date();
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const weekStart = new Date(today);
  weekStart.setDate(today.getDate() - 6);

  for (const row of rows) {
    const day = new Date(row.start.getFullYear(), row.start.getMonth(), row.start.getDate());
    const key = dayKey(day);

    let game = totals.get(row.process);
    if (!game) {
      game = {
        process: row.process,
        name: getDisplayName(row.process, custom),
        avatar: getAvatarUrl(row.process, custom),
        total: 0, week: 0, today: 0
      };
      totals.set(row.process, game);
    }
    game.total += row.minutes;
    if (day >= weekStart) game.week += row.minutes;
    if (key === dayKey(today)) game.today += row.minutes;

    if (!byDay.has(key)) byDay.set(key, new Map());
    const dayMap = byDay.get(key);
    const dayGame = dayMap.get(row.process) || {
      process: row.process,
      name: getDisplayName(row.process, custom),
      avatar: getAvatarUrl(row.process, custom),
      minutes: 0
    };
    dayGame.minutes += row.minutes;
    dayMap.set(row.process, dayGame);
  }

  const games = Array.from(totals.values())
    .map(g => ({
      process: g.process,
      name: g.name,
      avatar: g.avatar,
      totalMinutes: Math.round(g.total * 10) / 10,
      weekMinutes: Math.round(g.week * 10) / 10,
      todayMinutes: Math.round(g.today * 10) / 10
    }))
    .sort((a, b) => b.totalMinutes - a.totalMinutes);

  const sessions = buildSessions(rows, custom, settings.minSessionMinutes);
  const recentSessions = sessions
    .map(s => ({
      process: s.process,
      name: s.name,
      avatar: s.avatar,
      dateKey: dayKey(s.start),
      endDateKey: dayKey(s.end),
      startStamp: stamp(s.start),
      endStamp: stamp(s.end),
      startText: hm(s.start),
      endText: hm(s.end),
      minutes: Math.round(s.minutes * 10) / 10
    }))
    .sort((a, b) => (a.dateKey + a.startText < b.dateKey + b.startText ? 1 : -1))
    .slice(0, 10);

  const days = [];
  for (let i = 6; i >= 0; i--) {
    const day = new Date(today);
    day.setDate(today.getDate() - i);
    const key = dayKey(day);
    const dayStart = new Date(day);
    const dayEnd = new Date(day);
    dayEnd.setDate(dayEnd.getDate() + 1);
    const map = byDay.get(key) || new Map();
    const items = Array.from(map.values())
      .map(g => ({
        process: g.process,
        name: g.name,
        avatar: g.avatar,
        minutes: Math.round(g.minutes * 10) / 10
      }))
      .sort((a, b) => b.minutes - a.minutes);
    const total = uniqueMinutes(sessions, dayStart, dayEnd);
    const max = items.length ? Math.max(...items.map(g => g.minutes)) : 0;
    days.push({
      date: key,
      totalMinutes: Math.round(total * 10) / 10,
      maxMinutes: max,
      items: items.map(g => ({ ...g, percent: max ? Math.max(6, Math.round(g.minutes / max * 100)) : 0 }))
    });
  }

  const trend = [];
  for (let i = 13; i >= 0; i--) {
    const day = new Date(today);
    day.setDate(today.getDate() - i);
    const key = dayKey(day);
    const dayStart = new Date(day);
    const dayEnd = new Date(day);
    dayEnd.setDate(dayEnd.getDate() + 1);
    const map = byDay.get(key) || new Map();
    const items = Array.from(map.values())
      .map(g => ({ process: g.process, name: g.name, minutes: Math.round(g.minutes * 10) / 10 }))
      .sort((a, b) => b.minutes - a.minutes);
    trend.push({
      date: key,
      totalMinutes: Math.round(uniqueMinutes(sessions, dayStart, dayEnd) * 10) / 10,
      items: items
    });
  }

  const calendar = [];
  for (let i = 90; i >= 0; i--) {
    const day = new Date(today);
    day.setDate(today.getDate() - i);
    const dayStart = new Date(day);
    const dayEnd = new Date(day);
    dayEnd.setDate(dayEnd.getDate() + 1);
    calendar.push({
      date: dayKey(day),
      minutes: Math.round(uniqueMinutes(sessions, dayStart, dayEnd) * 10) / 10
    });
  }

  let reminder = null;
  if (settings.remindMinutes > 0) {
    const nowMs = Date.now();
    let best = null;
    for (const s of sessions) {
      if (s.end.getTime() < nowMs - 5 * 60000) continue;
      if (s.minutes < settings.remindMinutes) continue;
      if (!best || s.minutes > best.minutes) best = s;
    }
    if (best) {
      reminder = {
        process: best.process,
        name: best.name,
        minutes: Math.round(best.minutes),
        since: hm(best.start)
      };
    }
  }

  const historyMap = new Map();
  for (const row of rows) {
    const item = historyMap.get(row.process) || {
      process: row.process,
      name: getDisplayName(row.process, custom),
      avatar: getAvatarUrl(row.process, custom),
      minutes: 0,
      count: 0
    };
    item.minutes += row.minutes;
    item.count++;
    historyMap.set(row.process, item);
  }
  const history = Array.from(historyMap.values())
    .map(h => ({
      process: h.process,
      name: h.name,
      avatar: h.avatar,
      minutes: Math.round(h.minutes * 10) / 10,
      count: h.count
    }))
    .sort((a, b) => b.minutes - a.minutes);

  return {
    updated: new Date().toLocaleString('zh-CN', { hour12: false }),
    summary: {
      today: Math.round(uniqueMinutes(sessions, today, now) * 10) / 10,
      week: Math.round(uniqueMinutes(sessions, weekStart, now) * 10) / 10,
      all: Math.round(uniqueMinutes(sessions, null, null) * 10) / 10,
      sessions: sessions.length
    },
    games,
    days,
    trend,
    calendar,
    recentSessions,
    history,
    reminder,
    settings,
    configured: readConfiguredGames(custom)
  };
}

function runningProcesses() {
  try {
    const result = spawnSync('tasklist.exe', ['/fo', 'csv', '/nh'], {
      encoding: 'utf8',
      windowsHide: true,
      timeout: 5000
    });
    const set = new Set();
    for (const line of result.stdout.toString('utf8').split(/\r?\n/)) {
      const m = line.match(/^"([^"]+)"/);
      if (!m) continue;
      const name = m[1].replace(/\.exe$/i, '').toLowerCase();
      if (name) set.add(name);
    }
    return Array.from(set).sort();
  } catch (e) {
    return [];
  }
}

function addGame(body) {
  const processName = String(body.process || '').trim().toLowerCase();
  const name = String(body.name || '').trim();
  if (!processName || !/^[a-z0-9_\-]+$/.test(processName)) {
    return { error: '进程名无效:只能包含字母、数字、下划线和连字符。' };
  }

  let listText = '';
  const existing = new Set();
  if (fs.existsSync(GAME_LIST_FILE)) {
    const lines = fs.readFileSync(GAME_LIST_FILE, 'utf8').split(/\r?\n/);
    listText = lines.map(line => {
      const t = line.trim().toLowerCase();
      if (t && !t.startsWith('#')) existing.add(t);
      return line;
    }).join('\n');
  }

  if (existing.has(processName)) {
    if (body.update) {
      let custom = readCustomGames();
      const record = custom[processName] || {};
      record.name = name || record.name || processName;
      const avatarData = body.avatarData;
      if (avatarData && typeof avatarData === 'string') {
        const m = avatarData.match(/^data:image\/(png|jpeg|jpg|webp);base64,(.+)$/);
        if (m) {
          const ext = (m[1] === 'jpeg' ? 'jpg' : m[1]).toLowerCase();
          const buffer = Buffer.from(m[2], 'base64');
          const avatarFile = 'avatar_' + processName + '.' + ext;
          fs.writeFileSync(path.join(AVATAR_DIR, avatarFile), buffer);
          record.avatar = avatarFile;
        }
      }
      custom[processName] = record;
      fs.writeFileSync(CUSTOM_FILE, JSON.stringify(custom, null, 2), 'utf8');
      return { ok: true, process: processName, name: record.name, updated: true };
    }
    return { error: '该进程已在统计列表中,无需重复添加。' };
  }

  let custom = readCustomGames();
  const record = custom[processName] || {};
  record.name = name || processName;

  const avatarData = body.avatarData;
  if (avatarData && typeof avatarData === 'string') {
    const m = avatarData.match(/^data:image\/(png|jpeg|jpg|webp);base64,(.+)$/);
    if (m) {
      const ext = (m[1] === 'jpeg' ? 'jpg' : m[1]).toLowerCase();
      const buffer = Buffer.from(m[2], 'base64');
      const avatarFile = 'avatar_' + processName + '.' + ext;
      fs.writeFileSync(path.join(AVATAR_DIR, avatarFile), buffer);
      record.avatar = avatarFile;
    }
  }
  custom[processName] = record;
  fs.writeFileSync(CUSTOM_FILE, JSON.stringify(custom, null, 2), 'utf8');

  if (!existing.has(processName)) {
    if (listText && !listText.endsWith('\n')) listText += '\n';
    listText += processName;
  }
  fs.writeFileSync(GAME_LIST_FILE, listText, 'utf8');

  return { ok: true, process: processName, name: record.name };
}

function rewriteHistory(processName) {
  if (!fs.existsSync(CSV_FILE)) return;
  const text = fs.readFileSync(CSV_FILE, 'utf8');
  const lines = text.split(/\r?\n/);
  const keepAll = processName === 'all';
  const out = [];
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const trimmed = line.trim();
    if (i === 0 || !trimmed) {
      out.push(line);
      continue;
    }
    const parts = splitCsvLine(line);
    if (parts.length < 3) {
      out.push(line);
      continue;
    }
    const proc = parts[2].trim().toLowerCase();
    if (!keepAll && proc !== processName) out.push(line);
  }
  fs.writeFileSync(CSV_FILE, out.join('\r\n'), 'utf8');
}

function deleteGame(body) {
  const processName = String(body.process || '').trim().toLowerCase();
  if (!processName || processName === 'all') return { error: '进程名无效。' };

  if (body.deleteHistory) rewriteHistory(processName);

  if (fs.existsSync(GAME_LIST_FILE)) {
    const lines = fs.readFileSync(GAME_LIST_FILE, 'utf8').split(/\r?\n/);
    const out = lines.filter(line => {
      const t = line.trim().toLowerCase();
      return !t || t.startsWith('#') || t !== processName;
    });
    fs.writeFileSync(GAME_LIST_FILE, out.join('\n'), 'utf8');
  }

  const custom = readCustomGames();
  if (custom[processName]) {
    const avatarFile = custom[processName].avatar;
    if (avatarFile) {
      const avatarPath = path.resolve(AVATAR_DIR, avatarFile);
      if (avatarPath.startsWith(AVATAR_DIR + path.sep) && fs.existsSync(avatarPath)) {
        fs.unlinkSync(avatarPath);
      }
    }
    delete custom[processName];
    fs.writeFileSync(CUSTOM_FILE, JSON.stringify(custom, null, 2), 'utf8');
  }

  return { ok: true, process: processName };
}

function parseLocalDateTime(text) {
  const m = String(text == null ? '' : text).trim()
    .match(/^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?$/);
  if (!m) return null;
  const d = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]), Number(m[4]), Number(m[5]), Number(m[6] || 0), 0);
  return isNaN(d.getTime()) ? null : d;
}

function stamp(date) {
  return date.getFullYear() + '-' +
    String(date.getMonth() + 1).padStart(2, '0') + '-' +
    String(date.getDate()).padStart(2, '0') + ' ' +
    String(date.getHours()).padStart(2, '0') + ':' +
    String(date.getMinutes()).padStart(2, '0') + ':' +
    String(date.getSeconds()).padStart(2, '0');
}

function csvLine(start, end, processName) {
  return '"' + stamp(start) + '","' + stamp(end) + '","' + processName + '",""';
}

function ensureCsvFile() {
  try {
    if (!fs.existsSync(CSV_FILE) || fs.statSync(CSV_FILE).size === 0) {
      fs.writeFileSync(CSV_FILE, 'Start,End,Process,Title\r\n', 'utf8');
    }
  } catch (e) { /* ignore */ }
}

function appendLine(line) {
  ensureCsvFile();
  let sep = '';
  try {
    const fd = fs.openSync(CSV_FILE, 'r');
    const size = fs.fstatSync(fd).size;
    if (size > 0) {
      const buf = Buffer.alloc(1);
      fs.readSync(fd, buf, 0, 1, size - 1);
      if (buf.toString('utf8') !== '\n') sep = '\r\n';
    }
    fs.closeSync(fd);
  } catch (e) { /* ignore */ }
  fs.appendFileSync(CSV_FILE, sep + line + '\r\n', 'utf8');
}

function removeRows(match) {
  if (!fs.existsSync(CSV_FILE)) return 0;
  const lines = fs.readFileSync(CSV_FILE, 'utf8').split(/\r?\n/);
  const out = [];
  let removed = 0;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const trimmed = line.trim();
    if (i === 0 || !trimmed) { out.push(line); continue; }
    const parts = splitCsvLine(line);
    if (parts.length < 3) { out.push(line); continue; }
    const start = parseLocalDateTime(parts[0]);
    const end = parseLocalDateTime(parts[1]);
    const proc = parts[2].trim().toLowerCase();
    if (start && end && match(proc, start, end)) { removed++; continue; }
    out.push(line);
  }
  while (out.length && !out[out.length - 1].trim()) out.pop();
  if (removed) fs.writeFileSync(CSV_FILE, out.join('\r\n') + '\r\n', 'utf8');
  return removed;
}

function deleteSession(body) {
  const processName = String(body.process || '').trim().toLowerCase();
  const start = parseLocalDateTime(body.start);
  const end = parseLocalDateTime(body.end);
  if (!processName || !start || !end || end <= start) return { error: '记录参数无效。' };
  const pad = 5000;
  const removed = removeRows((proc, rowStart, rowEnd) =>
    proc === processName &&
    rowStart.getTime() >= start.getTime() - pad &&
    rowEnd.getTime() <= end.getTime() + pad
  );
  return { ok: true, removed: removed };
}

function deleteDay(body) {
  const dateKey = String(body.date || '').trim();
  if (!/^\d{4}-\d{2}-\d{2}$/.test(dateKey)) return { error: '日期无效。' };
  const onlyProcess = String(body.process || '').trim().toLowerCase();
  const removed = removeRows((proc, rowStart) =>
    (!onlyProcess || proc === onlyProcess) && stamp(rowStart).slice(0, 10) === dateKey
  );
  return { ok: true, removed: removed };
}

function addRecord(body) {
  const processName = String(body.process || '').trim().toLowerCase();
  if (!processName || !/^[a-z0-9_\-]+$/.test(processName)) return { error: '请先选择要补录的游戏。' };
  const start = parseLocalDateTime(body.start);
  const end = parseLocalDateTime(body.end);
  if (!start || !end) return { error: '请填写正确的开始和结束时间。' };
  if (end <= start) return { error: '结束时间必须晚于开始时间。' };
  if (end - start > 24 * 3600 * 1000) return { error: '单条记录不能超过 24 小时。' };
  if (start.getTime() > Date.now() + 60000) return { error: '开始时间不能晚于当前时间。' };
  appendLine(csvLine(start, end, processName));
  return { ok: true, minutes: Math.round((end - start) / 60000) };
}


const SETTINGS_FILE = path.join(ROOT, 'settings.json');
const BACKUP_DIR = path.join(ROOT, 'backups');
const AUTOSTART_KEY = 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run';
const AUTOSTART_NAME = 'GameTimeTrackerApp';

const DEFAULT_SETTINGS = {
  dailyGoalMinutes: 120,
  remindMinutes: 0,
  minSessionMinutes: 1,
  theme: 'violet',
  refreshSeconds: 5,
  showSessions: true,
  showTrend: true,
  showCalendar: true,
  showGames: true,
  showDays: true,
  autoBackup: true
};

function readSettings() {
  let parsed = {};
  try {
    if (fs.existsSync(SETTINGS_FILE)) parsed = JSON.parse(fs.readFileSync(SETTINGS_FILE, 'utf8')) || {};
  } catch (e) {
    parsed = {};
  }
  const out = Object.assign({}, DEFAULT_SETTINGS);
  for (const key of Object.keys(DEFAULT_SETTINGS)) {
    if (parsed[key] !== undefined && typeof parsed[key] === typeof DEFAULT_SETTINGS[key]) out[key] = parsed[key];
  }
  return out;
}

function normalizeSettings(next) {
  const out = Object.assign({}, next);
  out.dailyGoalMinutes = Math.max(0, Math.min(1440, Math.round(Number(out.dailyGoalMinutes) || 0)));
  out.remindMinutes = Math.max(0, Math.min(1440, Math.round(Number(out.remindMinutes) || 0)));
  out.refreshSeconds = Math.max(2, Math.min(120, Math.round(Number(out.refreshSeconds) || 5)));
  const minSession = Number(out.minSessionMinutes);
  out.minSessionMinutes = Number.isFinite(minSession) && minSession >= 0 ? Math.min(120, Math.round(minSession * 10) / 10) : 1;
  if (['violet', 'cyan', 'blue'].indexOf(out.theme) < 0) out.theme = 'violet';
  return out;
}

function writeSettings(patch) {
  const current = readSettings();
  const next = Object.assign({}, current);
  for (const key of Object.keys(DEFAULT_SETTINGS)) {
    if (patch && patch[key] !== undefined && typeof patch[key] === typeof DEFAULT_SETTINGS[key]) next[key] = patch[key];
  }
  const clean = normalizeSettings(next);
  fs.writeFileSync(SETTINGS_FILE, JSON.stringify(clean, null, 2), 'utf8');
  return clean;
}

function seaExecutable() {
  try {
    if (require('node:sea').isSea()) return process.execPath;
  } catch (e) { /* not a sea runtime */ }
  return '';
}

function isAutostartEnabled() {
  try {
    const res = spawnSync('reg.exe', ['query', AUTOSTART_KEY, '/v', AUTOSTART_NAME], { encoding: 'utf8', windowsHide: true, timeout: 5000 });
    return res.status === 0 && /GameTimeTracker/.test(String(res.stdout || ''));
  } catch (e) {
    return false;
  }
}

function setAutostart(enabled) {
  const target = seaExecutable();
  if (!target) return { error: '只有 exe 版本才能修改开机自启。' };
  try {
    if (enabled) {
      const res = spawnSync('reg.exe', ['add', AUTOSTART_KEY, '/v', AUTOSTART_NAME, '/t', 'REG_SZ', '/d', '"' + target + '"', '/f'], { encoding: 'utf8', windowsHide: true, timeout: 8000 });
      if (res.status !== 0) return { error: '写入开机自启失败:' + String(res.stderr || '').trim() };
    } else {
      spawnSync('reg.exe', ['delete', AUTOSTART_KEY, '/v', AUTOSTART_NAME, '/f'], { encoding: 'utf8', windowsHide: true, timeout: 8000 });
    }
    return { ok: true, enabled: isAutostartEnabled() };
  } catch (e) {
    return { error: e.message };
  }
}

function listBackups() {
  try {
    if (!fs.existsSync(BACKUP_DIR)) return { count: 0, last: '' };
    const files = fs.readdirSync(BACKUP_DIR)
      .filter(f => /^activity-.*\.csv$/.test(f))
      .map(f => ({ name: f, time: fs.statSync(path.join(BACKUP_DIR, f)).mtimeMs }))
      .sort((a, b) => a.time - b.time);
    return { count: files.length, last: files.length ? files[files.length - 1].name : '' };
  } catch (e) {
    return { count: 0, last: '' };
  }
}

function backupNow(timestamped) {
  try {
    if (!fs.existsSync(CSV_FILE) || fs.statSync(CSV_FILE).size === 0) return { error: '还没有数据可以备份。' };
    fs.mkdirSync(BACKUP_DIR, { recursive: true });
    const now = new Date();
    const name = timestamped
      ? 'activity-' + dayKey(now) + '-' + String(now.getHours()).padStart(2, '0') + String(now.getMinutes()).padStart(2, '0') + '.csv'
      : 'activity-' + dayKey(now) + '.csv';
    fs.copyFileSync(CSV_FILE, path.join(BACKUP_DIR, name));
    return { ok: true, file: name };
  } catch (e) {
    return { error: e.message };
  }
}

function ensureDailyBackup() {
  try {
    const settings = readSettings();
    if (!settings.autoBackup) return;
    backupNow(false);
  } catch (e) { /* ignore */ }
}

function buildRecords(query) {
  const custom = readCustomGames();
  const sessions = buildSessions(readRows(), custom, readSettings().minSessionMinutes);
  let items = sessions.map(s => ({
    process: s.process,
    name: s.name,
    avatar: s.avatar,
    dateKey: dayKey(s.start),
    endDateKey: dayKey(s.end),
    startStamp: stamp(s.start),
    endStamp: stamp(s.end),
    startText: hm(s.start),
    endText: hm(s.end),
    minutes: Math.round(s.minutes * 10) / 10
  }));
  items.sort((a, b) => (a.startStamp < b.startStamp ? 1 : -1));

  const from = String(query.from || '').trim();
  const to = String(query.to || '').trim();
  const onlyProcess = String(query.process || '').trim().toLowerCase();
  const keyword = String(query.q || '').trim().toLowerCase();
  if (/^\d{4}-\d{2}-\d{2}$/.test(from)) items = items.filter(x => x.dateKey >= from);
  if (/^\d{4}-\d{2}-\d{2}$/.test(to)) items = items.filter(x => x.dateKey <= to);
  if (onlyProcess) items = items.filter(x => x.process === onlyProcess);
  if (keyword) {
    items = items.filter(x => (x.name + ' ' + x.process + ' ' + x.dateKey + ' ' + x.startText + ' ' + x.endText).toLowerCase().indexOf(keyword) >= 0);
  }

  const totalMinutes = items.reduce((sum, x) => sum + x.minutes, 0);
  const total = items.length;
  const limit = Math.min(500, Math.max(20, Number(query.limit) || 300));
  return {
    total: total,
    minutes: Math.round(totalMinutes * 10) / 10,
    items: items.slice(0, limit),
    limit: limit,
    truncated: total > limit
  };
}

function readJsonBody(req, done) {
  let data = '';
  req.on('data', chunk => { data += chunk; });
  req.on('end', () => {
    try { done(JSON.parse(data || '{}')); }
    catch (e) { done(null); }
  });
}

const server = http.createServer((req, res) => {
  try {
    const urlPath = decodeURIComponent((req.url || '/').split('?')[0]);

    if (urlPath.startsWith('/avatars/')) {
      const file = path.resolve(AVATAR_DIR, '.' + urlPath.slice('/avatars'.length));
      if (file.startsWith(AVATAR_DIR + path.sep) && fs.existsSync(file)) {
        const mime = {
          '.png': 'image/png',
          '.jpg': 'image/jpeg',
          '.jpeg': 'image/jpeg',
          '.webp': 'image/webp'
        }[path.extname(file).toLowerCase()] || 'image/png';
        res.writeHead(200, { 'Content-Type': mime, 'Cache-Control': 'max-age=300' });
        fs.createReadStream(file).pipe(res);
      } else {
        res.writeHead(404);
        res.end('Not found');
      }
      return;
    }

    if (urlPath === '/api/data') {
      const data = buildData();
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
      res.end(JSON.stringify(data));
      return;
    }

    if (urlPath === '/api/processes') {
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
      res.end(JSON.stringify(runningProcesses()));
      return;
    }

    if (urlPath === '/api/games' && req.method === 'POST') {
      readJsonBody(req, (body) => {
        const result = addGame(body || {});
        res.writeHead(result.error ? 400 : 200, { 'Content-Type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify(result));
      });
      return;
    }

    if (urlPath === '/api/delete-history' && req.method === 'POST') {
      readJsonBody(req, (body) => {
        const processName = String((body || {}).process || '').toLowerCase();
        if (!processName) {
          res.writeHead(400, { 'Content-Type': 'application/json; charset=utf-8' });
          res.end(JSON.stringify({ error: '参数无效' }));
          return;
        }
        rewriteHistory(processName);
        res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify({ ok: true }));
      });
      return;
    }

    if (urlPath === '/api/delete-game' && req.method === 'POST') {
      readJsonBody(req, (body) => {
        const result = deleteGame(body || {});
        res.writeHead(result.error ? 400 : 200, { 'Content-Type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify(result));
      });
      return;
    }

    if (urlPath === '/api/settings') {
      const backupInfo = listBackups();
      const base = {
        autostart: isAutostartEnabled(),
        canAutostart: !!seaExecutable(),
        dataFile: CSV_FILE,
        backupDir: BACKUP_DIR,
        backups: backupInfo.count,
        lastBackup: backupInfo.last
      };
      if (req.method === 'POST') {
        readJsonBody(req, (body) => {
          const settings = writeSettings(body || {});
          let autostartError = '';
          if (body && body.autostart !== undefined) {
            const result = setAutostart(!!body.autostart);
            if (result.error) autostartError = result.error;
          }
          const info = listBackups();
          const payload = Object.assign({}, base, {
            settings: settings,
            autostart: isAutostartEnabled(),
            backups: info.count,
            lastBackup: info.last,
            ok: !autostartError,
            error: autostartError || undefined
          });
          res.writeHead(autostartError ? 400 : 200, { 'Content-Type': 'application/json; charset=utf-8' });
          res.end(JSON.stringify(payload));
        });
        return;
      }
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
      res.end(JSON.stringify(Object.assign({ settings: readSettings() }, base)));
      return;
    }

    if (urlPath === '/api/backup' && req.method === 'POST') {
      const result = backupNow(true);
      const info = listBackups();
      res.writeHead(result.error ? 400 : 200, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify(Object.assign({}, result, { backups: info.count, lastBackup: info.last })));
      return;
    }

    if (urlPath === '/api/open-folder' && req.method === 'POST') {
      try {
        spawn('explorer.exe', [ROOT], { detached: true, stdio: 'ignore', windowsHide: true }).unref();
      } catch (e) { /* ignore */ }
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify({ ok: true }));
      return;
    }

    if (urlPath === '/api/records') {
      const qs = new URLSearchParams((req.url || '').split('?')[1] || '');
      const data = buildRecords({
        process: qs.get('process') || '',
        from: qs.get('from') || '',
        to: qs.get('to') || '',
        q: qs.get('q') || '',
        limit: qs.get('limit') || ''
      });
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
      res.end(JSON.stringify(data));
      return;
    }

    if (urlPath === '/api/add-record' && req.method === 'POST') {
      readJsonBody(req, (body) => {
        const result = addRecord(body || {});
        res.writeHead(result.error ? 400 : 200, { 'Content-Type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify(result));
      });
      return;
    }

    if (urlPath === '/api/delete-session' && req.method === 'POST') {
      readJsonBody(req, (body) => {
        const result = deleteSession(body || {});
        res.writeHead(result.error ? 400 : 200, { 'Content-Type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify(result));
      });
      return;
    }

    if (urlPath === '/api/delete-day' && req.method === 'POST') {
      readJsonBody(req, (body) => {
        const result = deleteDay(body || {});
        res.writeHead(result.error ? 400 : 200, { 'Content-Type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify(result));
      });
      return;
    }

    if (urlPath === '/api/export') {
      ensureCsvFile();
      res.writeHead(200, {
        'Content-Type': 'text/csv; charset=utf-8',
        'Content-Disposition': 'attachment; filename="activity-' + dayKey(new Date()) + '.csv"',
        'Cache-Control': 'no-store'
      });
      fs.createReadStream(CSV_FILE).pipe(res);
      return;
    }

    if (urlPath === '/' || urlPath === '/index.html') {
      const html = fs.readFileSync(HTML_FILE, 'utf8');
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(html);
      return;
    }

    res.writeHead(404);
    res.end('Not found');
  } catch (err) {
    res.writeHead(500, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.end('Error: ' + err.message);
  }
});

function browserExecutables() {
  const list = [];
  const bases = [process.env['ProgramFiles(x86)'], process.env['ProgramFiles'], process.env['LOCALAPPDATA']];
  for (const base of bases) {
    if (!base) continue;
    list.push(path.join(base, 'Microsoft', 'Edge', 'Application', 'msedge.exe'));
    list.push(path.join(base, 'Google', 'Chrome', 'Application', 'chrome.exe'));
  }
  if (process.env['ProgramFiles']) {
    list.push(path.join(process.env['ProgramFiles'], 'Mozilla Firefox', 'firefox.exe'));
    list.push(path.join(process.env['ProgramFiles(x86)'] || '', 'Mozilla Firefox', 'firefox.exe'));
  }
  return list.filter(Boolean);
}

function spawnDetached(command, args) {
  try {
    const child = spawn(command, args, { detached: true, stdio: 'ignore', windowsHide: true });
    child.on('error', () => { /* 装不上浏览器也不能让后台统计挂掉 */ });
    child.unref();
    return true;
  } catch (e) {
    return false;
  }
}

function openDashboardWindow() {
  const url = 'http://127.0.0.1:' + PORT;
  for (const exe of browserExecutables()) {
    try {
      if (!fs.existsSync(exe)) continue;
      if (spawnDetached(exe, ['--app=' + url])) return true;
    } catch (e) { /* try next browser */ }
  }
  // 兜底:交给系统默认浏览器
  return spawnDetached('cmd.exe', ['/c', 'start', '', url]);
}

server.on('error', (err) => {
  if (err.code === 'EADDRINUSE') {
    logTracker('已经有一个实例在跑（端口被占用），本次启动直接退出' + (process.argv.includes('--open') ? '，顺便打开面板' : ''));
    console.log('Dashboard is already running at http://127.0.0.1:' + PORT);
    if (process.argv.includes('--open')) openDashboardWindow();
  } else {
    logTracker('启动失败：' + err.message);
    console.error(err.message);
  }
  process.exit(0);
});

server.listen(PORT, '127.0.0.1', () => {
  logTracker('启动成功：pid=' + process.pid + '，参数=[' + process.argv.slice(2).join(' ') + ']，目录=' + ROOT);
  console.log('Game dashboard: http://127.0.0.1:' + PORT);
  if (process.argv.includes('--open')) openDashboardWindow();

  // ---- 每日自动备份 ----
  // 只有真正抢到端口的实例才做备份：看门任务重复拉起的实例不该来覆盖备份
  ensureDailyBackup();
  setInterval(ensureDailyBackup, 30 * 60 * 1000);
});

// ---- standalone mode: background tracker + dashboard in one process ----
const isSeaApp = (() => {
  try { return require('node:sea').isSea(); } catch (e) { return false; }
})();

if (process.argv.includes('--standalone') || isSeaApp) {
  const STOP_FILE = path.join(ROOT, 'stop.txt');
  const CHECKPOINT_MS = 60000;
  const MIN_FLUSH_MS = 2000;
  const tracked = new Map(); // process -> last checkpoint time

  function appendCsvRow(start, end, processName) {
    if (end <= start) return;
    appendLine(csvLine(start, end, processName));
  }

  function configuredProcesses() {
    if (!fs.existsSync(GAME_LIST_FILE)) return [];
    return fs.readFileSync(GAME_LIST_FILE, 'utf8')
      .split(/\r?\n/)
      .map(l => l.trim().toLowerCase())
      .filter(l => l && !l.startsWith('#'));
  }

  function minecraftIsRunning() {
    try {
      const res = spawnSync(
        'powershell.exe',
        [
          '-NoProfile',
          '-Command',
          "Get-CimInstance Win32_Process -Filter \"Name='javaw.exe' OR Name='java.exe'\" | Select-Object -ExpandProperty CommandLine"
        ],
        { encoding: 'utf8', windowsHide: true, timeout: 5000 }
      );
      return res.status === 0 && /net\.minecraft\.client\.main\.Main/.test(res.stdout || '');
    } catch (e) {
      return false;
    }
  }

  function logTrackerError(err) {
    try {
      const line = new Date().toLocaleString('zh-CN', { hour12: false }) + '  ' + (err && err.message ? err.message : String(err));
      fs.appendFileSync(path.join(ROOT, 'standalone-error.log'), line + '\r\n', 'utf8');
    } catch (e) { /* ignore */ }
  }

  function tick() {
    const now = new Date();
    try {
      if (fs.existsSync(STOP_FILE)) {
        fs.unlinkSync(STOP_FILE);
        console.log('stop signal received, tracker exiting');
        process.exit(0);
      }

      const gameSet = new Set(configuredProcesses());
      const running = new Set(runningProcesses());
      if (gameSet.has('minecraft') && minecraftIsRunning()) running.add('minecraft');

      for (const game of gameSet) {
        if (running.has(game)) {
          if (!tracked.has(game)) {
            tracked.set(game, now);
          } else {
            const last = tracked.get(game);
            if ((now - last) >= CHECKPOINT_MS) {
              appendCsvRow(last, now, game);
              tracked.set(game, now);
            }
          }
        } else if (tracked.has(game)) {
          const last = tracked.get(game);
          if ((now - last) >= MIN_FLUSH_MS) appendCsvRow(last, now, game);
          tracked.delete(game);
        }
      }
    } catch (err) {
      logTrackerError(err);
    }
  }

  if (!fs.existsSync(CSV_FILE) || fs.statSync(CSV_FILE).size === 0) {
    fs.writeFileSync(CSV_FILE, 'Start,End,Process,Title\r\n', 'utf8');
  }

  console.log('Standalone tracker active');
  setInterval(tick, 2000);
}
