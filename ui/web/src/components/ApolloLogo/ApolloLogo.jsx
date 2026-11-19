// Apollo.io brand mark — shared between the integration settings panel and the
// inbox Contact panel's enrich action.
export default function ApolloLogo({ size = 24 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 32 32" fill="none" aria-hidden="true">
      <circle cx="16" cy="16" r="16" fill="#6B4FBB" />
      <path d="M16 6l7.5 18h-3.2l-1.5-3.8h-5.6L11.7 24H8.5L16 6zm0 5.8L13.2 18h5.6L16 11.8z" fill="white" />
    </svg>
  );
}
