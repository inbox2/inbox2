import { format, isToday, isThisWeek, isThisYear } from 'date-fns';

// App-style row time: the time today, "Tue" this week, "3 Oct" this year, else 3/10/24.
export function rowTime(iso) {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '';
  // Today: a clock time in the user's own 12/24-hour convention.
  if (isToday(d)) return d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
  if (isThisWeek(d, { weekStartsOn: 1 })) return format(d, 'EEE');
  if (isThisYear(d)) return format(d, 'd MMM');
  return format(d, 'd/M/yy');
}
