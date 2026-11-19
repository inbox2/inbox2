import { useState, useMemo, useEffect } from 'react';
import { useNavigate, useSearchParams } from 'react-router';

// ChromeBar search-box wiring shared by the inbox views: Enter navigates to
// the full results page, Escape clears + blurs the box. Returns the live
// query (some views key empty-state chrome off it) plus the searchProps
// object ChromeBar expects.
export default function useChromeSearch(orgSlug) {
  const navigate = useNavigate();
  const [searchParams] = useSearchParams();
  // The running search lives in ?q= — including the operators the Filters
  // dialog writes ("hetzner from:ana larger:5mb"). Mirror it into the box so
  // what's on screen is what's actually being searched, and so editing the
  // text picks up where the dialog left off.
  const urlQuery = searchParams.get('q') || '';
  const [searchQuery, setSearchQuery] = useState(urlQuery);

  // Only a URL that HAS a query writes to the box, so leaving the results page
  // doesn't wipe what you typed.
  /* eslint-disable react-hooks/set-state-in-effect -- intentional: follow the URL's query */
  useEffect(() => { if (urlQuery) setSearchQuery(urlQuery); }, [urlQuery]);
  /* eslint-enable react-hooks/set-state-in-effect */

  const searchProps = useMemo(() => ({
    value: searchQuery,
    onChange: (e) => setSearchQuery(e.target.value),
    onKeyDown: (e) => {
      if (e.key === 'Escape') {
        setSearchQuery('');
        e.target.blur();
        return;
      }
      if (e.key !== 'Enter' || !searchQuery.trim()) return;
      const base = orgSlug ? `/${orgSlug}` : '/mail';
      navigate(`${base}/search?q=${encodeURIComponent(searchQuery)}`);
    },
    onClear: () => setSearchQuery(''),
  }), [searchQuery, orgSlug, navigate]);

  return { searchQuery, searchProps };
}
