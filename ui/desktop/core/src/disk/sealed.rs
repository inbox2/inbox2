//! Sealed Disk format (inbox2-internal docs/plans/disk-build.md section 6),
//! byte for byte the same as the web client (`ui/web/src/lib/disk/crypto.js`).
//!
//! Covered: the 6.3 encoding (`ad`, `kdf`, envelopes), the 6.4 keys, the 6.5
//! records (key grant, epoch chain, name and type, version key, manifest), the
//! 6.6 content chunks with streaming seal/open, plaintext sizes, chunk sizes and
//! client-proposed ids. Not covered (no caller yet): thumbnails and renditions,
//! public links (6.9), sealed pages (6.10), rotation bodies (6.7).
//!
//! Proven against `testdata/disk_vectors.json`, a copy of the web client's
//! `lib/disk/__tests__/vectors.json`. Key material lives in [`Zeroizing`] and is
//! never logged.

use std::io::{ErrorKind, Read, Write};

use base64::Engine as _;
use blake2::digest::consts::U32;
use blake2::digest::{Digest, Mac};
use blake2::{Blake2b, Blake2bMac};
use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{XChaCha20Poly1305, XNonce};
use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

const B64: base64::engine::general_purpose::GeneralPurpose = base64::engine::general_purpose::STANDARD;

/// A 32-byte key, wiped on drop.
pub type Key = Zeroizing<[u8; 32]>;

pub const TAG_BYTES: usize = 16;
pub const ENV_VERSION: u8 = 0x01;
/// Shortest valid envelope: version byte, 24-byte nonce, 16-byte tag.
pub const ENV_MIN: usize = 1 + 24 + TAG_BYTES;
/// Build guide section 1: 1 MiB chunks for audio and video, 4 MiB otherwise.
pub const CHUNK_MEDIA: usize = 1024 * 1024;
pub const CHUNK_DEFAULT: usize = 4 * 1024 * 1024;
/// Largest chunk the opener will buffer. The web client writes at most 4 MiB.
const CHUNK_MAX: u64 = 64 * 1024 * 1024;
/// JS `Number.MAX_SAFE_INTEGER`: the web client refuses manifest numbers above it.
const MAX_SAFE: u64 = (1 << 53) - 1;

/// The labels of 6.4-6.6.
pub mod label {
    pub const EPOCH: &str = "disk/epoch/v1";
    pub const META: &str = "disk/meta/v1";
    pub const WRAP: &str = "disk/wrap/v1";
    pub const PAGE: &str = "disk/page/v1";
    pub const CONTENT: &str = "disk/content/v1";
    pub const MANIFEST: &str = "disk/manifest/v1";
    pub const THUMB: &str = "disk/thumb/v1";
    pub const RENDITION: &str = "disk/rendition/v1";
    pub const CHUNK: &str = "disk/chunk/v1";
}

