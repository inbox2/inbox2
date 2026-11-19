import StatusPage from '../../components/StatusPage/StatusPage';

export default function NoAccessPage() {
  return (
    <StatusPage
      code="403"
      title="You don't have access"
      message="Ask your admin if you think you should see this page."
      linkTo="/"
      linkLabel="Go back to inbox"
    />
  );
}
