const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = 8090;
const DIR = __dirname;

// Default save directory (same as server). User can change via the UI.
let saveDir = DIR;

const MIME = {
  '.html': 'text/html', '.css': 'text/css', '.js': 'application/javascript',
  '.png': 'image/png', '.jpg': 'image/jpeg', '.webp': 'image/webp',
  '.svg': 'image/svg+xml', '.ico': 'image/x-icon', '.json': 'application/json',
};

const server = http.createServer((req, res) => {
  // CORS headers for local use
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }

  // ── POST /save — Save a PNG file to the save directory ──
  if (req.method === 'POST' && req.url === '/save') {
    let body = [];
    req.on('data', chunk => body.push(chunk));
    req.on('end', () => {
      try {
        const data = JSON.parse(Buffer.concat(body).toString());
        const { filename, dataUrl, directory } = data;

        // Use provided directory or default
        const targetDir = directory || saveDir;

        // Security: basic sanitization
        const safeName = path.basename(filename);
        const filePath = path.join(targetDir, safeName);

        // Ensure directory exists
        if (!fs.existsSync(targetDir)) {
          fs.mkdirSync(targetDir, { recursive: true });
        }

        // Decode base64 data URL → buffer
        const base64 = dataUrl.replace(/^data:image\/png;base64,/, '');
        fs.writeFileSync(filePath, Buffer.from(base64, 'base64'));

        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true, path: filePath }));
        console.log(`  Saved: ${filePath}`);
      } catch (err) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, error: err.message }));
        console.error(`  Error saving: ${err.message}`);
      }
    });
    return;
  }

  // ── POST /browse — List directories for the folder picker ──
  if (req.method === 'POST' && req.url === '/browse') {
    let body = [];
    req.on('data', chunk => body.push(chunk));
    req.on('end', () => {
      try {
        const { dir } = JSON.parse(Buffer.concat(body).toString());
        const target = dir || saveDir;
        const items = fs.readdirSync(target, { withFileTypes: true })
          .filter(d => d.isDirectory() && !d.name.startsWith('.'))
          .map(d => d.name)
          .sort();
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true, dir: target, folders: items }));
      } catch (err) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, error: err.message }));
      }
    });
    return;
  }

  // ── GET — Serve static files ──
  const url = req.url === '/' ? '/index.html' : req.url.split('?')[0];
  const filePath = path.join(DIR, url);
  if (!filePath.startsWith(DIR)) { res.writeHead(403); res.end('Forbidden'); return; }

  fs.readFile(filePath, (err, data) => {
    if (err) { res.writeHead(404); res.end('Not found: ' + url); return; }
    const ext = path.extname(filePath).toLowerCase();
    res.writeHead(200, { 'Content-Type': MIME[ext] || 'application/octet-stream' });
    res.end(data);
  });
});

server.listen(PORT, () => {
  console.log(`\n  ╔══════════════════════════════════════╗`);
  console.log(`  ║   PBR Texture Forge — Server Ready   ║`);
  console.log(`  ╠══════════════════════════════════════╣`);
  console.log(`  ║  http://localhost:${PORT}              ║`);
  console.log(`  ╚══════════════════════════════════════╝\n`);
  console.log(`  Default save directory: ${DIR}\n`);
  console.log(`  Keep this window open. Press Ctrl+C to stop.\n`);
});