#[derive(Debug, thiserror::Error)]
pub enum SealError {
    /// The data does not open or fails a format check. Never carries key bytes.
    #[error("sealed disk: {0}")]
    Refused(String),
    #[error("sealed disk: {0}")]
    Io(#[from] std::io::Error),
}

pub type Result<T> = std::result::Result<T, SealError>;

fn refuse<T>(why: impl Into<String>) -> Result<T> {
    Err(SealError::Refused(why.into()))
}

fn key32(bytes: &[u8], what: &str) -> Result<Key> {
    let mut k = Zeroizing::new([0u8; 32]);
    if bytes.len() != 32 {
        return refuse(format!("{what} is not a 32-byte key"));
    }
    k.copy_from_slice(bytes);
    Ok(k)
}

// ── randomness (6.3: every random value from the OS CSPRNG) ─────────────────

#[cfg(test)]
thread_local! {
    static FIXED: std::cell::RefCell<Option<std::collections::VecDeque<Vec<u8>>>> = const { std::cell::RefCell::new(None) };
}

/// Test only (mirrors `setRandomForTests`): the next random draws on this
/// thread come from `queue` in order, each of exactly the length asked for.
/// `None` goes back to the OS CSPRNG.
#[cfg(test)]
pub fn set_random_for_tests(queue: Option<Vec<Vec<u8>>>) {
    FIXED.with(|f| *f.borrow_mut() = queue.map(Into::into));
}

fn random<const N: usize>() -> Zeroizing<[u8; N]> {
    let mut out = Zeroizing::new([0u8; N]);
    #[cfg(test)]
    {
        let fixed = FIXED.with(|f| f.borrow_mut().as_mut().map(|q| q.pop_front()));
        if let Some(next) = fixed {
            let next = next.expect("fixed random source ran dry");
            assert_eq!(next.len(), N, "fixed random source: wanted {N} bytes");
            out.copy_from_slice(&next);
            return out;
        }
    }
    rand::RngCore::fill_bytes(&mut rand::rngs::OsRng, out.as_mut());
    out
}

/// A fresh 32-byte key (a scope key or a version key).
pub fn new_key() -> Key {
    random::<32>()
}

/// A fresh 16-byte chunk nonce prefix, one per version key (6.6).
pub fn new_prefix() -> [u8; 16] {
    *random::<16>()
}

// ── 6.3 encoding ────────────────────────────────────────────────────────────

/// One `AD()` field (6.3).
#[derive(Debug, Clone, Copy)]
pub enum Field<'a> {
    /// A public id (`dnd_…`, `dvr_…`): its UTF-8.
    Id(&'a str),
    /// An integer: 8-byte big endian.
    Int(u64),
    /// A flag: one byte, 0 or 1.
    Flag(bool),
    /// Raw bytes (a salt, a key).
    Bytes(&'a [u8]),
}

/// `utf8(label) || 0x00`, then `u16be(len) || bytes` per field. Refuses a field
/// over 65535 bytes, as the JS does.
pub fn ad(label: &str, fields: &[Field]) -> Result<Vec<u8>> {
    let mut out = Vec::with_capacity(label.len() + 1 + fields.len() * 34);
    out.extend_from_slice(label.as_bytes());
    out.push(0);
    for f in fields {
        let (int, flag);
        let bytes: &[u8] = match f {
            Field::Id(s) => s.as_bytes(),
            Field::Int(n) => {
                int = n.to_be_bytes();
                &int
            }
            Field::Flag(b) => {
                flag = [*b as u8];
                &flag
            }
            Field::Bytes(b) => b,
        };
        let Ok(len) = u16::try_from(bytes.len()) else { return refuse("AD field over 65535 bytes") };
        out.extend_from_slice(&len.to_be_bytes());
        out.extend_from_slice(bytes);
    }
    Ok(out)
}

/// `KDF(key, label)` = keyed BLAKE2b-256 of the label (libsodium `crypto_generichash`).
pub fn kdf(key: &[u8], label: &str) -> Key {
    let mut mac = <Blake2bMac<U32> as KeyInit>::new_from_slice(key).expect("BLAKE2b key is 1..=64 bytes");
    Mac::update(&mut mac, label.as_bytes());
    let mut out = Zeroizing::new([0u8; 32]);
    out.copy_from_slice(&mac.finalize().into_bytes());
    out
}

fn aead(key: &[u8; 32]) -> XChaCha20Poly1305 {
    XChaCha20Poly1305::new(key.into())
}

/// `ENV(key, ad, plaintext)`: `0x01 || nonce(24, random) || xchacha20poly1305-ietf`.
pub fn env_seal(key: &[u8; 32], ad: &[u8], plaintext: &[u8]) -> Vec<u8> {
    let nonce = random::<24>();
    let ct = aead(key)
        .encrypt(XNonce::from_slice(nonce.as_ref()), Payload { msg: plaintext, aad: ad })
        .expect("XChaCha20-Poly1305 encrypt");
    let mut out = Vec::with_capacity(25 + ct.len());
    out.push(ENV_VERSION);
    out.extend_from_slice(nonce.as_ref());
    out.extend_from_slice(&ct);
    out
}

/// Opens an envelope. Refuses a short one, an unknown version byte and any
/// authentication failure.
pub fn env_open(key: &[u8; 32], ad: &[u8], env: &[u8]) -> Result<Zeroizing<Vec<u8>>> {
    if env.len() < ENV_MIN {
        return refuse("envelope too short");
    }
    if env[0] != ENV_VERSION {
        return refuse("unknown envelope version");
    }
    match aead(key).decrypt(XNonce::from_slice(&env[1..25]), Payload { msg: &env[25..], aad: ad }) {
        Ok(plain) => Ok(Zeroizing::new(plain)),
        Err(_) => refuse("envelope failed authentication"),
    }
}

// Sealed JSON (6.3): keys sorted, no whitespace, raw UTF-8, JSON.stringify
// escaping. Every sealed JSON here is a struct with its fields declared in
// sorted order; serde_json writes struct fields in declaration order and
// escapes strings exactly as JSON.stringify does (`"`, `\`, \b \f \n \r \t,
// other controls as lowercase \u00xx; `/`, U+007F, U+2028/9 and non-ASCII raw).
// A test pins that.
fn json<T: Serialize>(v: &T) -> Zeroizing<Vec<u8>> {
    Zeroizing::new(serde_json::to_vec(v).expect("struct serialises"))
}

fn parse<'a, T: Deserialize<'a>>(bytes: &'a [u8]) -> Result<T> {
    serde_json::from_slice(bytes).or_else(|_| refuse("sealed JSON is not valid"))
}

// ── 6.4 keys ────────────────────────────────────────────────────────────────

/// The keys derived from a scope key `K_s[e]`, which is never used directly.
pub struct ScopeKeys {
    /// Wraps the previous epoch's key.
    pub e: Key,
    /// Seals names and types.
    pub m: Key,
    /// Wraps version keys.
    pub w: Key,
    /// Seals page snapshots and updates.
    pub p: Key,
}

impl ScopeKeys {
    pub fn derive(ks: &[u8; 32]) -> Self {
        Self { e: kdf(ks, label::EPOCH), m: kdf(ks, label::META), w: kdf(ks, label::WRAP), p: kdf(ks, label::PAGE) }
    }
}

/// The keys derived from a version key `K_v`.
pub struct VersionKeys {
    /// Content chunks.
    pub c: Key,
    /// Manifest.
    pub f: Key,
    /// Thumbnail.
    pub t: Key,
    /// Rendition.
    pub r: Key,
}

impl VersionKeys {
    pub fn derive(kv: &[u8; 32]) -> Self {
        Self { c: kdf(kv, label::CONTENT), f: kdf(kv, label::MANIFEST), t: kdf(kv, label::THUMB), r: kdf(kv, label::RENDITION) }
    }
}

// ── 6.5 records ─────────────────────────────────────────────────────────────

/// Opens `disk_key_grants.sealed_key` (a libsodium sealed box) with the member's
/// X25519 identity secret key; the public key is derived from it. Returns `K_s[e]`.
pub fn open_key_grant(sealed_key: &[u8], identity_secret: &[u8; 32]) -> Result<Key> {
    let sk = crypto_box::SecretKey::from(*identity_secret);
    let Ok(plain) = sk.unseal(sealed_key) else { return refuse("key grant does not open with this identity") };
    key32(&Zeroizing::new(plain), "key grant")
}

/// `disk_scope_epochs.previous_key_wrapped` for epoch `epoch` (>= 2), under
/// `E[epoch]` (`ScopeKeys::derive(K_s[epoch]).e`).
pub fn wrap_previous_key(e_key: &[u8; 32], scope_id: &str, epoch: u64, previous: &[u8; 32]) -> Result<Vec<u8>> {
    if epoch < 2 {
        return refuse("epoch 1 has no previous key");
    }
    Ok(env_seal(e_key, &ad(label::EPOCH, &[Field::Id(scope_id), Field::Int(epoch - 1)])?, previous))
}

/// Opens `previous_key_wrapped` of epoch `epoch` to `K_s[epoch - 1]`.
pub fn unwrap_previous_key(e_key: &[u8; 32], scope_id: &str, epoch: u64, wrapped: &[u8]) -> Result<Key> {
    if epoch < 2 {
        return refuse("epoch 1 has no previous key");
    }
    let plain = env_open(e_key, &ad(label::EPOCH, &[Field::Id(scope_id), Field::Int(epoch - 1)])?, wrapped)?;
    key32(&plain, "previous epoch key")
}

/// Walks back from the newest key held (`ks` = `K_s[epoch]`) to `K_s[target]`.
/// `chain(e)` returns `previous_key_wrapped` of epoch `e`, or `None` if missing.
pub fn walk_epochs(
    ks: &[u8; 32],
    epoch: u64,
    target: u64,
    scope_id: &str,
    chain: impl Fn(u64) -> Option<Vec<u8>>,
) -> Result<Key> {
    if target > epoch || target < 1 {
        return refuse(format!("epoch {target} is not reachable from {epoch}"));
    }
    let mut k = Zeroizing::new(*ks);
    for e in (target + 1..=epoch).rev() {
        let Some(wrapped) = chain(e) else { return refuse(format!("epoch {e} is not in the chain")) };
        k = unwrap_previous_key(&kdf(k.as_ref(), label::EPOCH), scope_id, e, &wrapped)?;
    }
    Ok(k)
}

/// A node's name and type. `mime` is `None` for folders and pages.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Meta {
    pub name: String,
    pub mime: Option<String>,
}

#[derive(Serialize, Deserialize)]
struct MetaJson<'a> {
    // Sorted field order is the canonical key order.
    #[serde(borrow, default)]
    mime: Option<std::borrow::Cow<'a, str>>,
    #[serde(borrow)]
    name: std::borrow::Cow<'a, str>,
}

