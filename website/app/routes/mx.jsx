import Hero from "../components/Hero/Hero.jsx";
import StatChips from "../components/StatChips/StatChips.jsx";
import FeatureCards from "../components/FeatureCards/FeatureCards.jsx";
import SendingApi from "../components/SendingApi/SendingApi.jsx";
import MailClients from "../components/MailClients/MailClients.jsx";
import Pricing from "../components/Pricing/Pricing.jsx";
import ConsoleSection from "../components/ConsoleSection/ConsoleSection.jsx";
import Sovereignty from "../components/Sovereignty/Sovereignty.jsx";
import Proof from "../components/Proof/Proof.jsx";
import CrossLink from "../components/CrossLink/CrossLink.jsx";
import WindowFrame from "../components/WindowFrame/WindowFrame.jsx";
import Closing from "../components/Closing/Closing.jsx";

export function meta() {
  return [
    { title: "inbox2 MX | One inbox for your domain" },
    {
      name: "description",
      content:
        "Point your domain's MX at inbox2 and every message lands in the domain's inbox. Each person builds a view over it, rules route the rest, and your app sends from the same domain through the API. Plans start at €0, hosted by us or run by you.",
    },
  ];
}

export default function Mx() {
  return (
    <>
      <Hero />
      <StatChips />
      <FeatureCards />
      <SendingApi />
      <Pricing />
      <ConsoleSection />
      <MailClients />
      <Sovereignty />
      <Proof />
      <CrossLink
        kicker="The apps"
        title="Free apps for every device you own"
        cta="See the apps"
        to="/"
        body="The apps for macOS, Windows, Linux, iOS, Android, the browser and the terminal all run the same Rust core over a local file on your own disk. They work with the accounts you already have, whether or not your domain lives here. Every one of them is free."
      >
        <WindowFrame src="/assets/shots/spaces.webp" alt="Spaces boards in the desktop app" bare />
      </CrossLink>
      <Closing />
    </>
  );
}
