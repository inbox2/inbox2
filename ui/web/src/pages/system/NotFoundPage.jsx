import StatusPage from '../../components/StatusPage/StatusPage';

export default function NotFoundPage() {
  return (
    <StatusPage
      code="404"
      title="Page not found"
      message="This page doesn't exist or it moved."
      linkTo="/"
      linkLabel="Go back to inbox"
    />
  );
}
