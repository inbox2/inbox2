// @vitest-environment jsdom
import { describe, it, expect } from 'vitest';
import { mapMxAttachments, isMxAttachment } from '../mxAttachments';

// The API serializes attachments in its own shape (filename / size_bytes /
// download_url); MessageDetails renders name / size / mimeType. One list can
// hold both — a provider attachment is already mapped by the provider fetch —
// so the mapper has to be shape-aware rather than assume it owns the input.

const apiShape = {
  id: 'att_abc',
  filename: 'quote.pdf',
  content_type: 'application/pdf',
  size_bytes: 8192,
  has_content: true,
  download_url: '/api/v1/orgs/org_1/attachments/att_abc',
};

describe('mapMxAttachments', () => {
  it('maps the API shape onto what the chip renders', () => {
    const [a] = mapMxAttachments([apiShape]);
    expect(a.name).toBe('quote.pdf');
    expect(a.size).toBe('8.0 KB');
    expect(a.sizeBytes).toBe(8192);
    expect(a.mimeType).toBe('application/pdf');
    expect(a.downloadUrl).toBe('/api/v1/orgs/org_1/attachments/att_abc');
    expect(isMxAttachment(a)).toBe(true);
  });

  it('passes an already-mapped provider attachment straight through', () => {
    const provider = { name: 'photo.jpg', size: '1.2 MB', attachmentId: 'ANGjdJ', mimeType: 'image/jpeg' };
    const [a] = mapMxAttachments([provider]);
    expect(a).toBe(provider);
    // Must not be claimed by the MX download path — it has no downloadUrl.
    expect(isMxAttachment(a)).toBe(false);
  });

  it('handles an empty / missing list', () => {
    expect(mapMxAttachments([])).toEqual([]);
    expect(mapMxAttachments(undefined)).toEqual([]);
  });

  it('leaves size off when the server did not send one', () => {
    const [a] = mapMxAttachments([{ ...apiShape, size_bytes: 0 }]);
    expect(a.size).toBeUndefined();
  });

  // A row exists before its bytes land (sealed ciphertext is spooled after the
  // row). The chip still shows, but there is nothing to download yet.
  it('carries has_content false with no download URL', () => {
    const [a] = mapMxAttachments([{ ...apiShape, has_content: false, download_url: null }]);
    expect(a.hasContent).toBe(false);
    expect(a.downloadUrl).toBeNull();
  });
});

describe('mapMxAttachments — sealed (E2EE)', () => {
  const sealed = {
    id: 'att_sealed',
    filename: null,
    sealed_filename: 'Y2lwaGVy',
    filename_nonce: 'bm9uY2U=',
    content_nonce: 'bm9uY2Uy',
    content_type: 'application/octet-stream',
    size_bytes: 4096,
    has_content: true,
    download_url: '/api/v1/orgs/org_1/attachments/att_sealed',
  };

  it('shows a placeholder name and keeps the material needed to decrypt', () => {
    const [a] = mapMxAttachments([sealed]);
    expect(a.name).toBe('Encrypted attachment');
    expect(a.sealed).toBe(true);
    // The index is the AAD suffix ("|att:<i>") — decryption fails without it.
    expect(a.sealedIndex).toBe(0);
    expect(a.content_nonce).toBe('bm9uY2Uy');
  });

  it('uses the real name once useSealedMessages has decrypted it', () => {
    const [a] = mapMxAttachments([{ ...sealed, filename: 'contract.pdf' }]);
    expect(a.name).toBe('contract.pdf');
    // Still sealed: the BYTES are ciphertext regardless of the name being known.
    expect(a.sealed).toBe(true);
  });

  it('indexes each attachment by its position in the message', () => {
    const mapped = mapMxAttachments([sealed, { ...sealed, id: 'att_2' }]);
    expect(mapped.map((a) => a.sealedIndex)).toEqual([0, 1]);
  });
});