/// `disk_nodes.metadata_ciphertext` under `M[e]`: `{"mime":…,"name":…}`.
pub fn seal_meta(m_key: &[u8; 32], node_id: &str, name: &str, mime: Option<&str>) -> Result<Vec<u8>> {
    let plain = json(&MetaJson { mime: mime.map(Into::into), name: name.into() });
    Ok(env_seal(m_key, &ad(label::META, &[Field::Id(node_id)])?, &plain))
}

/// Opens `metadata_ciphertext` under `M[e]` (the epoch in `disk_nodes.key_epoch`).
pub fn open_meta(m_key: &[u8; 32], node_id: &str, ciphertext: &[u8]) -> Result<Meta> {
    let plain = env_open(m_key, &ad(label::META, &[Field::Id(node_id)])?, ciphertext)?;
    let m: MetaJson = parse(&plain).or_else(|_| refuse("metadata has no name"))?;
    Ok(Meta { name: m.name.into_owned(), mime: m.mime.map(|s| s.into_owned()) })
}

/// `disk_versions.wrapped_key` under `W[e]`.
pub fn wrap_version_key(w_key: &[u8; 32], node_id: &str, version_id: &str, kv: &[u8; 32]) -> Result<Vec<u8>> {
    Ok(env_seal(w_key, &ad(label::WRAP, &[Field::Id(node_id), Field::Id(version_id)])?, kv))
}

/// Opens `wrapped_key` under `W[e]` (the epoch in `disk_versions.key_epoch`) to `K_v`.
pub fn unwrap_version_key(w_key: &[u8; 32], node_id: &str, version_id: &str, wrapped: &[u8]) -> Result<Key> {
    let plain = env_open(w_key, &ad(label::WRAP, &[Field::Id(node_id), Field::Id(version_id)])?, wrapped)?;
    key32(&plain, "version key")
}

// ── 6.5 client-proposed ids ─────────────────────────────────────────────────

const NANOID: &[u8; 64] = b"useandom-26T198340PX75pxJACKVERYMINDBUSHWOLF_GQZbfghjklqvwyzrict";

/// An id for a sealed create: `prefix_` + 21 nanoid characters from the CSPRNG.
pub fn new_proposed_id(prefix: &str) -> String {
    let r = random::<21>();
    let tail: String = r.iter().map(|b| NANOID[(b & 63) as usize] as char).collect();
    format!("{prefix}_{tail}")
}

// ── 6.6 content ─────────────────────────────────────────────────────────────

/// Chunk size for a new upload: 1 MiB for `audio/*` and `video/*`, else 4 MiB.
pub fn chunk_bytes_for(mime: Option<&str>) -> usize {
    match mime {
        Some(m) if m.starts_with("video/") || m.starts_with("audio/") => CHUNK_MEDIA,
        _ => CHUNK_DEFAULT,
    }
}

/// Chunks of a plaintext of `size` bytes: an empty file has one.
pub fn chunk_count(size: u64, chunk_bytes: u64) -> u64 {
    size.div_ceil(chunk_bytes).max(1)
}

/// Stored (ciphertext) size of a plaintext of `size` bytes.
pub fn cipher_size(size: u64, chunk_bytes: u64) -> u64 {
    size + chunk_count(size, chunk_bytes) * TAG_BYTES as u64
}

