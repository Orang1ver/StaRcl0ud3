const fs = require('fs');
const file = process.argv[2];
if (!file) {
  console.error('usage: node flip-subsystem.js <exe>');
  process.exit(1);
}
const buffer = fs.readFileSync(file);
const peOffset = buffer.readUInt32LE(0x3c);
if (buffer.readUInt32LE(peOffset) !== 0x00004550) {
  throw new Error('not a PE executable');
}
const optionalHeader = peOffset + 24;
const subsystemOffset = optionalHeader + 68;
const before = buffer.readUInt16LE(subsystemOffset);
buffer.writeUInt16LE(2, subsystemOffset);
fs.writeFileSync(file, buffer);
console.log('subsystem changed: ' + before + ' -> 2 (GUI)');
