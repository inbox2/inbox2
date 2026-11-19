import StatusPage from '../../components/StatusPage/StatusPage';

export default function ErrorPage() {
  return (
    <StatusPage
      code="500"
      title="Something went wrong"
      message="Try again. If it keeps happening, contact support."
      linkTo="/"
      linkLabel="Go back to inbox"
    />
  );
}
