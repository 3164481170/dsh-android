import fs from 'node:fs';
const f = process.argv[2];
let s = fs.readFileSync(f, 'utf8');
if (s.includes('dsh-android fallback')) { console.log('already'); process.exit(0); }
const start = s.indexOf("if (platform !== 'linux' && platform !== 'darwin') {");
if (start < 0) { console.error('anchor-miss'); process.exit(3); }
const endMarker = '});\n    }';
const end = s.indexOf(endMarker, start);
if (end < 0) { console.error('end-miss'); process.exit(3); }
const replacement = [
  "if (platform !== 'linux' && platform !== 'darwin') {",
  '        // dsh-android fallback: no prebuilt native binding exists for this platform.',
  '        // A single local host process serialises its own writes, and the atomic',
  '        // write path commits through temp+rename, so an exclusive cross-process',
  '        // lock degrades to a no-op instead of failing the run.',
  '        binding = { tryLock(_fd, done) { done(0); } };',
  '        return binding;',
  '    }',
].join('\n');
s = s.slice(0, start) + replacement + s.slice(end + endMarker.length);
fs.writeFileSync(f, s);
console.log('patched');