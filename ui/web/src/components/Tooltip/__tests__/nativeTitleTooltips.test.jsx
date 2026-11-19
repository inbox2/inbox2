// @vitest-environment jsdom
//
// The one thing that can silently break the native-title takeover: leaving the
// DOM stripped. Hover must remove `title` (else the OS bubble shows on top of
// ours) and leaving must put it back exactly as it was.
import { describe, it, expect, afterEach } from 'vitest';
import { createRoot } from 'react-dom/client';
import { act } from 'react';
import NativeTitleTooltips from '../NativeTitleTooltips';

let root;
afterEach(() => {
  act(() => root?.unmount());
  document.body.innerHTML = '';
});

const mount = () => {
  const host = document.createElement('div');
  document.body.appendChild(host);
  root = createRoot(host);
  act(() => root.render(<NativeTitleTooltips />));
};

const hover = (el) => act(() => {
  el.dispatchEvent(new window.MouseEvent('mouseover', { bubbles: true }));
});

describe('NativeTitleTooltips', () => {
  it('strips title on hover, renders our tooltip, and restores it after', () => {
    const btn = document.createElement('button');
    btn.setAttribute('title', 'Archive');
    document.body.appendChild(btn);
    mount();

    hover(btn);
    expect(btn.hasAttribute('title')).toBe(false);
    expect(document.body.textContent).toContain('Archive');

    act(() => {
      btn.dispatchEvent(new window.MouseEvent('mouseleave', { bubbles: true }));
    });
    expect(btn.getAttribute('title')).toBe('Archive');
    expect(document.body.textContent).not.toContain('Archive');
  });

  it('leaves accessibility titles (iframe) alone', () => {
    const frame = document.createElement('iframe');
    frame.setAttribute('title', 'Email message');
    document.body.appendChild(frame);
    mount();

    hover(frame);
    expect(frame.getAttribute('title')).toBe('Email message');
  });
});
