import { create } from 'zustand';
import api from '../lib/api';
import log from '../lib/log';
import { ZONE_HIDDEN_CATEGORIES } from '../lib/storageKeys';
import { clearDismissed } from '../lib/zones';

// Calendar zones (docs/Calendar.md "Zones"). One store so the calendar grid, the
// sidebar, the start alert and the menu bar title all read the same zones —
// whichever of them fetched last.

function loadHidden() {
  try { return new Set(JSON.parse(localStorage.getItem(ZONE_HIDDEN_CATEGORIES) || '[]')); }
  catch { return new Set(); }
}

const overlaps = (z, from, to) => Date.parse(z.start_at) < to && Date.parse(z.end_at) > from;
const byStart = (a, b) => Date.parse(a.start_at) - Date.parse(b.start_at);

// ponytail: writes refetch the whole window seen so far rather than patching
// occurrences locally — a repeating zone's edit moves every day it runs.
const MAX_SPAN_MS = 400 * 24 * 3600 * 1000;

const useZoneStore = create((set, get) => ({
  zones: [],
  deletions: 0, // bumped by deleteZone; useZoneAlerts sweeps cards only then
  categories: [],
  span: null, // [fromMs, toMs] — everything fetched so far
  hiddenCategoryIds: loadHidden(),

  /** Sign-out: drop everything, the next account starts clean. */
  reset() {
    set({ zones: [], categories: [], span: null });
  },

  async loadCategories() {
    try {
      const res = await api.listZoneCategories();
      set({ categories: res?.zone_categories || [] });
    } catch (e) {
      log.warn('Zones', `categories fetch failed: ${e?.message || e}`);
    }
  },

  /** Refetch one window; zones in it are replaced, the rest are kept. */
  async loadRange(from, to) {
    try {
      const res = await api.listZones(from.toISOString(), to.toISOString());
      const fresh = res?.zones || [];
      const f = from.getTime();
      const t = to.getTime();
      set((s) => ({
        zones: [...s.zones.filter(z => !overlaps(z, f, t) && !fresh.some(n => n.id === z.id)), ...fresh].sort(byStart),
        span: s.span ? [Math.min(s.span[0], f), Math.max(s.span[1], t)] : [f, t],
      }));
    } catch (e) {
      log.warn('Zones', `zones fetch failed: ${e?.message || e}`);
    }
  },

  /** Refetch everything seen so far — after a write that may touch many days. */
  async refresh() {
    const { span } = get();
    if (!span) return;
    const to = Math.min(span[1], span[0] + MAX_SPAN_MS);
    await get().loadRange(new Date(span[0]), new Date(to));
  },

  async createZone(params) {
    const res = await api.createZone(params);
    await get().refresh();
    return res?.zone;
  },

  /** `id` may be a series key or an occurrence id — the API takes both. */
  async updateZone(id, params) {
    const res = await api.updateZone(id, params);
    // Drop the series' old occurrences first: moved ones would otherwise linger
    // outside the refetch overlap.
    const series = res?.zone?.series_id;
    if (series) {
      clearDismissed(series);
      set((s) => ({ zones: s.zones.filter(z => z.series_id !== series) }));
    }
    await get().refresh();
    return res?.zone;
  },

  /** Deletes the whole series, or with `only` just this occurrence of a repeating zone. */
  async deleteZone(zone, { only = false } = {}) {
    await api.deleteZone(zone.id, { only });
    // deletions tells useZoneAlerts a zone is gone (an edit also drops occurrences, but keeps its card).
    set((s) => ({
      zones: s.zones.filter(z => (only ? z.id !== zone.id : z.series_id !== zone.series_id)),
      deletions: (s.deletions || 0) + 1,
    }));
  },

  async createCategory(params) {
    const res = await api.createZoneCategory(params);
    if (res?.zone_category) set((s) => ({ categories: [...s.categories, res.zone_category] }));
    return res?.zone_category;
  },

  async updateCategory(id, params) {
    const res = await api.updateZoneCategory(id, params);
    if (res?.zone_category) set((s) => ({ categories: s.categories.map(c => (c.id === id ? res.zone_category : c)) }));
    return res?.zone_category;
  },

  async deleteCategory(id) {
    await api.deleteZoneCategory(id);
    set((s) => ({
      categories: s.categories.filter(c => c.id !== id),
      zones: s.zones.map(z => (z.category_id === id ? { ...z, category_id: null } : z)),
    }));
  },

  toggleCategory(id) {
    const next = new Set(get().hiddenCategoryIds);
    if (next.has(id)) next.delete(id); else next.add(id);
    try { localStorage.setItem(ZONE_HIDDEN_CATEGORIES, JSON.stringify([...next])); } catch { /* private mode */ }
    set({ hiddenCategoryIds: next });
  },
}));

export default useZoneStore;
