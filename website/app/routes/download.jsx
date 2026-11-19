import Download from "../components/Download/Download.jsx";
import Closing from "../components/Closing/Closing.jsx";

export function meta() {
  return [
    { title: "Download | inbox2" },
    { name: "description", content: "Download the free, open-source inbox2 apps for macOS, Windows, Linux, iOS and Android. They work offline." },
  ];
}

export default function DownloadPage() {
  return (
    <>
      <Download dark h1 heading="Download the free native apps" />
      <Closing />
    </>
  );
}
