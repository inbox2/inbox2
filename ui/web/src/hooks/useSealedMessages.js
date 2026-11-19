// Client-side decryption for sealed (E2EE) conversations — docs/E2EE.md
// Phase F. Given the API conversation, returns a shadow copy whose sealed
// messages carry decrypted plaintext fields (subject/from/body), so the
// existing renderers work unchanged, plus the lock state driving the unlock
// prompt. Plaintext conversations pass through untouched.
import { useEffect, useMemo, useState } from 'react';
import { useE2ee, isUnlocked, loadOrgDomainSecrets, decryptSealedMessage, decryptSealedFilename, refreshIdentity } from '../lib/e2eeStore';
import { isRealOrgId } from '../lib/org';
import log from '../lib/log';

export default function useSealedMessages(conversation, orgId) {
  const e2ee = useE2ee();
  const [decrypted, setDecrypted] = useState({}); // message id -> {header, body} | {error: true}

  const sealedMessages = useMemo(
    () => (conversation?.messages || []).filter((m) => m.sealed),
    [conversation?.messages]
  );
  const hasSealed = sealedMessages.length > 0;

  // Know whether an identity exists so the prompt can say unlock vs not-set-up.
  useEffect(() => {
    if (hasSealed && e2ee.identityStatus === 'unknown') refreshIdentity();
  }, [hasSealed, e2ee.identityStatus]);

  useEffect(() => {
    if (!hasSealed || !isUnlocked() || !isRealOrgId(orgId)) return;
    let cancelled = false;
    (async () => {
      await loadOrgDomainSecrets(orgId);
      const next = {};
      for (const msg of sealedMessages) {
        try {
          const dec = await decryptSealedMessage(msg);
          // Attachment filenames are sealed separately (AAD "|att:<i>|name"), so
          // they need their own pass — without it every file on a sealed message
          // reads as "Encrypted attachment". One failing name must not lose the
          // decrypted body, hence the inner catch.
          dec.attachmentNames = await Promise.all(
            (msg.attachments || []).map((att, i) =>
              decryptSealedFilename(msg, att, i).catch((e) => {
                log.warn('E2EE', `filename decrypt failed for ${msg.id}[${i}]: ${e?.message || e}`);
                return null;
              })
            )
          );
          next[msg.id] = dec;
        } catch (e) {
          log.warn('E2EE', `decrypt failed for ${msg.id}: ${e?.message || e}`);
          next[msg.id] = { error: true };
        }
      }
      if (!cancelled) setDecrypted(next);
    })();
    return () => { cancelled = true; };
  }, [hasSealed, sealedMessages, orgId, e2ee.identityStatus, e2ee.epoch]);

  const resolved = useMemo(() => {
    if (!hasSealed) return conversation;

    let subjectFallback = null;
    const messages = (conversation.messages || []).map((msg) => {
      if (!msg.sealed) return msg;
      const dec = decrypted[msg.id];
      if (!dec || dec.error) {
        return {
          ...msg,
          subject: null,
          from_address: null,
          body_plain: dec?.error ? "⚠ We couldn't open this sealed message." : '',
          sealedPending: !dec,
          sealedError: !!dec?.error,
        };
      }
      subjectFallback ||= dec.header.subject;
      return {
        ...msg,
        subject: dec.header.subject,
        from_address: dec.header.from,
        to_address: dec.header.to,
        cc_address: dec.header.cc,
        bcc_address: dec.header.bcc,
        body_plain: dec.body.plain,
        body_html: dec.body.html,
        // Keep sealed_filename: the bytes are still ciphertext, and the download
        // path reads it to know it must decrypt them.
        attachments: (msg.attachments || []).map((att, i) => (
          dec.attachmentNames?.[i] ? { ...att, filename: dec.attachmentNames[i] } : att
        )),
        sealedDecrypted: true,
      };
    });

    return {
      ...conversation,
      subject: conversation.subject || subjectFallback,
      messages,
    };
  }, [conversation, decrypted, hasSealed]);

  return {
    conversation: resolved,
    hasSealed,
    // Locked = sealed content present but no usable key material in memory.
    sealedLocked: hasSealed && e2ee.identityStatus !== 'unlocked',
    identityStatus: e2ee.identityStatus,
  };
}
