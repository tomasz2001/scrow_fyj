<script setup lang="ts">
import { ref, onMounted } from "vue";
import { createActor } from "./bindings/backend";
import { getCanisterEnv } from "@icp-sdk/core/agent/canister-env";
import { HttpAgent } from "@icp-sdk/core/agent";
import { Principal } from "@icp-sdk/core/principal";
import { sha224 } from "@noble/hashes/sha2";
import QRCode from "qrcode";

interface CanisterEnv {
  readonly "PUBLIC_CANISTER_ID:backend": string;
}

const canisterEnv = getCanisterEnv<CanisterEnv>();
const canisterId = canisterEnv["PUBLIC_CANISTER_ID:backend"];

let backend = createActor(canisterId, {
  agentOptions: {
    rootKey: canisterEnv.IC_ROOT_KEY,
  },
});

function makeBackendWithIdentity(identity?: any) {
  if (!canisterId) throw new Error("Missing canisterId");
  if (identity) {
    const agent = HttpAgent.createSync({ identity, rootKey: canisterEnv.IC_ROOT_KEY });
    backend = createActor(canisterId, { agent });
  } else {
    // anonymous agent (use rootKey for local dev)
    backend = createActor(canisterId, { agentOptions: { rootKey: canisterEnv.IC_ROOT_KEY } });
  }
}

// Reactive state
const greeting = ref("");
const status = ref("");
const activePanel = ref("greet");
const isAuthenticated = ref(false);
const principalText = ref("anon");
let authClient: any = null;

const greetName = ref("");

// Account form
const pgp = ref("");
const wallet = ref("");
const kontakt = ref("");

// Escrow form
const middle = ref("");
const end = ref("");
// store user-entered ICP amounts as strings (allow decimals like "0.001")
const middle_drop = ref("");
const sylli_drop = ref("");

// Lookup / voting
const escrowId = ref(0);
const escrowData = ref<any | null>(null);

function parsePrincipal(text: string) {
  try {
    return Principal.fromText(text);
  } catch (e) {
    return null;
  }
}

function getIdentityProviderUrl() {
  const host = window.location.hostname;
  const isLocal = host === "localhost" || host === "127.0.0.1" || host.endsWith(".localhost");
  if (isLocal) return "http://id.ai.localhost:8000/authorize";
  return "https://id.ai/authorize";
}

function getIcpAccessAddress() {
  if (!canisterId) return "";
  return `https://tqais-zyaaa-aaaaj-qa6ca-cai.icp.net/`;
}

async function copyIcpAccessAddress() {
  if (!icpAccessUrl.value) return;
  try {
    await navigator.clipboard.writeText(icpAccessUrl.value);
    status.value = "ICP address copied to clipboard.";
  } catch (e) {
    status.value = "Copy failed. Please save the address manually.";
  }
}

onMounted(() => {
  const address = getIcpAccessAddress();
  if (address) {
    icpAccessUrl.value = address;
    showIcpSaveModal.value = true;
  }
});

async function initAuth() {
  try {
    const mod = await import('https://esm.sh/@icp-sdk/auth/client');
    const AuthClient = mod.AuthClient || mod.default?.AuthClient || mod.default;
    authClient = new AuthClient({ identityProvider: getIdentityProviderUrl() });
    if (authClient.isAuthenticated()) {
      const identity = await authClient.getIdentity();
      principalText.value = identity.getPrincipal().toText();
      isAuthenticated.value = true;
      // recreate backend actor with authenticated identity so backend sees caller
      makeBackendWithIdentity(identity);
    }
  } catch (e) {
    // ignore, we'll fall back to unauthenticated state
    console.warn("Auth client init failed", e);
  }
}

async function signIn() {
  if (!authClient) await initAuth();
  if (!authClient) {
    status.value = "Auth unavailable";
    return;
  }
  try {
    const identity = await authClient.signIn({ maxTimeToLive: BigInt(8) * BigInt(3_600_000_000_000) });
    principalText.value = identity.getPrincipal().toText();
    isAuthenticated.value = true;
    status.value = "Authenticated: " + principalText.value;
    // recreate backend actor with the authenticated identity
    makeBackendWithIdentity(identity);
  } catch (e) {
    status.value = "Login failed";
  }
}

