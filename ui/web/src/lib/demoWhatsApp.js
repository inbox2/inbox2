// Demo-mode WhatsApp (lib/demoData.js): a fictional set of chats that stands in
// for WhatsApp Desktop's database while demo mode is on — the tab, the columns,
// global search, the media viewer and Lore all read from here, so a screenshot
// never shows a real chat. Same shapes as whatsapp.rs returns (wa_chats,
// wa_messages, wa_search, wa_chat_media, wa_lore rows). Photos are the demo faces
// under public/images (absolute paths, which waMediaUrl passes through).

const MIN = 60 * 1000;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;

// Times are offsets back from "now" at load, so the demo always looks current.
const ago = (ms) => Date.now() - ms;

// ZMESSAGETYPE values (lib/localWhatsApp.js WA_KIND).
const TEXT = 0;
const IMAGE = 1;
const SYSTEM = 6;
const DOCUMENT = 8;

const photo = (n, caption = null, aspect = 0.8) => ({
  path: `/images/a${n}.jpg`, thumb: null, title: caption, name: `IMG-20261025-WA00${n}.jpg`,
  aspect, size: 184_000, duration: 0, latitude: 0, longitude: 0,
});
const doc = (name, size) => ({
  path: null, thumb: null, title: name, name, aspect: 0, size, duration: 0, latitude: 0, longitude: 0,
});

// [chat, messages oldest first as [minutesAgo, fromMe, text, sender?, kind?, media?]]
const CHATS = [
  {
    id: 9001, jid: '31600000001@s.whatsapp.net', name: 'Sarah Chen', is_group: false, archived: false, unread: 2,
    avatar: '/images/a2.jpg',
    messages: [
      [190, false, 'Morning! Did you get a chance to look at the Northwind proposal?'],
      [184, true, 'Not yet, on it after standup'],
      [62, false, 'No rush, but they want an answer by Friday'],
      [61, false, 'Here are the slides from yesterday', null, IMAGE, photo(4, 'Slide 6 has the new pricing', 1.6)],
      [12, false, 'Can you send me the signed contract before 3pm today?'],
      [11, false, 'Legal needs it for the filing 🙏'],
    ],
  },
  {
    id: 9002, jid: '120363000000001@g.us', name: 'Northwind launch 🚀', is_group: true, archived: false, unread: 5,
    avatar: null,
    messages: [
      [600, false, 'Tomas Kok added Aisha Rahman', null, SYSTEM],
      [420, false, 'Landing page copy is in the doc, comments welcome', 'Tomas Kok'],
      [415, true, 'Looks great, two small notes on the hero'],
      [95, false, 'Press kit is ready', 'Aisha Rahman', DOCUMENT, doc('Northwind-press-kit.pdf', 2_400_000)],
      [40, false, '@You can you approve the launch date? Marketing wants to book the slots', 'Marieke de Groot'],
      [38, false, '+1, we need it today', 'Tomas Kok'],
    ],
  },
  {
    id: 9003, jid: '31600000003@s.whatsapp.net', name: 'Jasper Vos', is_group: false, archived: false, unread: 0,
    avatar: '/images/a5.jpg',
    messages: [
      [2 * 60 * 24, false, 'Thanks for the intro to Lumenworks!'],
      [2 * 60 * 24 - 30, true, 'Any time, they were keen to talk'],
      [300, false, 'Lunch Thursday?'],
      [290, true, 'Thursday works, 12:30 at Café Binnenhof?'],
      [285, false, 'Perfect 👍'],
    ],
  },
  {
    id: 9004, jid: '31600000004@s.whatsapp.net', name: 'Aisha Rahman', is_group: false, archived: false, unread: 1,
    avatar: '/images/a3.jpg',
    messages: [
      [26 * 60, true, 'Sent you the Q4 budget draft'],
      [80, false, 'Got it. The invoice from Helixpay is €12,480 and due on the 31st, can you pay it this week?'],
    ],
  },
  {
    id: 9005, jid: '120363000000002@g.us', name: 'Family', is_group: true, archived: false, unread: 0,
    avatar: null,
    messages: [
      [9 * 60, false, 'Who is bringing the cake on Sunday?', 'Elena Marchetti'],
      [8 * 60, true, 'I will 🎂'],
      [7 * 60, false, 'Look who learned to swim!', 'Elena Marchetti', IMAGE, photo(6, null, 0.75)],
    ],
  },
  {
    id: 9006, jid: '31600000006@s.whatsapp.net', name: 'Daniel Okafor', is_group: false, archived: false, unread: 0,
    avatar: '/images/a1.jpg',
    messages: [
      [3 * 60 * 24, false, 'Are we still on for the Kestrel Data review next week?'],
      [3 * 60 * 24 - 5, true, 'Yes, Tuesday 10:00'],
    ],
  },
  {
    id: 9007, jid: '31600000007@s.whatsapp.net', name: 'Priya Menon', is_group: false, archived: true, unread: 0,
    avatar: '/images/a4.jpg',
    messages: [
      [9 * 60 * 24, false, 'Here is the onboarding plan we discussed'],
      [9 * 60 * 24 - 10, true, 'Thanks Priya!'],
    ],
  },
];

