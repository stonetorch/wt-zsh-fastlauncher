// Raw-stdin byte receiver for issue #409 reproduction.
// Mirrors how pi / Claude Code (Node + libuv) read keyboard input:
// raw mode, observing the literal byte stream. Logs each received byte
// as hex to the file given as argv[2] so the test can inspect what
// psmux actually forwarded for Enter / Ctrl+Enter / Alt+Enter.
const fs = require('fs');
const out = process.argv[2];
fs.writeFileSync(out, 'READY\n');
try { process.stdin.setRawMode(true); } catch (e) { fs.appendFileSync(out, 'NORAW ' + e + '\n'); }
process.stdin.resume();
process.stdin.on('data', (buf) => {
  const hex = [...buf].map(b => b.toString(16).padStart(2, '0')).join(' ');
  fs.appendFileSync(out, 'BYTES: ' + hex + '\n');
  // ESC alone => quit hook so we can end cleanly if needed
});
process.on('SIGINT', () => {});