async function signOut() {
  if (!authClient) {
    status.value = "Auth unavailable";
    return;
  }
  await authClient.signOut();
  isAuthenticated.value = false;
  principalText.value = "anon";
  status.value = "Logged out";
  // restore anonymous backend actor
  makeBackendWithIdentity(undefined);
}

async function doGreet(name: string) {
  try {
    greeting.value = await backend.greet(name);
  } catch (e) {
    status.value = String(e);
  }
}

async function doAccountEdit() {
  status.value = "Sending...";
  const p = parsePrincipal(wallet.value);
  if (!p) {
    status.value = "Invalid wallet principal";
    return;
  }
  try {
    const res = await backend.account_edit(pgp.value, p, kontakt.value);
    status.value = res;
  } catch (e) {
    status.value = String(e);
  }
}

async function doNewEscrow() {
  status.value = "Creating escrow...";
  const m = parsePrincipal(middle.value);
  const e = parsePrincipal(end.value);
  if (!m || !e) {
    status.value = "Invalid principal(s) for middle or end";
    return;
  }
  try {
    // parse user-entered ICP decimal strings into ledger units (e8s)
    const middleE8s = parseIcpToE8s(middle_drop.value || "0");
    const sylliE8s = parseIcpToE8s(sylli_drop.value || "0");
    const res = await backend.new_escrow(m, e, middleE8s, sylliE8s);
    status.value = res;
  } catch (err) {
    status.value = String(err);
  }
}

async function doGetEscrow() {
  status.value = "Fetching...";
  if (!canisterId) {
    status.value = "No backend canister id available";
    return;
  }
  try {
    // Try to detect arity of generated binding; fall back as needed.
    const fn: any = (backend as any).get_escrow;
    let res: any = null;
    if (typeof fn === "function") {
      try {
        if (fn.length === 0) {
          // binding expects no args
          res = await fn.call(backend);
        } else {
          // binding expects an id
          res = await fn.call(backend, BigInt(escrowId.value));
        }
      } catch (firstErr) {
        // fallback: try the other variant
        try {
          res = await fn.call(backend);
        } catch (secondErr) {
          try {
            res = await fn.call(backend, BigInt(escrowId.value));
          } catch (thirdErr) {
            throw firstErr;
          }
        }
      }
    } else {
      throw new Error("get_escrow method not found on backend actor");
    }
    escrowData.value = res;
    status.value = res ? "Escrow loaded" : "Escrow not found";
  } catch (e) {
    status.value = String(e);
  }
}

async function doVote(v: string) {
  status.value = "Voting...";
  try {
    const res = await backend.vote_escrow(BigInt(escrowId.value), v);
    status.value = res;
  } catch (e) {
    status.value = String(e);
  }
}

async function doLaw(v: string) {
  status.value = "Applying law...";
  try {
    const res = await backend.law_escrow(BigInt(escrowId.value), v);
    status.value = res;
  } catch (e) {
    status.value = String(e);
  }
}

// Helpers that use escrowData.wallet_id if available
async function doVoteWithFallback(v: string) {
  let id: bigint | null = null;
  if (escrowData.value && escrowData.value.wallet_id != null) {
    id = BigInt(escrowData.value.wallet_id);
  }
  if (!id) {
    status.value = 'No escrow loaded; press Load My Escrow first.';
    return;
  }
  status.value = 'Voting...';
  try {
    const res = await backend.vote_escrow(id, v);
    status.value = res;
  } catch (e) {
    status.value = String(e);
  }
}

async function doLawWithFallback(v: string) {
  let id: bigint | null = null;
  if (escrowData.value && escrowData.value.wallet_id != null) {
    id = BigInt(escrowData.value.wallet_id);
  }
  if (!id) {
    status.value = 'No escrow loaded; press Load My Escrow first.';
    return;
  }
  status.value = 'Applying law...';
  try {
    const res = await backend.law_escrow(id, v);
    status.value = res;
  } catch (e) {
    status.value = String(e);
  }
}

// Escrow fund / wallet panel
const fundAccount = ref<any | null>(null);
const fundBalance = ref<bigint | null>(null);
const fundAccountText = ref("");
const fundQr = ref("");
const fundAddress = ref("");
const fundAddressQr = ref("");

