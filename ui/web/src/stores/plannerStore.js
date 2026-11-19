import { create } from 'zustand';

/**
 * Timezone-planner open state. The planner is opened from two places that
 * never share a tree — the calendar's zone picker and the command palette —
 * so it's mounted once globally (routes.jsx) and both just flip this.
 */
const usePlannerStore = create((set) => ({
  open: false,
  openPlanner: () => set({ open: true }),
  closePlanner: () => set({ open: false }),
}));

export default usePlannerStore;
