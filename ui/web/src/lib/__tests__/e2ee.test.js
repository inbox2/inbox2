// E2EE client crypto tests (docs/E2EE.md Phase F).
//
// The fixture cases are the round-trip acceptance test: the Go MX sealed the
// material (mta/cmd/sealfixture runs the real seal pipeline), and this suite
// proves the client opens it — the cross-language interop contract.
import { describe, it, expect, beforeAll, vi } from "vitest";
import {
  ready,
  generateIdentity,
  unlockIdentity,
  rewrapIdentity,
  generateRecoveryPassphrase,
  wrapRecovery,
  recoverIdentity,
  normalizePassphrase,
  generateDomainKey,
  sealGrant,
  openGrant,
  decryptMessage,
  decryptAttachment,
  decryptFilename,
  RECOVERY_WORD_COUNT,
} from "../e2ee";
import { EFF_WORDLIST } from "../effWordlist";
import fixture from "./fixtures/sealed_fixture.json";
import fixtureV2 from "./fixtures/sealed_v2_fixture.json";

// The Argon2id KDF (real interactive params) takes ~5s+ per derivation on a
// loaded machine — vitest's 5s default flakes the passphrase-wrapping tests.
vi.setConfig({ testTimeout: 60_000 });

const hex = (bytes) => Array.from(bytes).map((b) => b.toString(16).padStart(2, "0")).join("");

beforeAll(async () => {
  await ready();
});

describe("Go → JS interop (the round-trip acceptance test)", () => {
  it("decrypts a Go-sealed message with the domain secret key", async () => {
    const sodium = await ready();
    const secret = sodium.from_base64(fixture.domain_secret_key, sodium.base64_variants.ORIGINAL);

    const { header, body } = decryptMessage(fixture.sealed, fixture.domain_public_key, secret);

    expect(header.subject).toBe(fixture.expected.header.subject);
    expect(header.from).toBe(fixture.expected.header.from);
    expect(header.snippet).toBe(fixture.expected.header.snippet);
    expect(body.plain).toBe(fixture.expected.body.plain);
    expect(body.html).toBe(fixture.expected.body.html);
  });

  it("decrypts a Go-sealed attachment (content + filename)", async () => {
    const sodium = await ready();
    const secret = sodium.from_base64(fixture.domain_secret_key, sodium.base64_variants.ORIGINAL);
    const cipher = sodium.from_base64(fixture.attachment_ciphertext, sodium.base64_variants.ORIGINAL);

    const bytes = decryptAttachment(fixture.sealed, fixture.attachment, 0, cipher, fixture.domain_public_key, secret);
    expect(new TextDecoder().decode(bytes)).toBe(fixture.expected.attachment_plain);

    const name = decryptFilename(fixture.sealed, fixture.attachment, 0, fixture.domain_public_key, secret);
    expect(name).toBe(fixture.expected.attachment_filename);
  });

  it("rejects a tampered AAD (blob grafted onto another message)", async () => {
    const sodium = await ready();
    const secret = sodium.from_base64(fixture.domain_secret_key, sodium.base64_variants.ORIGINAL);
    const tampered = { ...fixture.sealed, aad: fixture.sealed.aad.replace("4242", "4243") };

    expect(() => decryptMessage(tampered, fixture.domain_public_key, secret)).toThrow();
  });

  it("rejects the wrong domain key", () => {
    const other = generateDomainKey();
    expect(() => decryptMessage(fixture.sealed, other.publicKey, other.secretKey)).toThrow();
  });
});

describe("identity keys", () => {
  it("wraps under the password and unlocks only with it", () => {
    const identity = generateIdentity("correct horse");
    expect(identity.public_key).toBeTruthy();
    expect(identity.kdf_params.alg).toBe("argon2id13");

    const priv = unlockIdentity("correct horse", identity);
    expect(priv.length).toBe(32);
    expect(() => unlockIdentity("wrong password", identity)).toThrow();
  });

  it("rewraps under a new password keeping the same identity", () => {
    const identity = generateIdentity("old-password");
    const priv = unlockIdentity("old-password", identity);

    const rewrapped = rewrapIdentity(priv, "new-password");
    const priv2 = unlockIdentity("new-password", { encrypted_private_key: rewrapped.encrypted_private_key });
    expect(hex(priv2)).toBe(hex(priv));
  });
});

describe("recovery passphrase", () => {
  // Looped: the one hyphenated entry in the list ("yo-yo") used to be drawable,
  // which split into 7 tokens roughly 1 run in 216 — a single draw hid it.
  it("generates 6 hyphenated EFF words", () => {
    for (let i = 0; i < 500; i++) {
      const words = generateRecoveryPassphrase().split("-");
      expect(words).toHaveLength(RECOVERY_WORD_COUNT);
      for (const w of words) expect(EFF_WORDLIST).toContain(w);
    }
  });

  it("round-trips the identity key through the recovery blob, tolerating re-typing variance", () => {
    const identity = generateIdentity("pw");
    const priv = unlockIdentity("pw", identity);
    const phrase = generateRecoveryPassphrase();
    const blob = wrapRecovery(phrase, priv);

    // As the user might re-type it from paper: spaces + mixed case.
    const retyped = phrase.split("-").map((w, i) => (i % 2 ? w.toUpperCase() : w)).join(" ");
    const recovered = recoverIdentity(retyped, blob);
    expect(hex(recovered)).toBe(hex(priv));

    expect(() => recoverIdentity("wrong-words-entirely-typed-here-nope", blob)).toThrow();
  });

  it("normalizes separators and case", () => {
    expect(normalizePassphrase("  Acid  ACORN acre ")).toBe("acid-acorn-acre");
    expect(normalizePassphrase("acid-acorn-acre")).toBe("acid-acorn-acre");
  });
});

describe("domain keys & grants", () => {
  it("seals the domain secret to a member identity and opens it back", () => {
    const identity = generateIdentity("member-pw");
    const identityPriv = unlockIdentity("member-pw", identity);
    const domain = generateDomainKey();

    const grant = sealGrant(domain.secretKey, identity.public_key);
    const opened = openGrant(grant, identity.public_key, identityPriv);
    expect(hex(opened)).toBe(hex(domain.secretKey));

    // Another member's identity cannot open this grant.
    const other = generateIdentity("other-pw");
    const otherPriv = unlockIdentity("other-pw", other);
    expect(() => openGrant(grant, other.public_key, otherPriv)).toThrow();
  });
});

describe("sealed_box_v2 (the part's role is in the AAD)", () => {
  const secret = async () => {
    const sodium = await ready();
    return sodium.from_base64(fixtureV2.domain_secret_key, sodium.base64_variants.ORIGINAL);
  };

  it("opens mail the Go MX sealed", async () => {
    const { header, body } = decryptMessage(fixtureV2.sealed, fixtureV2.domain_public_key, await secret());
    expect(header.subject).toBe(fixtureV2.expected.header.subject);
    expect(body.plain).toBe(fixtureV2.expected.body.plain);
  });

  it("refuses swapped parts and a removed scheme", async () => {
    const key = await secret();
    const s = fixtureV2.sealed;
    const swapped = { ...s, header_nonce: s.body_nonce, header_ciphertext: s.body_ciphertext, body_nonce: s.header_nonce, body_ciphertext: s.header_ciphertext };
    expect(() => decryptMessage(swapped, fixtureV2.domain_public_key, key)).toThrow();
    const downgraded = { ...s, scheme: undefined };
    expect(() => decryptMessage(downgraded, fixtureV2.domain_public_key, key)).toThrow();
  });
});