async function loadEscrowWallet() {
  status.value = "Fetching wallet...";
  try {
    const res = await backend.escrow_wallet();
    fundAccount.value = res;
    status.value = res ? "Wallet loaded" : "No wallet returned";
    if (res) {
      const ownerText = res.owner && typeof res.owner.toText === 'function' ? res.owner.toText() : String(res.owner);
      let subHex = "";
      if (res.subaccount) {
        subHex = bytesToHex(res.subaccount);
        if (subHex.length < 64) {
          subHex = subHex.padStart(64, '0');
        }
      } else {
        subHex = '0'.repeat(64);
      }
      fundAccountText.value = ownerText + '.' + subHex;

      try {
        const qrcode = await import('https://esm.sh/qrcode@1.5.1');
        if (qrcode && typeof qrcode.toDataURL === 'function') {
          fundQr.value = await qrcode.toDataURL(fundAccountText.value);
        }
      } catch (e) {
        console.warn('QR generation failed', e);
      }

      await computeAddress();
    } else {
      fundAccountText.value = "";
      fundQr.value = "";
      fundAddress.value = "";
      fundAddressQr.value = "";
    }
  } catch (e) {
    status.value = String(e);
  }
}

function natToSubaccountBytes(id: bigint): Uint8Array {
  const a = new Uint8Array(32);
  let v = id;
  for (let i = 0; i < 32; i++) {
    a[31 - i] = Number(v & BigInt(0xff));
    v = v >> BigInt(8);
  }
  return a;
}

function normalizeSubaccount(subaccount: Uint8Array | number[] | null | undefined): Uint8Array {
  if (!subaccount) return new Uint8Array(32);
  const arr = subaccount instanceof Uint8Array ? subaccount : Uint8Array.from(subaccount as number[]);
  const out = new Uint8Array(32);
  const start = Math.max(0, 32 - arr.length);
  out.set(arr.slice(Math.max(0, arr.length - 32)), start);
  return out;
}

function generateAccountIdentifierFromPrincipalAndSubaccount(principalText: string, subaccount?: Uint8Array | number[] | null) {
  const principal = Principal.fromText(principalText);
  const principalBytes = principal.toUint8Array();
  const sub = normalizeSubaccount(subaccount);
  const sep = new Uint8Array([0x0a, ...new TextEncoder().encode("account-id")]);
  const combined = new Uint8Array(sep.length + principalBytes.length + sub.length);
  combined.set(sep, 0);
  combined.set(principalBytes, sep.length);
  combined.set(sub, sep.length + principalBytes.length);

  const hash = sha224(combined);

  const crcTable = new Uint32Array(256);
  for (let i = 0; i < 256; i++) {
    let c = i;
    for (let k = 0; k < 8; k++) {
      if (c & 1) c = 0xedb88320 ^ (c >>> 1);
      else c = c >>> 1;
    }
    crcTable[i] = c >>> 0;
  }

  let crc = 0xffffffff >>> 0;
  for (let i = 0; i < hash.length; i++) {
    const b = hash[i];
    crc = (crc >>> 8) ^ crcTable[(crc ^ b) & 0xff];
  }
  crc = (crc ^ 0xffffffff) >>> 0;

  const checksum = new Uint8Array(4);
  checksum[0] = (crc >>> 24) & 0xff;
  checksum[1] = (crc >>> 16) & 0xff;
  checksum[2] = (crc >>> 8) & 0xff;
  checksum[3] = crc & 0xff;

  const accountIdBytes = new Uint8Array(4 + hash.length);
  accountIdBytes.set(checksum, 0);
  accountIdBytes.set(hash, 4);

  return Array.from(accountIdBytes).map((b) => ("0" + (b & 0xff).toString(16)).slice(-2)).join("");
}

