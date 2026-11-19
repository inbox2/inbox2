import { useEffect, useState } from "react";
import Button from "../Button/Button.jsx";
import { OsIcon, PLATFORMS } from "../OsIcons/OsIcons.jsx";
import { useLatestRelease, installerFor } from "../../lib/releases.js";

/** Which of the five builds this visitor wants. iPadOS reports itself as a Mac,
 *  so the touch count is what separates an iPad from a laptop. */
function detect() {
  const ua = navigator.userAgent;
  const plat = navigator.userAgentData?.platform || navigator.platform || "";
  if (/Android/i.test(ua)) return "android";
  if (/iPhone|iPad|iPod/i.test(ua) || (/Mac/i.test(plat) && navigator.maxTouchPoints > 1)) return "ios";
  if (/Mac/i.test(plat) || /Mac OS X/i.test(ua)) return "macos";
  if (/Win/i.test(plat) || /Windows/i.test(ua)) return "windows";
  if (/Linux|X11/i.test(ua)) return "linux";
  return null;
}

/**
 * The hero's primary call to action, aimed at the platform you are reading on.
 * The prerendered HTML carries the neutral version, so detection happens on
 * mount and an unrecognised browser keeps the page of all five builds.
 */
export default function DownloadButton({ size = "lg", variant = "accent", className = "" }) {
  const [id, setId] = useState(null);
  // eslint-disable-next-line react-hooks/set-state-in-effect -- navigator only exists in the browser, so the platform is detected on mount.
  useEffect(() => setId(detect()), []);
  const release = useLatestRelease();

  const platform = PLATFORMS.find((p) => p.id === id);
  if (!platform) {
    return <Button size={size} variant={variant} to="/download" className={className}>Download for desktop</Button>;
  }
  return (
    <Button size={size} variant={variant} href={installerFor(release, platform.id) || platform.href} className={className}>
      <OsIcon id={platform.id} size={20} />
      Download for {platform.name}
    </Button>
  );
}
