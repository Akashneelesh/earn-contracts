// LayerZero V2 manual message delivery helper.
//
// When the LZ Starknet executor is slow, anyone can manually call
// endpoint.lz_receive(...) once the DVN attestation has been sealed.
// This script reads the pending message from LZ scan and submits the
// delivery tx via the Starknet burner.
//
// Usage:
//   node kick.mjs <source-tx-hash>
//
// Pulls Origin / GUID / payload from scan-testnet.layerzero-api.com.
// Requires the message's verification.sealer.status == "SUCCEEDED" — if not,
// the receive lib hasn't committed the verification yet and the endpoint
// will revert with "verifying" / "PAYLOAD_HASH_NOT_FOUND".

import { RpcProvider, Account, CallData } from 'starknet';
import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));
// .env is three levels up: scripts/lib/lz-kick/ -> scripts/lib/ -> scripts/ -> cross_chain/
const ROOT = join(__dirname, '..', '..', '..');

const ENV = Object.fromEntries(
  readFileSync(join(ROOT, '.env'), 'utf8')
    .split('\n')
    .filter(l => /^[A-Z_][A-Z0-9_]*=/.test(l))
    .map(l => { const [k, ...v] = l.split('='); return [k, v.join('=').trim()]; })
);

const TX = process.argv[2];
if (!TX || !TX.startsWith('0x')) {
  console.error('usage: node kick.mjs <source-tx-hash>');
  process.exit(2);
}

// Fetch message details from LZ scan
const scanUrl = `https://scan-testnet.layerzero-api.com/v1/messages/tx/${TX}`;
console.log('fetching:', scanUrl);
const res = await fetch(scanUrl);
if (!res.ok) { console.error('LZ scan returned', res.status); process.exit(1); }
const json = await res.json();
if (!json.data?.length) { console.error('no message data'); process.exit(1); }
const m = json.data[0];

if (m.verification?.sealer?.status !== 'SUCCEEDED') {
  console.error(`sealer status = ${m.verification?.sealer?.status} — must be SUCCEEDED to deliver. Wait for the sealer to commit first.`);
  process.exit(1);
}
if (m.destination?.status === 'DELIVERED') {
  console.log('already DELIVERED — nothing to do');
  process.exit(0);
}

const SRC_EID = m.pathway.srcEid;
const NONCE = BigInt(m.pathway.nonce);
const SENDER_ADDR = m.pathway.sender.address.toLowerCase();
const RECEIVER = m.pathway.receiver.address;
const GUID = m.guid;
const PAYLOAD = m.source.tx.payload;  // hex string

console.log('--- manual lz_receive ---');
console.log('endpoint :', ENV.LZ_ENDPOINT_STARKNET);
console.log('receiver :', RECEIVER);
console.log('src_eid  :', SRC_EID);
console.log('sender   :', SENDER_ADDR);
console.log('nonce    :', NONCE);
console.log('guid     :', GUID);
console.log('payload  :', PAYLOAD, `(${(PAYLOAD.length - 2) / 2} bytes)`);

// Account setup
const accounts = JSON.parse(readFileSync(join(ROOT, 'accounts.json'), 'utf8'));
const acct = accounts['alpha-sepolia']?.[ENV.STARKNET_ACCOUNT] || accounts['sepolia']?.[ENV.STARKNET_ACCOUNT];
if (!acct) { console.error('starknet account not in accounts.json'); process.exit(1); }

const provider = new RpcProvider({
  nodeUrl: ENV.STARKNET_RPC_URL,
  specVersion: '0.8.1',
  blockIdentifier: 'latest',
});
const account = new Account(provider, acct.address, acct.private_key);

// Pad sender to 32 bytes as Bytes32.value (u256)
const senderPadded = '0x' + SENDER_ADDR.replace(/^0x/, '').padStart(64, '0');

function u256split(big) {
  const MASK = (1n << 128n) - 1n;
  return { low: big & MASK, high: big >> 128n };
}

// Cairo ByteArray. For payloads <= 31 bytes, everything fits in pending_word.
function bytesToByteArray(hex) {
  const clean = hex.replace(/^0x/, '');
  const len = clean.length / 2;
  if (len > 31) throw new Error(`payload ${len} bytes > 31; multi-bytes31 ByteArray not yet supported`);
  return {
    data: [],
    pending_word: clean.length ? '0x' + clean : '0x0',
    pending_word_len: len,
  };
}

const calldata = CallData.compile([
  {
    src_eid: SRC_EID,
    sender: { value: u256split(BigInt(senderPadded)) },
    nonce: NONCE,
  },
  RECEIVER,
  { value: u256split(BigInt(GUID)) },
  bytesToByteArray(PAYLOAD),
  bytesToByteArray('0x'),       // extra_data: empty
  { low: 0n, high: 0n },        // value: 0
]);

console.log('signer   :', acct.address);
console.log('submitting…');
const r = await account.execute({
  contractAddress: ENV.LZ_ENDPOINT_STARKNET,
  entrypoint: 'lz_receive',
  calldata,
});
console.log('tx:', r.transaction_hash);
console.log('Voyager:', `https://sepolia.voyager.online/tx/${r.transaction_hash}`);
console.log('waiting for confirmation…');
const receipt = await provider.waitForTransaction(r.transaction_hash, { retryInterval: 5000 });
console.log('status:', receipt.execution_status || receipt.finality_status || receipt.status);
