import { create } from 'zustand';

// The calendar's views (keys of CalendarPage's VIEW_MAP).
export const CALENDAR_VIEW = { MONTH: 'month', WEEK: 'week', WORKWEEK: 'workweek', DAY: 'day', AGENDA: 'agenda' };

const useCalendarStore = create((set, get) => ({
  // View state
  view: CALENDAR_VIEW.WEEK,
  currentDate: new Date(),
  visibleStart: null,       // start of FullCalendar visible range
  visibleEnd: null,         // end of FullCalendar visible range
  selectedEventId: null,
  activeAccountKey: null,   // null = unified (all accounts)

  // Data
  calendars: [],
  events: [],
  visibleCalendarIds: new Set(),

  // View actions
  setView: (view) => set({ view }),
  setCurrentDate: (date) => set({ currentDate: date }),
  setVisibleRange: (start, end) => set({ visibleStart: start, visibleEnd: end }),
  selectEvent: (id) => set({ selectedEventId: id }),
  setActiveAccountKey: (key) => set({ activeAccountKey: key }),

  // Calendar actions
  setCalendars: (calendars) => set({
    calendars,
    visibleCalendarIds: new Set(calendars.filter(c => c.is_visible).map(c => c.id)),
  }),

  toggleCalendarVisibility: (calId) => set((state) => {
    const next = new Set(state.visibleCalendarIds);
    if (next.has(calId)) {
      next.delete(calId);
    } else {
      next.add(calId);
    }
    return { visibleCalendarIds: next };
  }),

  // Event actions
  setEvents: (events) => set({ events }),

  addEvent: (event) => set((state) => ({
    events: [...state.events, event],
  })),

  updateEvent: (id, changes) => set((state) => ({
    events: state.events.map(e => e.id === id ? { ...e, ...changes } : e),
  })),

  removeEvent: (id) => set((state) => ({
    events: state.events.filter(e => e.id !== id),
  })),

  // Computed — returns visible events only
  visibleEvents: () => {
    const { events, visibleCalendarIds } = get();
    if (visibleCalendarIds.size === 0) return events;
    return events.filter(e => visibleCalendarIds.has(e.calendar_id));
  },
}));

export default useCalendarStore;
