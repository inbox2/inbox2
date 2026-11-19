// What the user last sent from / last created an event on — the default for a
// new message's From and a new event's calendar when no account is filtered.
import { LAST_FROM_ADDRESS, LAST_EVENT_CALENDAR } from './storageKeys';

export const getLastFrom = () => localStorage.getItem(LAST_FROM_ADDRESS);
export const setLastFrom = (address) => { if (address) localStorage.setItem(LAST_FROM_ADDRESS, address); };

export const getLastCalendar = () => localStorage.getItem(LAST_EVENT_CALENDAR);
export const setLastCalendar = (id) => { if (id) localStorage.setItem(LAST_EVENT_CALENDAR, id); };
