import useBrand from '../../hooks/useBrand';
import { serverDomain } from '../../lib/mcpClient';
import Icon from '../Icon';
import styles from './SendTo.module.css';

/** A connected MCP server's logo, looked up by its URL's domain. */
export default function SendToLogo({ url }) {
  const brand = useBrand(serverDomain(url));
  if (brand?.icon) return <img className={styles.logo} src={brand.icon} alt="" />;
  return <span className={styles.logoFallback}><Icon name="link" size={14} /></span>;
}