async function computeAddress() {
  if (!fundAccount.value) {
    status.value = "No escrow wallet loaded";
    return;
  }

  status.value = "Computing address...";
  try {
    const ownerText = fundAccount.value.owner && typeof fundAccount.value.owner.toText === 'function' ? fundAccount.value.owner.toText() : String(fundAccount.value.owner);
    let sub: Uint8Array | null = null;
    if (fundAccount.value.subaccount) {
      sub = fundAccount.value.subaccount instanceof Uint8Array ? fundAccount.value.subaccount : Uint8Array.from(fundAccount.value.subaccount);
    } else if (escrowData.value && escrowData.value.wallet_id != null) {
      sub = natToSubaccountBytes(BigInt(escrowData.value.wallet_id));
    } else {
      sub = new Uint8Array(32);
    }

    fundAddress.value = generateAccountIdentifierFromPrincipalAndSubaccount(ownerText, sub);

    try {
      const qrcode = await import('https://esm.sh/qrcode@1.5.1');
      if (qrcode && typeof qrcode.toDataURL === 'function') {
        fundAddressQr.value = await qrcode.toDataURL(fundAddress.value);
      }
    } catch (e) {
      console.warn('QR generation failed', e);
    }

    status.value = 'Address computed';
  } catch (e) {
    status.value = String(e);
  }
}

async function loadEscrowBalance() {
  status.value = "Fetching balance...";
  try {
    const res = await backend.escrow_balance();
    fundBalance.value = res;
    status.value = "Balance loaded";
  } catch (e) {
    status.value = String(e);
  }
}

function bytesToHex(arr: Uint8Array | number[] | null | undefined) {
  if (!arr) return "";
  const u8 = arr instanceof Uint8Array ? arr : Uint8Array.from(arr as number[]);
  return Array.from(u8).map((b) => ("0" + (b & 0xff).toString(16)).slice(-2)).join("");
}

// ICP formatting / parsing utilities
const E8S_PER_ICP = BigInt(100_000_000);

function formatIcpFromE8s(val: bigint | number | null | undefined, decimals = 3) {
  if (val == null) return "0";
  let v: bigint;
  try {
    v = typeof val === 'bigint' ? val : BigInt(val as any);
  } catch (e) {
    return "0";
  }
  const whole = v / E8S_PER_ICP;
  const frac = v % E8S_PER_ICP;
  const fracStrFull = frac.toString().padStart(8, '0');
  const fracDisplay = fracStrFull.slice(0, decimals).padEnd(decimals, '0');
  // remove trailing zeros if decimals==0 not expected; keep fixed decimals as requested
  return `${whole.toString()}.${fracDisplay}`;
}

function parseIcpToE8s(input: string | number): bigint {
  const s = String(input).trim();
  if (s === "" || s === "NaN") return BigInt(0);
  if (!s.includes('.')) {
    return BigInt(s) * E8S_PER_ICP;
  }
  const [whole, frac] = s.split('.');
  const fracPadded = (frac + '00000000').slice(0, 8);
  const wholePart = BigInt(whole || '0') * E8S_PER_ICP;
  const fracPart = BigInt(fracPadded);
  return wholePart + fracPart;
}

// Check user panel
const lookupPrincipal = ref("");
const checkedUser = ref<any | null>(null);
async function doCheckUser() {
  status.value = "Checking...";
  const p = parsePrincipal(lookupPrincipal.value);
  if (!p) {
    status.value = "Invalid principal";
    return;
  }
  try {
    const res = await backend.get_account(p);
    checkedUser.value = res;
    status.value = res ? "User found" : "User not found";
  } catch (e) {
    status.value = String(e);
  }
}

</script>

