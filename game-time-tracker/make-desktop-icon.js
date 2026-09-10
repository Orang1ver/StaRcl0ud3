const fs = require('fs');
const zlib = require('zlib');
const path = require('path');
const { spawnSync } = require('child_process');

const root = 'C:/Users/StarRiver/OneDrive/Desktop/code/game-time-tracker';
const desktop = 'C:/Users/StarRiver/OneDrive/Desktop';

// ---------- minimal PNG encoder (RGBA) ----------
const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();

function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const head = Buffer.concat([len, Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(head.subarray(4)));
  return Buffer.concat([head, crc]);
}

function encodePng(size, rgba) {
  const sig = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0);
  ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8;
  ihdr[9] = 6;
  const raw = Buffer.alloc(size * (size * 4 + 1));
  let off = 0;
  for (let y = 0; y < size; y++) {
    raw[off++] = 0;
    for (let x = 0; x < size; x++) {
      const i = (y * size + x) * 4;
      raw[off++] = rgba[i];
      raw[off++] = rgba[i + 1];
      raw[off++] = rgba[i + 2];
      raw[off++] = rgba[i + 3];
    }
  }
  return Buffer.concat([
    sig,
    chunk('IHDR', ihdr),
    chunk('IDAT', zlib.deflateSync(raw)),
    chunk('IEND', Buffer.alloc(0))
  ]);
}

// ---------- simple icon drawing ----------
function inRoundedRect(px, py, l, t, w, h, r) {
  if (px < l || px > l + w || py < t || py > t + h) return false;
  const cx = Math.max(l + r, Math.min(px, l + w - r));
  const cy = Math.max(t + r, Math.min(py, t + h - r));
  return (px - cx) * (px - cx) + (py - cy) * (py - cy) <= r * r;
}

function dist(ax, ay, bx, by) {
  return Math.hypot(ax - bx, ay - by);
}

function inGamepad(px, py) {
  // main body
  if (inRoundedRect(px, py, 50, 92, 156, 60, 26)) return true;
  // two grips
  if (dist(px, py, 74, 148) <= 44) return true;
  if (dist(px, py, 182, 148) <= 44) return true;
  // D-pad
  if (px >= 80 && px <= 100 && py >= 96 && py <= 146) return true;
  if (px >= 68 && px <= 112 && py >= 114 && py <= 128) return true;
  // action buttons
  if (dist(px, py, 146, 104) <= 15) return true;
  if (dist(px, py, 176, 112) <= 15) return true;
  if (dist(px, py, 158, 140) <= 15) return true;
  if (dist(px, py, 194, 128) <= 15) return true;
  return false;
}

function mix(a, b, t) {
  return Math.round(a + (b - a) * t);
}

function buildPng(size) {
  const rgba = Buffer.alloc(size * size * 4);
  const ss = 4;
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      let white = 0;
      for (let sy = 0; sy < ss; sy++) {
        for (let sx = 0; sx < ss; sx++) {
          const px = x + (sx + 0.5) / ss;
          const py = y + (sy + 0.5) / ss;
          if (inGamepad(px, py)) white++;
        }
      }
      const i = (y * size + x) * 4;
      if (!inRoundedRect(x + 0.5, y + 0.5, 4, 4, size - 8, size - 8, size * 0.19)) {
        rgba[i + 3] = 0;
        continue;
      }
      const t = y / size;
      const top = [30, 64, 175];
      const bottom = [124, 58, 237];
      let r = mix(top[0], bottom[0], t);
      let g = mix(top[1], bottom[1], t);
      let b = mix(top[2], bottom[2], t);
      if (white > 0) {
        const k = white / (ss * ss);
        r = Math.round(r + (245 - r) * k);
        g = Math.round(g + (245 - g) * k);
        b = Math.round(b + (245 - b) * k);
      }
      rgba[i] = r;
      rgba[i + 1] = g;
      rgba[i + 2] = b;
      rgba[i + 3] = 255;
    }
  }
  return encodePng(size, rgba);
}

const png = buildPng(256);
const icoPath = path.join(root, 'statistics.ico');

// ICO container with one PNG-compressed 256x256 image
const header = Buffer.alloc(6);
header.writeUInt16LE(0, 0);
header.writeUInt16LE(1, 2);
header.writeUInt16LE(1, 4);
const entry = Buffer.alloc(16);
entry[0] = 0;
entry[1] = 0;
entry[2] = 0;
entry[3] = 0;
entry.writeUInt16LE(1, 4);
entry.writeUInt16LE(32, 6);
entry.writeUInt32LE(png.length, 8);
entry.writeUInt32LE(22, 12);
fs.writeFileSync(icoPath, Buffer.concat([header, entry, png]));
fs.writeFileSync(path.join(root, 'statistics-preview.png'), png);

const lnkName = path.join(desktop, '游戏时长统计.lnk');
const ps = [
  "$ws = New-Object -ComObject WScript.Shell;",
  `$s = $ws.CreateShortcut('${lnkName}');`,
  `$s.TargetPath = '${path.join(root, 'GameTimeTracker.exe')}';`,
  `$s.Arguments = '--open';`,
  `$s.WorkingDirectory = '${root}';`,
  `$s.IconLocation = '${icoPath}';`,
  '$s.WindowStyle = 7;',
  `$s.Description = '打开游戏时长统计面板';`,
  '$s.Save()'
].join(' ');

const res = spawnSync('powershell.exe', ['-NoProfile', '-Command', ps], { stdio: 'inherit' });
if (res.status !== 0) process.exit(res.status || 1);

console.log('created:', icoPath);
console.log('created shortcut:', lnkName);
