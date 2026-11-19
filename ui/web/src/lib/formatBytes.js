/**
 * Human-readable byte size, e.g. 14_680_064 → "14.0 MB".
 * Shared by the conversation list/detail (attachment sizes), the composer's
 * attachment tokens and Disk (file sizes, the pooled quota meter) so all render
 * sizes identically. Tops out at TB.
 */
export default function formatBytes(bytes) {
  if (!bytes || bytes < 1) return '0 B';
  const k = 1024;
  const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
  const i = Math.min(Math.floor(Math.log(bytes) / Math.log(k)), sizes.length - 1);
  return `${(bytes / Math.pow(k, i)).toFixed(i > 0 ? 1 : 0)} ${sizes[i]}`;
}
