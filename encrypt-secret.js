const fs = require('fs');
const sodium = require('libsodium-wrappers');

function b64ToUint8Array(b64) {
  return new Uint8Array(Buffer.from(b64, 'base64'));
}

(async () => {
  const pubKeyB64 = process.argv[2];
  const secret = process.argv[3];
  if (!pubKeyB64 || !secret) {
    console.error('usage: node encrypt-secret.js <public_key_base64> <secret>');
    process.exit(1);
  }
  await sodium.ready;
  const pk = b64ToUint8Array(pubKeyB64);
  const message = new Uint8Array(Buffer.from(secret, 'utf8'));
  const boxed = sodium.crypto_box_seal(message, pk);
  process.stdout.write(Buffer.from(boxed).toString('base64'));
})();
