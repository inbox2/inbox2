import { NavLink } from "react-router";
import Lockup from "../Mark/Mark.jsx";
import Button from "../Button/Button.jsx";
import { NAV_ITEMS, LOGIN_URL, SIGNUP_URL } from "../../lib/nav.js";
import styles from "./Nav.module.css";

export default function Nav() {
  return (
    <nav className={styles.nav}>
      <div className={`wrap ${styles.inner}`}>
        <Lockup />
        <ul className={styles.links}>
          {NAV_ITEMS.map((item) => (
            <li key={item.id}>
              {item.to ? (
                /* `end` so Home isn't active on every route. */
                <NavLink to={item.to} end className={({ isActive }) => (isActive ? styles.active : "")}>{item.label}</NavLink>
              ) : (
                <a href={item.href} target="_blank" rel="noopener">{item.label}</a>
              )}
            </li>
          ))}
        </ul>
        <div className={styles.right}>
          <a href={LOGIN_URL} className={styles.login}>Log in</a>
          <Button variant="glass" size="sm" href={SIGNUP_URL}>Start free</Button>
        </div>
      </div>
    </nav>
  );
}