/// Plaintext size shown for a stored size (6.6): `s - 16 * ceil(s / (cb + 16))`.
/// The manifest's `size` is the authority once opened. 0 for nonsense input.
pub fn plaintext_size(ciphertext_size: u64, chunk_bytes: u64) -> u64 {
    if ciphertext_size == 0 || chunk_bytes == 0 {
        return 0;
    }
    let tags = TAG_BYTES as u64 * ciphertext_size.div_ceil(chunk_bytes + TAG_BYTES as u64);
    ciphertext_size.saturating_sub(tags)
}

fn chunk_ad(i: u64, last: bool) -> Vec<u8> {
    ad(label::CHUNK, &[Field::Int(i), Field::Flag(last)]).expect("fixed-size fields")
}

fn chunk_nonce(prefix: &[u8; 16], i: u64) -> [u8; 24] {
    let mut n = [0u8; 24];
    n[..16].copy_from_slice(prefix);
    n[16..].copy_from_slice(&i.to_be_bytes());
    n
}

/// Seals chunk `i` under `C`; `last` is true on the final chunk.
pub fn chunk_seal(c_key: &[u8; 32], prefix: &[u8; 16], i: u64, last: bool, plain: &[u8]) -> Vec<u8> {
    aead(c_key)
        .encrypt(XNonce::from_slice(&chunk_nonce(prefix, i)), Payload { msg: plain, aad: &chunk_ad(i, last) })
        .expect("XChaCha20-Poly1305 encrypt")
}

/// Opens chunk `i` under `C`. Fails on tampering, a wrong position or a wrong `last`.
pub fn chunk_open(c_key: &[u8; 32], prefix: &[u8; 16], i: u64, last: bool, ciphertext: &[u8]) -> Result<Vec<u8>> {
    aead(c_key)
        .decrypt(XNonce::from_slice(&chunk_nonce(prefix, i)), Payload { msg: ciphertext, aad: &chunk_ad(i, last) })
        .or_else(|_| refuse(format!("chunk {i} failed authentication")))
}

/// The opened manifest of a version (6.6). `size`, `chunk_bytes`, `chunks` and
/// `prefix` are taken only from here, never from API fields. `tags` is the
/// BLAKE2b-256 of every chunk's 16-byte tag in order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Manifest {
    pub chunk_bytes: u64,
    pub chunks: u64,
    pub node: String,
    pub prefix: [u8; 16],
    pub size: u64,
    pub tags: [u8; 32],
    pub v: u64,
    pub version: String,
}

#[derive(Serialize, Deserialize)]
struct ManifestJson {
    // Sorted field order is the canonical key order.
    chunk_bytes: u64,
    chunks: u64,
    node: String,
    prefix: String,
    size: u64,
    tags: String,
    v: u64,
    version: String,
}

fn manifest_json(m: &Manifest) -> Zeroizing<Vec<u8>> {
    json(&ManifestJson {
        chunk_bytes: m.chunk_bytes,
        chunks: m.chunks,
        node: m.node.clone(),
        prefix: B64.encode(m.prefix),
        size: m.size,
        tags: B64.encode(m.tags),
        v: m.v,
        version: m.version.clone(),
    })
}

/// `disk_versions.manifest_ciphertext` under `F`, bound to the manifest's own ids.
pub fn seal_manifest(f_key: &[u8; 32], manifest: &Manifest) -> Result<Vec<u8>> {
    let ad = ad(label::MANIFEST, &[Field::Id(&manifest.node), Field::Id(&manifest.version)])?;
    Ok(env_seal(f_key, &ad, &manifest_json(manifest)))
}

/// Opens and checks a manifest (6.6): the ids must be the ones asked for, `v`
/// is 1, the numbers are safe integers with `chunks` matching `size`, the prefix
/// is 16 bytes and the tags 32.
pub fn open_manifest(f_key: &[u8; 32], node_id: &str, version_id: &str, ciphertext: &[u8]) -> Result<Manifest> {
    let plain = env_open(f_key, &ad(label::MANIFEST, &[Field::Id(node_id), Field::Id(version_id)])?, ciphertext)?;
    let m: ManifestJson = parse(&plain)?;
    if m.node != node_id || m.version != version_id {
        return refuse("manifest belongs to another version");
    }
    if m.v != 1 {
        return refuse("unknown manifest version");
    }
    if m.size > MAX_SAFE || m.chunk_bytes > MAX_SAFE || m.chunks > MAX_SAFE || m.chunk_bytes < 1 {
        return refuse("manifest sizes are not integers");
    }
    if m.chunks != chunk_count(m.size, m.chunk_bytes) {
        return refuse("manifest chunk count does not match its size");
    }
    let Ok(prefix) = B64.decode(&m.prefix) else { return refuse("manifest prefix is not base64") };
    let Ok(prefix) = <[u8; 16]>::try_from(prefix.as_slice()) else { return refuse("manifest prefix is not 16 bytes") };
    let tags = B64.decode(&m.tags).ok().and_then(|t| <[u8; 32]>::try_from(t.as_slice()).ok());
    let Some(tags) = tags else { return refuse("manifest tags are not 32 bytes") };
    Ok(Manifest { chunk_bytes: m.chunk_bytes, chunks: m.chunks, node: m.node, prefix, size: m.size, tags, v: m.v, version: m.version })
}

/// Fills `buf` from `r` until full or end of stream; returns the bytes read.
fn read_full(r: &mut impl Read, buf: &mut [u8]) -> std::io::Result<usize> {
    let mut n = 0;
    while n < buf.len() {
        match r.read(&mut buf[n..]) {
            Ok(0) => break,
            Ok(k) => n += k,
            Err(e) if e.kind() == ErrorKind::Interrupted => {}
            Err(e) => return Err(e),
        }
    }
    Ok(n)
}

/// Seals a plaintext stream into the stored object (6.6), holding at most two
/// chunks in memory. The size need not be known up front: it reads one chunk
/// ahead to know which chunk is the last.
pub struct ChunkSealer {
    c: Key,
    prefix: [u8; 16],
    chunk_bytes: usize,
}