<template>
  <main>
    <div v-if="showIcpSaveModal" class="modal-backdrop" @click.self="showIcpSaveModal = false">
      <div class="modal-box">
        <h2>Save the ICP address</h2>
        <p>
          This is the ICP access address for the platform, not the scrow.fyi domain.
          Save it, because if the domain disappears, you will still have access to the app.
        </p>
        <div class="modal-address">{{ icpAccessUrl }}</div>
        <div class="controls modal-controls">
          <button class="button" @click="copyIcpAccessAddress">Copy address</button>
          <button class="button" @click="showIcpSaveModal = false">Close</button>
        </div>
      </div>
    </div>

    <div class="app-layout">
      <aside class="sidebar">
        <h1 style="margin: 0; font-size: 30px;">scrow.fyi</h1>
        <div class="side-info">welcome: <div class="mono">{{ principalText }}</div></div>
        <nav class="side-nav">
          <button class="nav" @click="activePanel='greet'">Greet</button>
          <button class="nav" @click="activePanel='account'">Account</button>
          <button class="nav" @click="activePanel='check'">Check User</button>
          <button class="nav" @click="activePanel='new'">New Escrow</button>
          <button class="nav" @click="activePanel='preview'">Preview Escrow</button>
          <button class="nav" @click="activePanel='fund'">Escrow Fund</button>
          <button class="nav" @click="activePanel='vote'">Vote Escrow</button>
          <button class="nav" @click="activePanel='terms'">Terms</button>
        </nav>
        <div class="side-actions">
          <button @click="signIn" v-show="!isAuthenticated">LOG-IN</button>
          <button @click="signOut" v-show="isAuthenticated">LOG-OUT</button>
        </div>
      </aside>

      <section class="content">
        <section class="panel">
          <h1 class="title">scrow.fyi</h1>
          <p class="subtitle">Interact with the backend canister</p>

          <section class="card" v-show="activePanel==='greet'">
        <h2>How to go</h2>
        <div class="output" style="text-align:left; max-width:800px; margin:0 auto;">
          <p>Scrow.fyi is a platform powered entirely by native ICP coins, where you choose the arbiter, and the blockchain ensures they can’t run off with all the cash.</p>
          <p>To get the party started, log in using your Internet Identity. A Gmail account will do if you're a pleb who can't afford a U2F hardware key.</p>
          <p>Go to the Account tab and enter your public PGP key along with your ICP wallet Principal (e.g., pulled from Oisy Wallet). Note: whatever is displayed after "Welcome" is NOT your wallet address! Politely fetch your Principal from Oisy and bring it back in your teeth.</p>
          <p>Force your vendors/junkies—err, I mean friends—to do the same. Pro tip: firearms might come in handy here; otherwise, a standard kitchen knife will do.</p>
          <p>Verify them via the Check User tab using the Principal shown after their "Welcome" screen.</p>
          <p>Now, let's create an escrow (all transactions run on ICP tokens):</p>
          <p>Start (Creator): the one putting up the funds in ICP.<br />Middle (Arbiter): the dispute resolver.<br />End (Recipient): the guy who theoretically gets the cash.</p>
          <p>Tips:<br />Middle drop: tip / fee for the arbiter in ICP.<br />Sylli drop: donation for me—come on, throw me some ICP, don't be a cheapskate.</p>
          <p>To check the current status, head to Preview Escrow, and use Vote Escrow to cast your vote. The transaction triggers only when at least 2 out of 3 parties vote for the exact same option.</p>
          <p>You can figure out the rest. I have my own needs to attend to and need to get blasted like a Messerschmitt.</p>
        </div>
      </section>

      <section class="card" v-show="activePanel==='account'">
        <h2>Account (create / edit)</h2>
        <label>PGP</label>
        <textarea v-model="pgp" rows="6" placeholder="Paste your PGP key"></textarea>
        <label>Wallet principal</label>
        <input v-model="wallet" placeholder="principal text" />
        <label>Kontakt</label>
        <input v-model="kontakt" />
        <div class="controls">
          <button class="button" @click="doAccountEdit">Save Account</button>
        </div>
      </section>

      <section class="card" v-show="activePanel==='check'">
        <h2>Check User</h2>
        <label>Principal to check</label>
        <input v-model="lookupPrincipal" placeholder="principal text" />
        <div class="controls">
          <button class="button" @click="doCheckUser">Check</button>
        </div>
        <div class="output" v-if="checkedUser">
          <div><strong>PGP:</strong> {{ checkedUser.pgp }}</div>
          <div><strong>Wallet:</strong> {{ checkedUser.wallet }}</div>
          <div><strong>Kontakt:</strong> {{ checkedUser.kontakt }}</div>
          <div><strong>Escrow id:</strong> {{ checkedUser.escrow }}</div>
        </div>
        <div class="output" v-else>No user loaded.</div>
      </section>

          <section class="card" v-show="activePanel==='new'">
        <h2>Create Escrow</h2>
        <label>Middle principal</label>
        <input v-model="middle" placeholder="principal text" />
        <label>End principal</label>
        <input v-model="end" placeholder="principal text" />
        <label>Middle drop (ICP)</label>
        <input type="text" v-model="middle_drop" placeholder="e.g., 0.001" />
        <label>Sylli drop (ICP)</label>
        <input type="text" v-model="sylli_drop" placeholder="e.g., 0.001" />
        <div class="controls">
          <button class="button" @click="doNewEscrow">Create Escrow</button>
        </div>
      </section>

          <section class="card" v-show="activePanel==='preview'">
            <h2>Escrow Preview</h2>
            <div class="controls">
              <button class="button" @click="doGetEscrow">Load My Escrow</button>
            </div>
            <div class="output" v-if="escrowData">
              <div><strong>Start:</strong> {{ escrowData.start }}</div>
              <div><strong>Middle:</strong> {{ escrowData.middle }}</div>
              <div><strong>End:</strong> {{ escrowData.end }}</div>
              <div><strong>State:</strong> {{ escrowData.state }}</div>
              <div><strong>Start vote:</strong> {{ escrowData.start_vote }}</div>
              <div><strong>Middle vote:</strong> {{ escrowData.middle_vote }}</div>
              <div><strong>End vote:</strong> {{ escrowData.end_vote }}</div>
              <div><strong>Wallet id:</strong> {{ escrowData.wallet_id }}</div>
              <div><strong>Middle drop:</strong> {{ formatIcpFromE8s(escrowData.middle_drop) }} ICP</div>
              <div><strong>Sylli drop:</strong> {{ formatIcpFromE8s(escrowData.sylli_drop) }} ICP</div>
            </div>
            <div v-else class="output">No escrow loaded. Press "Load My Escrow".</div>
          </section>

          <section class="card" v-show="activePanel==='fund'">
            <h2>Escrow Fund</h2>
            <div class="controls">
              <button class="button" @click="loadEscrowWallet">Load Escrow Wallet</button>
              <button class="button" @click="loadEscrowBalance">Load Escrow Balance</button>
            </div>

            <div class="output">
              <div v-if="fundAccountText"><strong>Account (canonical):</strong>
                <pre style="white-space:pre-wrap">{{ fundAccountText }}</pre>
              </div>
              <div v-if="fundAddress"><strong>Account Identifier:</strong>
                <pre style="white-space:pre-wrap">{{ fundAddress }}</pre>
              </div>
              <div v-if="fundAddressQr" style="margin-top:8px"><strong>Account QR:</strong><div><img :src="fundAddressQr" alt="account-qr" /></div></div>
              <div v-if="fundBalance !== null"><strong>Balance:</strong> {{ formatIcpFromE8s(fundBalance) }} ICP</div>
              <div v-if="!fundAccount">No wallet data. Press "Load Escrow Wallet" to generate the escrow address automatically.</div>
            </div>
          </section>

          <section class="card" v-show="activePanel==='vote'">
            <h2>Escrow Voting</h2>
            <div class="output" v-if="escrowData">
              <div><strong>Escrow for:</strong> {{ escrowData.start }} → {{ escrowData.end }}</div>
              <div><strong>State:</strong> {{ escrowData.state }}</div>
            </div>
            <div v-else class="output">No escrow loaded. Go to Preview and load your escrow first.</div>
            <div class="controls">
              <button class="button" @click="doVoteWithFallback('frezze')">Vote: frezze</button>
              <button class="button" @click="doVoteWithFallback('refund')">Vote: refund</button>
              <button class="button" @click="doVoteWithFallback('done')">Vote: done</button>
            </div>
            <div class="controls">
              <button class="button" @click="doLawWithFallback('frezze')">Apply: frezze</button>
              <button class="button" @click="doLawWithFallback('refund')">Apply: refund</button>
              <button class="button" @click="doLawWithFallback('done')">Apply: done</button>
            </div>
          </section>

          <section class="card" v-show="activePanel==='terms'">
            <h2>Terms & Rules</h2>
            <div class="output" style="text-align:left; max-width:900px; margin:0 auto;">
              <h3>LEGAL DISCLAIMER & SCROW.FYI PROTOCOL TERMS OF SERVICE</h3>
              <p><em>MiCA Exemption Notice</em></p>

              <section>
                <h4>1. Regulatory Status & MiCA Safe Harbor Exemption</h4>
                <p>This graphical interface (hosted at scrow.fyi) is a non-custodial, open-source UI for interacting with immutable smart contracts (canisters) on the Internet Computer Protocol (ICP). The developer is not a Crypto-Asset Service Provider (CASP) under Regulation (EU) 2023/1114 (MiCA) and does not offer custody, exchange, or brokerage services.</p>
              </section>

              <section>
                <h4>2. Absolute Disclaimer of Transaction Liability</h4>
                <p>The developer is not a party, guarantor, or escrow agent in user transactions. The developer is not liable for the nature, legality, or execution of any transaction — legal responsibility lies with the interacting peers and their agreed third-party arbiter (Tower).</p>
              </section>

              <section>
                <h4>3. "Sylli Drop" Contributions (Donations)</h4>
                <p>Any transfer designated as a "Sylli Drop" is an unconditional, irrevocable, non-refundable voluntary donation governed by Article 888 et seq. of the Polish Civil Code. Donations are transferred to the Developer's account and may be spent at the Developer’s sole discretion. Donations are not fees, commissions, or custodial deposits. Donors waive rights to restitution or refunds.</p>
              </section>

              <section>
                <h4>4. Zero-KYC Architecture & Data Purging</h4>
                <p>No KYC/AML data is collected or stored. To minimize state usage, identity placeholders and transactional records are permanently removed from canister memory immediately after execution or refund.</p>
              </section>

              <section>
                <h4>5. Technological Risks, Immutability & Autonomy</h4>
                <p>Despite testing, the software may contain bugs or vulnerabilities. Once released and administrative privileges are renounced (blackholed), the canister becomes immutable and autonomous. The Developer cannot modify code, patch bugs, or rescue funds — users accept this risk.</p>
              </section>

              <section>
                <h4>6. Third-Party Forks and Modifications</h4>
                <p>The protocol is open-source. The Developer is not responsible for forks, clones, or third-party deployments and disclaims liability for their actions or vulnerabilities.</p>
              </section>

              <section>
                <h4>7. User Eligibility & Legal Capacity</h4>
                <p>By using the Protocol, the user represents they are of legal age and have the legal capacity to enter binding agreements in their jurisdiction.</p>
              </section>

              <section>
                <h4>8. Limitation of Liability & "As-Is" Provision</h4>
                <p>The software is provided "AS-IS" and "AS-AVAILABLE" without warranties. To the fullest extent permitted by law, the Developer disclaims liability for any damages arising from use. These Terms are final and immutable.</p>
              </section>

              <p style="margin-top:1rem; font-size:0.9em; color:var(--muted)">Basic, [17.08.2026 13:47]</p>
            </div>
          </section>

          <section class="status">
            <strong>Status:</strong> {{ status }}</section>
        </section>
      </section>
    </div>
  </main>
