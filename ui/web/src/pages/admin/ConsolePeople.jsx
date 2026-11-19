import useAuth from '../../hooks/useAuth';
import AdminPeople from './AdminPeople';
import { orgToDomain } from '../../hooks/useAdminData';
import styles from './console.module.css';

/* People view — the full team/access surface, one table per org (AdminPeople
 * brings its own section chrome: member rows, domain grants, visibility rules,
 * invite; clicking a person opens their access page). */
export default function ConsolePeople() {
  const { organizations } = useAuth();

  return (
    <>
      <div className={styles.pageHead}>
        <div>
          <div className={styles.pageEyebrow}>People</div>
          <h1 className={styles.pageTitle}>People</h1>
          <p className={styles.pageSub}>
            Who’s in the workspace and which domains they see.
          </p>
        </div>
      </div>

      {(organizations || []).map((org) => (
        <AdminPeople
          key={org.id}
          scopeDomain={orgToDomain(org)}
          title={organizations.length > 1 ? `Team · ${org.domain || org.name}` : 'Team'}
        />
      ))}
    </>
  );
}
