// Pure Canvas paint helpers for the Command Center force graph. None of these
// close over component state — the component passes its live state in explicitly
// so these can live outside the render body.
import { readThemeTokens } from './readThemeTokens';
import { displayName as formatName } from './emailAddress';

// Read theme colors from CSS custom properties so Canvas painting follows the active theme
export function getThemeColors() {
  const t = readThemeTokens([
    '--bg-raised', '--bg-elevated', '--bg-recessed', '--border-default', '--border-strong',
    '--accent-warning', '--text-primary', '--text-secondary', '--text-tertiary', '--text-muted',
    '--accent-primary', '--accent-danger', '--accent-danger-dim', '--accent-success', '--accent-success-dim',
    '--accent-primary-dim', '--accent-teal-dim', '--accent-warning-dim', '--border-subtle',
    '--accent-purple-dim', '--bg-base', '--accent-info', '--accent-teal', '--accent-purple',
  ]);
  const v = (name) => t[name];
  return {
    cardBg: v('--bg-raised') || 'rgba(22, 26, 36, 0.92)',
    cardBgHover: v('--bg-elevated') || 'rgba(32, 36, 48, 0.95)',
    cardBgDim: v('--bg-recessed') || 'rgba(22, 26, 36, 0.4)',
    cardStroke: v('--border-default') || 'rgba(255, 255, 255, 0.08)',
    cardStrokeHover: v('--border-strong') || 'rgba(160, 168, 184, 0.25)',
    cardStrokeMatch: v('--accent-warning') || 'rgba(200, 168, 122, 0.5)',
    textPrimary: v('--text-primary') || '#e0e0e8',
    textSecondary: v('--text-secondary') || '#a0a0b0',
    textTertiary: v('--text-tertiary') || '#707080',
    textMuted: v('--text-muted') || '#4a4a58',
    accentPrimary: v('--accent-primary') || '#a0a8b8',
    accentDanger: v('--accent-danger') || '#c48a88',
    accentDangerDim: v('--accent-danger-dim') || 'rgba(196, 138, 136, 0.15)',
    accentSuccess: v('--accent-success') || '#7aaa8c',
    accentSuccessDim: v('--accent-success-dim') || 'rgba(122, 170, 140, 0.12)',
    accentWarning: v('--accent-warning') || '#c8a060',
    accentWarningDim: v('--accent-warning-dim') || 'rgba(200, 168, 122, 0.12)',
    memberBg: v('--accent-primary-dim') || 'rgba(160, 168, 184, 0.08)',
    externalBg: v('--accent-teal-dim') || 'rgba(120, 168, 160, 0.08)',
    linkInternal: v('--accent-warning-dim') || 'rgba(200, 168, 122, 0.12)',
    linkInbound: v('--border-subtle') || 'rgba(160, 168, 184, 0.06)',
    linkSharedTag: v('--accent-purple-dim') || 'rgba(168, 152, 192, 0.06)',
    linkHighlight: v('--accent-warning') || 'rgba(200, 168, 122, 0.35)',
    // Entity graph: one hue per ontology kind (lib/entityGraph ENTITY_KINDS)
    kind: {
      organization: v('--accent-info') || v('--accent-primary'),
      person: v('--accent-teal') || v('--accent-success'),
      product: v('--accent-purple') || v('--accent-primary'),
      project: v('--accent-warning'),
    },
    // Detect light vs dark for Canvas shadow adjustments
    isLight: (v('--bg-base') || '#090a0e').match(/^#[a-fA-F0-9]{6}$/)
      ? parseInt((v('--bg-base')).slice(1, 3), 16) > 128
      : false,
  };
}

// Week-over-week change as a fraction (0.4 = +40%). Infinity when prior is 0
// and recent > 0 ("new"), null when there is nothing to compare.
export function trendPct(recent, prior) {
  if (!recent && !prior) return null;
  if (!prior) return Infinity;
  return (recent - prior) / prior;
}

export function urgencyColor(u, c) {
  if (u >= 0.6) return c.accentDanger;
  if (u >= 0.3) return c.accentWarning;
  if (u > 0) return c.accentSuccess;
  return c.accentPrimary;
}

export function linkColorFor(link, c) {
  if (link.kind === 'internal') return c.linkInternal;
  if (link.kind === 'shared_tag') return c.linkSharedTag;
  return c.linkInbound;
}

// Custom Canvas node renderer. `state` carries the component's live values:
// { colors, hoveredNode, directMatchSet, visibleSet, hubImageCache }.
export function paintNode(node, ctx, globalScale, state) {
  const { colors: C, hoveredNode, directMatchSet, visibleSet, hubImageCache } = state;
  if (node.type === 'entity') {
    paintEntityNode(node, ctx, globalScale, state);
    return;
  }
  const isHub = node.type === 'channel_hub';
  const isMailbox = node.type === 'mailbox';
  const isHovered = hoveredNode === node.id;

  // Channel hub node — larger card with provider icon
  if (isHub) {
    const hubW = 160 / globalScale;
    const hubH = 54 / globalScale;
    const radius = 8 / globalScale;

    // Card background with stronger styling
    ctx.beginPath();
    ctx.roundRect(node.x - hubW / 2, node.y - hubH / 2, hubW, hubH, radius);
    ctx.fillStyle = isHovered ? C.cardBgHover : C.cardBg;
    ctx.fill();
    ctx.strokeStyle = isHovered ? C.cardStrokeHover : C.accentPrimary;
    ctx.lineWidth = 1.5 / globalScale;
    ctx.stroke();

    // Provider icon
    const img = hubImageCache.current[node.providerType];
    if (img && img.complete) {
      const iconSize = 24 / globalScale;
      ctx.drawImage(img, node.x - hubW / 2 + 10 / globalScale, node.y - iconSize / 2, iconSize, iconSize);
    }

    // Name + email
    const textX = node.x - hubW / 2 + 42 / globalScale;
    const maxW = hubW - 50 / globalScale;
    ctx.fillStyle = C.textPrimary;
    ctx.font = `600 ${12 / globalScale}px "SF Pro Display", system-ui, sans-serif`;
    ctx.textAlign = 'left';
    ctx.textBaseline = 'middle';
    let hubName = formatName(node.name);
    while (ctx.measureText(hubName).width > maxW && hubName.length > 3) {
      hubName = hubName.slice(0, -2) + '…';
    }
    ctx.fillText(hubName, textX, node.y - 6 / globalScale);

    ctx.fillStyle = C.textMuted;
    ctx.font = `400 ${8 / globalScale}px "Fira Code", monospace`;
    let hubAddr = node.address;
    while (ctx.measureText(hubAddr).width > maxW && hubAddr.length > 5) {
      hubAddr = hubAddr.slice(0, -2) + '…';
    }
    ctx.fillText(hubAddr, textX, node.y + 8 / globalScale);

    // Unread badge
    if (node.unread > 0) {
      const badgeText = String(node.unread);
      ctx.font = `bold ${9 / globalScale}px "Fira Code", monospace`;
      const badgeW = Math.max(16, ctx.measureText(badgeText).width * globalScale + 8) / globalScale;
      const badgeH = 14 / globalScale;
      const badgeX = node.x + hubW / 2 - badgeW - 4 / globalScale;
      const badgeY = node.y - hubH / 2 - badgeH / 2;
      ctx.beginPath();
      ctx.roundRect(badgeX, badgeY, badgeW, badgeH, 3 / globalScale);
      ctx.fillStyle = C.accentDangerDim;
      ctx.fill();
      ctx.fillStyle = C.accentDanger;
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      ctx.fillText(badgeText, badgeX + badgeW / 2, badgeY + badgeH / 2);
    }

    return;
  }
  const isDirectMatch = directMatchSet && directMatchSet.has(node.id);
  const isVisible = !visibleSet || visibleSet.has(node.id);
  const isDim = visibleSet && !isVisible;
  const label = formatName(node.name);
  const fontSize = isMailbox ? 12 / globalScale : 10 / globalScale;
  const cardW = isMailbox ? 140 / globalScale : 100 / globalScale;
  const cardH = isMailbox ? 44 / globalScale : 32 / globalScale;
  const radius = (isMailbox ? 6 : 4) / globalScale;

  if (isDim) {
    ctx.beginPath();
    ctx.roundRect(node.x - cardW / 2, node.y - cardH / 2, cardW, cardH, radius);
    ctx.fillStyle = C.cardBgDim;
    ctx.fill();
    return;
  }

  // Card shadow (light mode needs visible elevation)
  if (C.isLight) {
    ctx.save();
    ctx.shadowColor = 'rgba(0, 0, 0, 0.12)';
    ctx.shadowBlur = 8 / globalScale;
    ctx.shadowOffsetY = 2 / globalScale;
  }

  // Card background
  ctx.beginPath();
  ctx.roundRect(node.x - cardW / 2, node.y - cardH / 2, cardW, cardH, radius);
  ctx.fillStyle = isHovered ? C.cardBgHover : C.cardBg;
  ctx.fill();

  if (C.isLight) ctx.restore();

  ctx.beginPath();
  ctx.roundRect(node.x - cardW / 2, node.y - cardH / 2, cardW, cardH, radius);
  ctx.strokeStyle = isDirectMatch ? C.cardStrokeMatch
    : isHovered ? C.cardStrokeHover : C.cardStroke;
  ctx.lineWidth = (isDirectMatch ? 1.5 : 1) / globalScale;
  ctx.stroke();

  // Urgency ring
  if (isMailbox && node.urgency > 0.1) {
    ctx.beginPath();
    ctx.arc(node.x, node.y, cardW / 2 + 6 / globalScale, 0, 2 * Math.PI);
    ctx.strokeStyle = urgencyColor(node.urgency, C);
    ctx.globalAlpha = node.urgency * 0.5;
    ctx.lineWidth = 1.5 / globalScale;
    ctx.stroke();
    ctx.globalAlpha = 1;
  }

  // Avatar circle
  const avatarR = (isMailbox ? 12 : 8) / globalScale;
  const avatarX = node.x - cardW / 2 + avatarR + 8 / globalScale;
  const avatarY = node.y;
  ctx.beginPath();
  ctx.arc(avatarX, avatarY, avatarR, 0, 2 * Math.PI);
  ctx.fillStyle = isMailbox ? C.memberBg : C.externalBg;
  ctx.fill();

  // Avatar initial
  ctx.fillStyle = isMailbox ? C.accentPrimary : C.textTertiary;
  ctx.font = `bold ${avatarR}px "SF Pro Display", system-ui, sans-serif`;
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  ctx.fillText(label.charAt(0), avatarX, avatarY);

  // Name label
  const textX = avatarX + avatarR + 6 / globalScale;
  const maxTextW = cardW - (textX - (node.x - cardW / 2)) - 6 / globalScale;
  ctx.fillStyle = isMailbox ? C.textPrimary : C.textSecondary;
  ctx.font = `${isMailbox ? 600 : 400} ${fontSize}px "SF Pro Display", system-ui, sans-serif`;
  ctx.textAlign = 'left';
  ctx.textBaseline = 'middle';

  let displayName = label;
  while (ctx.measureText(displayName).width > maxTextW && displayName.length > 3) {
    displayName = displayName.slice(0, -2) + '…';
  }

  if (isMailbox) {
    ctx.fillText(displayName, textX, node.y - 5 / globalScale);
    ctx.fillStyle = C.textMuted;
    ctx.font = `400 ${8 / globalScale}px "Fira Code", monospace`;
    let addr = node.address;
    while (ctx.measureText(addr).width > maxTextW && addr.length > 5) {
      addr = addr.slice(0, -2) + '…';
    }
    ctx.fillText(addr, textX, node.y + 7 / globalScale);
  } else {
    ctx.fillText(displayName, textX, node.y);
  }

  // Unread badge
  if (isMailbox && node.unread > 0) {
    const badgeText = String(node.unread);
    ctx.font = `bold ${9 / globalScale}px "Fira Code", monospace`;
    const badgeW = Math.max(16, ctx.measureText(badgeText).width * globalScale + 8) / globalScale;
    const badgeH = 14 / globalScale;
    const badgeX = node.x + cardW / 2 - badgeW - 4 / globalScale;
    const badgeY = node.y - cardH / 2 - badgeH / 2;
    ctx.beginPath();
    ctx.roundRect(badgeX, badgeY, badgeW, badgeH, 3 / globalScale);
    ctx.fillStyle = C.accentDangerDim;
    ctx.fill();
    ctx.fillStyle = C.accentDanger;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillText(badgeText, badgeX + badgeW / 2, badgeY + badgeH / 2);
  }

  // Total badge
  if (isMailbox) {
    const totalText = String(node.total);
    ctx.font = `bold ${9 / globalScale}px "Fira Code", monospace`;
    const tBadgeW = Math.max(16, ctx.measureText(totalText).width * globalScale + 8) / globalScale;
    const tBadgeH = 14 / globalScale;
    const tBadgeX = node.x + cardW / 2 - tBadgeW - 4 / globalScale;
    const tBadgeY = node.y + cardH / 2 - tBadgeH / 2;
    ctx.beginPath();
    ctx.roundRect(tBadgeX, tBadgeY, tBadgeW, tBadgeH, 3 / globalScale);
    ctx.fillStyle = C.memberBg;
    ctx.fill();
    ctx.fillStyle = C.textTertiary;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillText(totalText, tBadgeX + tBadgeW / 2, tBadgeY + tBadgeH / 2);
  }

  // Weekly trend badge (top-left): this 7 days vs the prior 7. Only drawn when
  // there's enough volume to mean something and the change is >= 10%.
  if (isMailbox && (node.recent || 0) + (node.prior || 0) >= 5) {
    const pct = trendPct(node.recent || 0, node.prior || 0);
    if (pct !== null && Math.abs(pct) >= 0.1) {
      const up = pct > 0;
      const trendText = pct === Infinity ? '▲new' : `${up ? '▲' : '▼'}${Math.round(Math.abs(pct) * 100)}%`;
      ctx.font = `bold ${9 / globalScale}px "Fira Code", monospace`;
      const trBadgeW = ctx.measureText(trendText).width + 8 / globalScale;
      const trBadgeH = 14 / globalScale;
      const trBadgeX = node.x - cardW / 2 + 4 / globalScale;
      const trBadgeY = node.y - cardH / 2 - trBadgeH / 2;
      ctx.beginPath();
      ctx.roundRect(trBadgeX, trBadgeY, trBadgeW, trBadgeH, 3 / globalScale);
      ctx.fillStyle = up ? C.accentWarningDim : C.accentSuccessDim;
      ctx.fill();
      ctx.fillStyle = up ? C.accentWarning : C.accentSuccess;
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      ctx.fillText(trendText, trBadgeX + trBadgeW / 2, trBadgeY + trBadgeH / 2);
    }
  }
}

export function nodePointerAreaPaint(node, color, ctx, globalScale) {
  const isHub = node.type === 'channel_hub';
  const isMailbox = node.type === 'mailbox';
  const cardW = (isHub ? 160 : isMailbox ? 140 : node.type === 'entity' ? 110 : 100) / globalScale;
  const cardH = (isHub ? 54 : isMailbox ? 44 : 32) / globalScale;
  ctx.fillStyle = color;
  ctx.fillRect(node.x - cardW / 2, node.y - cardH / 2, cardW, cardH);
}

// Custom Canvas link renderer. `state` carries { colors, hoveredNode, visibleSet }.
export function paintLink(link, ctx, globalScale, state) {
  const { colors: C, hoveredNode, visibleSet } = state;
  const start = link.source;
  const end = link.target;
  if (!start || !end || typeof start.x === 'undefined') return;

  const isHighlighted = hoveredNode &&
    (hoveredNode === start.id || hoveredNode === end.id);

  // Dim links when searching and neither endpoint matches
  if (visibleSet && !visibleSet.has(start.id) && !visibleSet.has(end.id)) {
    return; // skip drawing entirely
  }

  ctx.beginPath();
  ctx.moveTo(start.x, start.y);
  const mx = (start.x + end.x) / 2;
  const my = (start.y + end.y) / 2;
  const dx = end.x - start.x;
  const dy = end.y - start.y;
  const push = 20 / globalScale;
  const cpx = mx - dy * 0.15 + (link.curvature || 0) * push;
  const cpy = my + dx * 0.15 + (link.curvature || 0) * push;
  ctx.quadraticCurveTo(cpx, cpy, end.x, end.y);

  ctx.strokeStyle = isHighlighted ? C.linkHighlight : linkColorFor(link, C);
  ctx.lineWidth = (isHighlighted ? 1.5 : Math.min(0.5 + link.weight * 0.3, 2)) / globalScale;
  if (!isHighlighted) {
    ctx.setLineDash([3 / globalScale, 3 / globalScale]);
  }
  ctx.stroke();
  ctx.setLineDash([]);
}

// An ontology entity (organization / person / product / project): a contact-size
// card whose avatar ring carries the kind's hue, and an org/product's domain logo
// when `state.logoCache` (domain → loaded Image) has it.
export function paintEntityNode(node, ctx, globalScale, state) {
  const { colors: C, hoveredNode, directMatchSet, visibleSet, logoCache } = state;
  const isHovered = hoveredNode === node.id;
  const isDirectMatch = directMatchSet && directMatchSet.has(node.id);
  const isDim = visibleSet && !visibleSet.has(node.id);
  const hue = C.kind?.[node.kind] || C.accentPrimary;
  const cardW = 110 / globalScale;
  const cardH = 32 / globalScale;
  const left = node.x - cardW / 2;

  ctx.beginPath();
  ctx.roundRect(left, node.y - cardH / 2, cardW, cardH, 4 / globalScale);
  ctx.fillStyle = isDim ? C.cardBgDim : isHovered ? C.cardBgHover : C.cardBg;
  ctx.fill();
  if (isDim) return;
  ctx.strokeStyle = isDirectMatch ? C.cardStrokeMatch : isHovered ? hue : C.cardStroke;
  ctx.lineWidth = (isDirectMatch ? 1.5 : 1) / globalScale;
  ctx.stroke();

  const r = 9 / globalScale;
  const ax = left + r + 7 / globalScale;
  const logo = node.email_domain && logoCache?.current?.get(node.email_domain);
  ctx.beginPath();
  ctx.arc(ax, node.y, r, 0, 2 * Math.PI);
  ctx.fillStyle = C.cardBgHover;
  ctx.fill();
  if (logo && logo.complete && logo.naturalWidth > 0) {
    ctx.save();
    ctx.clip();
    ctx.drawImage(logo, ax - r, node.y - r, r * 2, r * 2);
    ctx.restore();
  } else {
    ctx.fillStyle = hue;
    ctx.font = `bold ${r}px "SF Pro Display", system-ui, sans-serif`;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillText((node.name || '?').charAt(0).toUpperCase(), ax, node.y);
  }
  ctx.beginPath();
  ctx.arc(ax, node.y, r, 0, 2 * Math.PI);
  ctx.strokeStyle = hue;
  ctx.lineWidth = 1.5 / globalScale;
  ctx.stroke();

  const textX = ax + r + 6 / globalScale;
  const maxW = left + cardW - textX - 5 / globalScale;
  ctx.fillStyle = C.textPrimary;
  ctx.font = `500 ${10 / globalScale}px "SF Pro Display", system-ui, sans-serif`;
  ctx.textAlign = 'left';
  ctx.textBaseline = 'middle';
  let name = node.name || '';
  while (ctx.measureText(name).width > maxW && name.length > 3) name = name.slice(0, -2) + '…';
  ctx.fillText(name, textX, node.y - 4 / globalScale);
  ctx.fillStyle = C.textMuted;
  ctx.font = `400 ${7 / globalScale}px "Fira Code", monospace`;
  ctx.fillText(node.kind, textX, node.y + 7 / globalScale);
}
