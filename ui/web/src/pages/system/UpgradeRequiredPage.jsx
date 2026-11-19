import StatusPage from '../../components/StatusPage/StatusPage';
import { consolePath } from '../../lib/consoleHost';

export default function UpgradeRequiredPage() {
  return (
    <StatusPage
      code={"\u2B06"}
      title="Upgrade to add this"
      message="This needs a paid plan. Compare plans and upgrade from billing."
      linkTo={consolePath('billing')}
      linkLabel="Go to billing & plan"
    />
  );
}