</template>

<style>
@import url('https://fonts.googleapis.com/css2?family=Press+Start+2P&display=swap');

body, #app {
  background-color: black;
  color: white;
  text-align: center;
  font-size: 16px;
  line-height: 1.5;
  font-family: 'Press Start 2P', monospace;
  font-weight: normal;
  font-style: normal;
}

body, #app,
h1, h2, h3, h4, h5, h6,
p, li, label, div, span,
strong, b, em, i,
input, textarea, select, button,
.logo, .mono, .side-info, .canister,
.status, .output, .title, .subtitle,
.nav, .brand .plus {
  font-weight: normal !important;
}

h2, h3, h4, h5, h6 {
  margin: 0 0 0.5rem;
  font-family: 'Press Start 2P', monospace;
  font-size: 20px;
  line-height: 1.25;
  letter-spacing: 0.02em;
  font-style: normal;
}

h1 {
  margin: 0 0 0.5rem;
  font-family: 'Press Start 2P', monospace;
  font-size: 60px;
  line-height: 1.25;
  letter-spacing: 0.02em;
  font-style: normal;
}

p, li, label, .output, .status, .side-info, .canister {
  font-size: 1em;
}

em, i {
  font-style: italic;
}

input,
textarea,
select,
button {
    background-color: #000;
    border: 2px solid #ff0000;
    color: #fff;
    padding: 10px;
    border-radius: 5px;
    font-family: 'Press Start 2P', monospace;
}

