import fs from 'node:fs';
const f = process.argv[2];
let s = fs.readFileSync(f, 'utf8');
if (s.includes('android app-data mounts deny hardlinks')) { console.log('already'); process.exit(0); }
const needle = 'await link(tmp, finalPath);';
if (!s.includes(needle)) { console.error('anchor-miss'); process.exit(3); }
const block = [
  'try { await link(tmp, finalPath); } catch (linkError) {',
  '\t\t\t\tconst code = linkError?.code;',
  '\t\t\t\tif (code !== "EACCES" && code !== "EPERM" && code !== "EXDEV" && code !== "ENOTSUP" && code !== "EOPNOTSUPP") throw linkError;',
  '\t\t\t\t// android app-data mounts deny hardlinks',
  '\t\t\t\tconst { rename } = await import("node:fs/promises");',
  '\t\t\t\tawait rename(tmp, finalPath);',
  '\t\t\t}',
].join('\n');
s = s.replace(needle, block);
fs.writeFileSync(f, s);
console.log('patched');