impl ChunkSealer {
    /// `kv` is the version's fresh `K_v`; `prefix` from [`new_prefix`] (keep it
    /// to resume an upload); `chunk_bytes` from [`chunk_bytes_for`].
    pub fn new(kv: &[u8; 32], prefix: [u8; 16], chunk_bytes: usize) -> Self {
        assert!(chunk_bytes > 0, "chunk_bytes must be positive");
        Self { c: VersionKeys::derive(kv).c, prefix, chunk_bytes }
    }

    /// Reads `plain` to its end, writes the ciphertext chunks to `out`, and
    /// returns the manifest for `node_id`/`version_id` (seal it with
    /// [`seal_manifest`] under `VersionKeys::derive(kv).f`).
    pub fn seal(&self, node_id: &str, version_id: &str, mut plain: impl Read, mut out: impl Write) -> Result<Manifest> {
        let cb = self.chunk_bytes;
        let (mut cur, mut next) = (vec![0u8; cb], vec![0u8; cb]);
        let mut n = read_full(&mut plain, &mut cur)?;
        let mut tags = Blake2b::<U32>::new();
        let (mut i, mut size) = (0u64, 0u64);
        loop {
            let ahead = if n == cb { read_full(&mut plain, &mut next)? } else { 0 };
            let last = ahead == 0;
            let sealed = chunk_seal(&self.c, &self.prefix, i, last, &cur[..n]);
            Digest::update(&mut tags, &sealed[sealed.len() - TAG_BYTES..]);
            out.write_all(&sealed)?;
            size += n as u64;
            i += 1;
            if last {
                break;
            }
            std::mem::swap(&mut cur, &mut next);
            n = ahead;
        }
        out.flush()?;
        Ok(Manifest {
            chunk_bytes: cb as u64,
            chunks: i,
            node: node_id.to_string(),
            prefix: self.prefix,
            size,
            tags: tags.finalize().into(),
            v: 1,
            version: version_id.to_string(),
        })
    }
}

/// Opens a whole stored object against its (already opened) manifest, one chunk
/// at a time: every chunk's length and authentication, the `last` flag on chunk
/// `chunks - 1`, no bytes past it, and the tags digest. Plaintext of earlier
/// chunks is written before a later chunk can fail, so on any error the caller
/// must discard what was written.
pub struct ChunkOpener {
    c: Key,
    manifest: Manifest,
}

impl ChunkOpener {
    pub fn new(kv: &[u8; 32], manifest: Manifest) -> Result<Self> {
        if manifest.chunk_bytes > CHUNK_MAX {
            return refuse("manifest chunk size is too large to open");
        }
        Ok(Self { c: VersionKeys::derive(kv).c, manifest })
    }