input[type="text"], textarea { display: block; width: 60%; max-width: 560px; margin: 0.25rem auto; box-sizing: border-box; }
label { display: block; width: 60%; max-width: 560px; margin: 0.25rem auto; text-align: left; }
input::placeholder,
textarea::placeholder { color: #aaa; }

input:focus,
textarea:focus,
select:focus {
    outline: none;
    border-color: #ff3333;
    box-shadow: 0 0 8px #ff0000;
}

button { cursor: pointer; }
button:hover { background-color: #222; }

.panel { max-width: 900px; margin: 0 auto; padding: 12px; }
.card { background: transparent; margin: 8px 0; padding: 8px; border: none; }
.controls { margin-top: 6px; display:flex; gap:8px; flex-wrap:wrap; justify-content:center; }
.output { margin-top: 6px; color: #ddd; }
/* Make long panels scrollable and allow reaching the top */
.panel { overflow: auto; max-height: calc(100vh - 80px); }
.output { overflow-y: auto; max-height: 60vh; padding-right: 8px; }
.status { margin-top: 12px; color: #f3f3f3; }

pre { text-align:left; max-width: 90%; margin: 8px auto; color: #ddd; }

/* Enforce strict black+red palette and remove default blue focus */
button, input, textarea {
  background: #000 !important;
  color: #fff !important;
  border-color: #ff0000 !important;
}

button:focus, input:focus, textarea:focus {
  outline: none !important;
  box-shadow: 0 0 8px #ff0000 !important;
  border-color: #ff0000 !important;
}

button:active { background: #000 !important; }

.nav { margin: 0 6px; }

.modal-backdrop {
  position: fixed;
  inset: 0;
  background: rgba(0, 0, 0, 0.8);
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 1000;
  padding: 20px;
}

.modal-box {
  width: min(620px, 92vw);
  background: #0a0a0a;
  border: 2px solid #ff0000;
  box-shadow: 0 0 20px rgba(255, 0, 0, 0.45);
  padding: 22px 20px;
  text-align: center;
}

.modal-box h2 {
  margin-bottom: 12px;
}

.modal-box p {
  color: #f1f1f1;
  line-height: 1.8;
  margin-bottom: 16px;
}

.modal-address {
  background: #111;
  border: 1px solid #ff3b3b;
  padding: 12px 14px;
  margin: 12px 0 18px;
  color: #fff;
  word-break: break-all;
  font-size: 0.82rem;
  line-height: 1.7;
}

.modal-controls {
  justify-content: center;
}

</style>

<style>
/* Layout for 16:9 single-screen display */
.app-layout { display:flex; height: calc(100vh - 24px); gap: 12px; }
.sidebar { width: 300px; min-width: 260px; padding: 12px; display:flex; flex-direction:column; align-items:flex-start; gap:12px; border-right: 1px solid rgba(255,255,255,0.04); }
.side-info { font-size: 13px; color:#ddd; font-weight: 300; }
.mono { font-family: 'Press Start 2P', monospace; color:#ffdddd; font-weight: 400; }
.side-nav { display:flex; flex-direction:column; gap:8px; width:100%; }
.side-nav .nav { width:100%; text-align:left; padding:8px 10px; }
.side-actions { margin-top:auto; display:flex; gap:8px; }
.canister { font-size:12px; color:#bbb; }
.content { flex:1; overflow:auto; display:flex; align-items:flex-start; justify-content:center; padding-top:12px; padding-bottom:12px; }
.content .panel { width: 100%; max-width: 980px; }

/* Ensure controls don't wrap awkwardly */
.controls { justify-content:flex-start; }

/* Responsive rules: stack sidebar on small screens and center controls */
@media (max-width: 900px) {
  .app-layout { flex-direction: column; height: auto; }
  .sidebar { width: 100%; min-width: auto; border-right: none; border-bottom: 1px solid rgba(255,255,255,0.06); padding: 10px; align-items: center; }
  .side-nav { flex-direction: row; flex-wrap: wrap; gap:6px; justify-content:center; }
  .side-nav .nav { width: auto; padding: 8px 12px; text-align:center; }
  .content { align-items:flex-start; padding-top: 8px; }
  .panel { max-width: 100%; padding: 10px; }
  input[type="text"], textarea { width: 90%; max-width: 100%; }
  .controls { justify-content: center; }
  .output { max-height: 50vh; overflow-y: auto; }
}

@media (max-width: 420px) {
  h1.title { font-size: 1.4rem; }
  .sidebar { padding: 8px; }
  .nav { font-size: 0.95rem; padding: 8px; }
}

</style>