const deleted = (kind) => kind === 14;
const preview = ([, , text, , kind, media]) => {
  if (kind === IMAGE) return `📷 ${media?.title || 'Photo'}`;
  if (kind === DOCUMENT) return `📄 ${media?.name || 'Document'}`;
  return deleted(kind) ? 'This message was deleted' : text;
};

let pk = 50_000;
const BUILT = CHATS.map((c) => {
  const messages = c.messages.map((m) => {
    const [minutes, fromMe, text, sender = null, kind = TEXT, media = null] = m;
    return {
      id: ++pk,
      chat_id: c.id,
      from_me: fromMe,
      at: ago(minutes * MIN),
      kind,
      text: kind === IMAGE ? null : kind === DOCUMENT ? media?.name : text,
      sender: fromMe || !c.is_group ? null : sender,
      sender_avatar: null,
      media,
    };
  });
  const last = c.messages[c.messages.length - 1];
  return {
    chat: {
      id: c.id, jid: c.jid, name: c.name, is_group: c.is_group, archived: c.archived, unread: c.unread,
      last_text: preview(last), last_at: ago(last[0] * MIN), avatar: c.avatar,
    },
    messages,
  };
});
const byId = new Map(BUILT.map((b) => [b.chat.id, b]));

export const demoWaStatus = () => ({
  available: true, error: null, head: pk, version: `demo.${pk}`,
  unread: BUILT.filter((b) => b.chat.unread && !b.chat.archived).length,
});

export const demoWaChats = () => BUILT.map((b) => b.chat).sort((a, b) => b.last_at - a.last_at);

export const demoWaMessages = (chatId) => ({ messages: byId.get(chatId)?.messages || [], has_earlier: false });

export function demoWaSearch(query) {
  const terms = String(query || '').toLowerCase().split(/\s+/).filter(Boolean);
  if (!terms.length) return [];
  return BUILT.flatMap(({ chat, messages }) => messages
    .filter((m) => terms.every((t) => `${m.text || ''} ${m.media?.title || ''}`.toLowerCase().includes(t)))
    .map((m) => ({
      id: m.id, chat_id: chat.id, chat_name: chat.name, chat_avatar: chat.avatar, is_group: chat.is_group,
      from_me: m.from_me, sender: m.sender, at: m.at, text: m.text || m.media?.title || '',
    })))
    .sort((a, b) => b.at - a.at);
}

export const demoWaChatMedia = (chatId) => (byId.get(chatId)?.messages || [])
  .filter((m) => m.kind === IMAGE && m.media?.path)
  .map((m) => ({ id: m.id, kind: IMAGE, path: m.media.path, thumb: null, at: m.at, from_me: m.from_me, sender: m.sender, name: m.media.name }));

/** Lore's wa_lore rows in demo mode: the asks in the chats above. */
export function demoWaLoreRows(status = 'open') {
  if (status !== 'open') return [];
  const ask = (chatId, label, priority, title, summary, extra = {}) => {
    const { chat, messages } = byId.get(chatId);
    const last = messages[messages.length - 1];
    return {
      chat_id: chat.id, chat_name: chat.name, is_group: chat.is_group ? 1 : 0, avatar: chat.avatar,
      ask_from_id: messages[Math.max(0, messages.length - 2)].id, ask_through_id: last.id,
      ask_at: new Date(last.at).toISOString(), sender: last.sender, label, priority, title, summary,
      next_action_due_on: null, next_action_amount_cents: null, next_action_currency: null, status: 'open', ...extra,
    };
  };
  return [
    ask(9001, 'action_required', 3, 'Send Sarah the signed contract before 3pm', 'Legal needs it for the filing today.'),
    ask(9002, 'needs_approval', 3, 'Approve the Northwind launch date', 'Marketing wants to book the launch slots today.'),
    ask(9004, 'payment_due', 2, 'Pay the Helixpay invoice', 'Aisha asks to pay €12,480 this week.', {
      next_action_amount_cents: 1248000, next_action_currency: 'EUR',
      next_action_due_on: new Date(Date.now() + 5 * DAY).toISOString().slice(0, 10),
    }),
  ];
}