    /// Decrypts `sealed` into `out`; returns the plaintext size.
    pub fn open(&self, mut sealed: impl Read, mut out: impl Write) -> Result<u64> {
        let m = &self.manifest;
        let mut buf = vec![0u8; m.chunk_bytes as usize + TAG_BYTES];
        let mut tags = Blake2b::<U32>::new();
        for i in 0..m.chunks {
            let plain_len = m.chunk_bytes.min(m.size - i * m.chunk_bytes) as usize;
            let piece = &mut buf[..plain_len + TAG_BYTES];
            if read_full(&mut sealed, piece)? != piece.len() {
                return refuse("stored object is truncated");
            }
            out.write_all(&chunk_open(&self.c, &m.prefix, i, i == m.chunks - 1, piece)?)?;
            Digest::update(&mut tags, &piece[plain_len..]);
        }
        if read_full(&mut sealed, &mut [0u8; 1])? != 0 {
            return refuse("stored object has the wrong length");
        }
        if <[u8; 32]>::from(tags.finalize()) != m.tags {
            return refuse("chunk tags do not match the manifest");
        }
        out.flush()?;
        Ok(m.size)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;
    use sha2::Sha512;

    fn unhex(s: &str) -> Vec<u8> {
        (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap()).collect()
    }
    fn hex(b: &[u8]) -> String {
        b.iter().map(|x| format!("{x:02x}")).collect()
    }
    fn k32(s: &str) -> [u8; 32] {
        unhex(s).try_into().unwrap()
    }
    fn vectors() -> std::collections::HashMap<String, Value> {
        let all: Value = serde_json::from_str(include_str!("../../testdata/disk_vectors.json")).unwrap();
        all["vectors"].as_array().unwrap().iter().map(|v| (v["name"].as_str().unwrap().to_string(), v.clone())).collect()
    }
    fn s<'a>(v: &'a Value, path: &str) -> &'a str {
        path.split('.').fold(v, |v, k| &v[k]).as_str().unwrap_or_else(|| panic!("{path}"))
    }
    /// Runs `f` with the given nonces as the only random draws.
    fn with_nonces<T>(nonces: &[&str], f: impl FnOnce() -> T) -> T {
        set_random_for_tests(Some(nonces.iter().map(|n| unhex(n)).collect()));
        let out = f();
        FIXED.with(|q| assert!(q.borrow().as_ref().unwrap().is_empty(), "unused fixed random"));
        set_random_for_tests(None);
        out
    }

    const NODE: &str = "dnd_filenode000000000000B";
    const VERSION: &str = "dvr_version0000000000000D";

    #[test]
    fn ad_kdf_and_derived_keys_match_the_vectors() {
        let v = vectors();
        let a = &v["AD"];
        let f = &a["inputs"]["fields"];
        let bytes = unhex(f[3]["bytes"].as_str().unwrap());
        let got = ad(
            s(a, "inputs.label"),
            &[
                Field::Id(f[0]["id"].as_str().unwrap()),
                Field::Int(f[1]["int"].as_u64().unwrap()),
                Field::Flag(f[2]["flag"].as_u64().unwrap() == 1),
                Field::Bytes(&bytes),
            ],
        )
        .unwrap();
        assert_eq!(hex(&got), s(a, "expected.ad"));
        assert!(ad("x", &[Field::Bytes(&[0u8; 65536])]).is_err());

        let k = &v["KDF"];
        assert_eq!(hex(kdf(&unhex(s(k, "inputs.key")), s(k, "inputs.label")).as_ref()), s(k, "expected.out"));

        let sk = &v["scope keys"];
        let d = ScopeKeys::derive(&k32(s(sk, "inputs.Ks")));
        for (name, key) in [("E", &d.e), ("M", &d.m), ("W", &d.w), ("P", &d.p)] {
            assert_eq!(hex(key.as_ref()), s(sk, &format!("expected.{name}")), "{name}");
        }
        let vk = &v["version keys"];
        let d = VersionKeys::derive(&k32(s(vk, "inputs.Kv")));
        for (name, key) in [("C", &d.c), ("F", &d.f), ("T", &d.t), ("R", &d.r)] {
            assert_eq!(hex(key.as_ref()), s(vk, &format!("expected.{name}")), "{name}");
        }
    }

    #[test]
    fn envelope_matches_and_refuses_bad_input() {
        let e = &vectors()["ENV"];
        let (key, ad) = (k32(s(e, "inputs.key")), unhex(s(e, "inputs.ad")));
        let env = with_nonces(&[s(e, "inputs.nonce")], || env_seal(&key, &ad, &unhex(s(e, "inputs.plaintext"))));
        assert_eq!(hex(&env), s(e, "expected.env"));
        assert_eq!(&**env_open(&key, &ad, &env).unwrap(), b"hello");

        let mut bad = env.clone();
        bad[0] = 0x02;
        assert!(env_open(&key, &ad, &bad).unwrap_err().to_string().contains("version"));
        assert!(env_open(&key, &ad, &env[..ENV_MIN - 1]).unwrap_err().to_string().contains("short"));
        let mut flipped = env.clone();
        *flipped.last_mut().unwrap() ^= 1;
        assert!(env_open(&key, &ad, &flipped).is_err());
        assert!(env_open(&key, b"other", &env).is_err());
    }

    #[test]
    fn key_grant_and_epoch_chain_match_the_vectors() {
        let v = vectors();
        let g = &v["key grant (open)"];
        // libsodium crypto_box_seed_keypair: sk = SHA-512(seed)[..32].
        let hash = Sha512::digest(unhex(s(g, "inputs.identitySeed")));
        let sk: [u8; 32] = hash[..32].try_into().unwrap();
        assert_eq!(hex(crypto_box::SecretKey::from(sk).public_key().as_bytes()), s(g, "inputs.publicKey"));
        let ks = open_key_grant(&unhex(s(g, "inputs.sealed")), &sk).unwrap();
        assert_eq!(hex(ks.as_ref()), s(g, "expected.Ks"));
        assert!(open_key_grant(&unhex(s(g, "inputs.sealed")), &[7u8; 32]).is_err());

        let c = &v["epoch chain"];
        let (scope, ks2, ks1) = (s(c, "inputs.scope"), k32(s(c, "inputs.Ks")), k32(s(c, "inputs.previous")));
        let e2 = ScopeKeys::derive(&ks2).e;
        let wrapped = with_nonces(&[s(c, "inputs.nonce")], || wrap_previous_key(&e2, scope, 2, &ks1).unwrap());
        assert_eq!(hex(&wrapped), s(c, "expected.previous_key_wrapped"));
        let chain = |e: u64| (e == 2).then(|| wrapped.clone());
        assert_eq!(*walk_epochs(&ks2, 2, 1, scope, chain).unwrap(), ks1);
        assert_eq!(*walk_epochs(&ks2, 2, 2, scope, chain).unwrap(), ks2);
        assert!(walk_epochs(&ks2, 2, 3, scope, chain).is_err());
        assert!(walk_epochs(&ks2, 2, 0, scope, chain).is_err());
        assert!(walk_epochs(&ks2, 3, 1, scope, chain).unwrap_err().to_string().contains("epoch 3"));
        assert!(walk_epochs(&ks2, 2, 1, "dnd_other", chain).is_err());
        assert!(wrap_previous_key(&e2, scope, 1, &ks1).is_err());
    }

    #[test]
    fn metadata_and_version_key_match_the_vectors() {
        let v = vectors();
        let m = &v["metadata"];
        let mk = ScopeKeys::derive(&k32(s(m, "inputs.Ks"))).m;
        let (name, mime) = (s(m, "inputs.meta.name"), s(m, "inputs.meta.mime"));
        assert_eq!(&**json(&MetaJson { mime: Some(mime.into()), name: name.into() }), s(m, "expected.json").as_bytes());
        let ct = with_nonces(&[s(m, "inputs.nonce")], || seal_meta(&mk, NODE, name, Some(mime)).unwrap());
        assert_eq!(hex(&ct), s(m, "expected.metadata_ciphertext"));
        assert_eq!(open_meta(&mk, NODE, &ct).unwrap(), Meta { name: name.into(), mime: Some(mime.into()) });
        assert!(open_meta(&mk, "dnd_copynode000000000000C", &ct).is_err());

        let folder = seal_meta(&mk, NODE, "Plans", None).unwrap();
        assert_eq!(open_meta(&mk, NODE, &folder).unwrap(), Meta { name: "Plans".into(), mime: None });
        let nameless = env_seal(&mk, &ad(label::META, &[Field::Id(NODE)]).unwrap(), br#"{"mime":null}"#);
        assert!(open_meta(&mk, NODE, &nameless).is_err());

        let w = &v["version key wrap"];
        let wk = ScopeKeys::derive(&k32(s(w, "inputs.Ks"))).w;
        let kv = k32(s(w, "inputs.Kv"));
        let wrapped = with_nonces(&[s(w, "inputs.nonce")], || wrap_version_key(&wk, NODE, VERSION, &kv).unwrap());
        assert_eq!(hex(&wrapped), s(w, "expected.wrapped_key"));
        assert_eq!(*unwrap_version_key(&wk, NODE, VERSION, &wrapped).unwrap(), kv);
        assert!(unwrap_version_key(&wk, NODE, "dvr_version0000000000000E", &wrapped).is_err());
    }

    #[test]
    fn json_escapes_strings_like_json_stringify() {
        // JSON.stringify("a/\u0001\b\t\n\f\r\u001f\u007f  \"\\é😀") in V8:
        let input = "a/\u{1}\u{8}\t\n\u{c}\r\u{1f}\u{7f}\u{2028}\u{2029}\"\\é😀";
        let js = "\"a/\\u0001\\b\\t\\n\\f\\r\\u001f\u{7f}\u{2028}\u{2029}\\\"\\\\é😀\"";
        assert_eq!(serde_json::to_string(input).unwrap(), js);
    }

    #[test]
    fn chunks_empty_file_and_manifest_match_the_vectors() {
        let v = vectors();
        let c = &v["content chunks"];
        let kv = k32(s(c, "inputs.Kv"));
        let prefix: [u8; 16] = unhex(s(c, "inputs.prefix")).try_into().unwrap();
        let cb = c["inputs"]["chunk_bytes"].as_u64().unwrap() as usize;
        let plain = unhex(s(c, "inputs.plaintext"));
        let ck = VersionKeys::derive(&kv).c;
        for (i, want) in c["expected"]["chunks"].as_array().unwrap().iter().enumerate() {
            let piece = &plain[i * cb..plain.len().min((i + 1) * cb)];
            let sealed = chunk_seal(&ck, &prefix, i as u64, i == 2, piece);
            assert_eq!(hex(&sealed), want.as_str().unwrap(), "chunk {i}");
            assert_eq!(chunk_open(&ck, &prefix, i as u64, i == 2, &sealed).unwrap(), piece);
            assert!(chunk_open(&ck, &prefix, i as u64, i != 2, &sealed).is_err(), "last flag is bound");
        }

        let mut object = Vec::new();
        let manifest = ChunkSealer::new(&kv, prefix, cb).seal(NODE, VERSION, plain.as_slice(), &mut object).unwrap();
        assert_eq!(hex(&object), s(c, "expected.object"));

        let e = &v["empty file"];
        let mut empty = Vec::new();
        let em = ChunkSealer::new(&kv, prefix, cb).seal(NODE, VERSION, &[][..], &mut empty).unwrap();
        assert_eq!(hex(&empty), s(e, "expected.object"));
        assert_eq!((em.size, em.chunks), (0, 1));
        assert_eq!(hex(&chunk_seal(&ck, &prefix, 0, true, &[])), s(e, "expected.object"));

        let m = &v["manifest"];
        assert_eq!(s(m, "inputs.object"), hex(&object));
        assert_eq!(&**manifest_json(&manifest), s(m, "expected.json").as_bytes(), "manifest JSON and tags");
        let fk = VersionKeys::derive(&kv).f;
        let ct = with_nonces(&[s(m, "inputs.nonce")], || seal_manifest(&fk, &manifest).unwrap());
        assert_eq!(hex(&ct), s(m, "expected.manifest_ciphertext"));
        let opened = open_manifest(&fk, NODE, VERSION, &ct).unwrap();
        assert_eq!(opened, manifest);

        let mut out = Vec::new();
        assert_eq!(ChunkOpener::new(&kv, opened).unwrap().open(object.as_slice(), &mut out).unwrap(), 40);
        assert_eq!(out, plain);
    }

    fn roundtrip(size: usize, cb: usize) {
        let kv = new_key();
        let plain: Vec<u8> = (0..size).map(|i| (i * 7 % 251) as u8).collect();
        let mut object = Vec::new();
        let m = ChunkSealer::new(&kv, new_prefix(), cb).seal(NODE, VERSION, plain.as_slice(), &mut object).unwrap();
        assert_eq!((m.size, m.chunks), (size as u64, chunk_count(size as u64, cb as u64)), "size {size}");
        assert_eq!(object.len() as u64, cipher_size(size as u64, cb as u64));
        assert_eq!(plaintext_size(object.len() as u64, cb as u64), size as u64);
        let fk = VersionKeys::derive(&kv).f;
        let m = open_manifest(&fk, NODE, VERSION, &seal_manifest(&fk, &m).unwrap()).unwrap();
        let mut out = Vec::new();
        ChunkOpener::new(&kv, m).unwrap().open(object.as_slice(), &mut out).unwrap();
        assert_eq!(out, plain, "size {size}");
    }

    /// A reader that hands out at most 5 bytes per read, to prove short reads are handled.
    struct Trickle<'a>(&'a [u8]);
    impl Read for Trickle<'_> {
        fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
            let n = buf.len().min(5).min(self.0.len());
            buf[..n].copy_from_slice(&self.0[..n]);
            self.0 = &self.0[n..];
            Ok(n)
        }
    }

    #[test]
    fn streaming_roundtrips_at_the_chunk_boundaries() {
        let cb = 64;
        for size in [0, 1, cb, cb + 1, 3 * cb, 3 * cb - 1] {
            roundtrip(size, cb);
        }
        roundtrip(CHUNK_MEDIA + 1, CHUNK_MEDIA);

        let kv = new_key();
        let plain = vec![9u8; 200];
        let (mut a, mut b) = (Vec::new(), Vec::new());
        let p = new_prefix();
        let ma = ChunkSealer::new(&kv, p, 64).seal(NODE, VERSION, plain.as_slice(), &mut a).unwrap();
        let mb = ChunkSealer::new(&kv, p, 64).seal(NODE, VERSION, Trickle(&plain), &mut b).unwrap();
        assert_eq!((a, ma), (b.clone(), mb.clone()));
        let mut out = Vec::new();
        ChunkOpener::new(&kv, mb).unwrap().open(Trickle(&b), &mut out).unwrap();
        assert_eq!(out, plain);
    }

    #[test]
    fn opener_refuses_tampered_truncated_and_padded_objects() {
        let kv = new_key();
        let plain = vec![1u8; 3 * 64];
        let mut object = Vec::new();
        let m = ChunkSealer::new(&kv, new_prefix(), 64).seal(NODE, VERSION, plain.as_slice(), &mut object).unwrap();
        let open = |obj: &[u8], m: &Manifest| ChunkOpener::new(&kv, m.clone()).unwrap().open(obj, std::io::sink());

        let mut tampered = object.clone();
        tampered[70] ^= 1;
        assert!(open(&tampered, &m).unwrap_err().to_string().contains("chunk 0"));

        // Drop the last chunk: the stream is short of what the manifest says.
        let two = &object[..2 * (64 + 16)];
        assert!(open(two, &m).unwrap_err().to_string().contains("truncated"));
        // And a manifest claiming two chunks cannot pass chunk 1 off as the last:
        // its AD says last = 0.
        let short = Manifest { size: 128, chunks: 2, ..m.clone() };
        assert!(open(two, &short).unwrap_err().to_string().contains("chunk 1"));

        let mut padded = object.clone();
        padded.push(0);
        assert!(open(&padded, &m).unwrap_err().to_string().contains("wrong length"));

        let wrong_tags = Manifest { tags: [0; 32], ..m.clone() };
        assert!(open(&object, &wrong_tags).unwrap_err().to_string().contains("tags"));

        let other_key = new_key();
        assert!(ChunkOpener::new(&other_key, m.clone()).unwrap().open(object.as_slice(), std::io::sink()).is_err());
        assert!(ChunkOpener::new(&kv, Manifest { chunk_bytes: CHUNK_MAX + 1, ..m }).is_err());
    }

    #[test]
    fn open_manifest_refuses_another_node_and_bad_fields() {
        let kv = new_key();
        let fk = VersionKeys::derive(&kv).f;
        let good = Manifest { chunk_bytes: 16, chunks: 3, node: NODE.into(), prefix: [5; 16], size: 40, tags: [1; 32], v: 1, version: VERSION.into() };
        let ct = seal_manifest(&fk, &good).unwrap();
        assert!(open_manifest(&fk, "dnd_copynode000000000000C", VERSION, &ct).is_err());
        assert!(open_manifest(&fk, NODE, "dvr_version0000000000000E", &ct).is_err());

        // Sealed under the right ids but naming another node inside.
        let ad = ad(label::MANIFEST, &[Field::Id(NODE), Field::Id(VERSION)]).unwrap();
        let liar = env_seal(&fk, &ad, &manifest_json(&Manifest { node: "dnd_copynode000000000000C".into(), ..good.clone() }));
        assert!(open_manifest(&fk, NODE, VERSION, &liar).unwrap_err().to_string().contains("another version"));

        for (bad, why) in [
            (Manifest { v: 2, ..good.clone() }, "manifest version"),
            (Manifest { chunks: 2, ..good.clone() }, "chunk count"),
            (Manifest { chunk_bytes: 0, chunks: 1, ..good.clone() }, "not integers"),
            (Manifest { size: MAX_SAFE + 1, ..good.clone() }, "not integers"),
        ] {
            let err = open_manifest(&fk, NODE, VERSION, &seal_manifest(&fk, &bad).unwrap()).unwrap_err();
            assert!(err.to_string().contains(why), "{why}: {err}");
        }
        let short_prefix = env_seal(&fk, &ad, br#"{"chunk_bytes":16,"chunks":3,"node":"dnd_filenode000000000000B","prefix":"AAAA","size":40,"tags":"AAAA","v":1,"version":"dvr_version0000000000000D"}"#);
        assert!(open_manifest(&fk, NODE, VERSION, &short_prefix).unwrap_err().to_string().contains("prefix"));
        assert!(open_manifest(&fk, NODE, VERSION, &env_seal(&fk, &ad, b"not json")).is_err());
    }

    #[test]
    fn sizes_ids_and_chunk_choice() {
        assert_eq!(plaintext_size(16, 16), 0);
        assert_eq!(plaintext_size(cipher_size(40, 16), 16), 40);
        assert_eq!(plaintext_size(0, 16), 0);
        assert_eq!(plaintext_size(5, 16), 0);
        assert_eq!(chunk_bytes_for(Some("video/mp4")), CHUNK_MEDIA);
        assert_eq!(chunk_bytes_for(Some("audio/mpeg")), CHUNK_MEDIA);
        assert_eq!(chunk_bytes_for(Some("application/pdf")), CHUNK_DEFAULT);
        assert_eq!(chunk_bytes_for(None), CHUNK_DEFAULT);

        let fixed: Vec<u8> = (0..21).map(|i| i + 64).collect(); // & 63 wraps to 0..21
        let id = with_nonces(&[&hex(&fixed)], || new_proposed_id("dnd"));
        assert_eq!(id, "dnd_useandom-26T198340PX7");
        let id = new_proposed_id("dvr");
        assert!(id.len() == 25 && id.starts_with("dvr_") && id[4..].bytes().all(|b| NANOID.contains(&b)));
        assert_ne!(new_proposed_id("dnd"), new_proposed_id("dnd"));
    }
}
