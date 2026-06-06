import type { ReactNode } from "react";

export const metadata = {
  title: "PokeGenie Raid Queue",
  description: "Fairly reserve a slot in a high-demand Pokémon GO raid.",
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body style={{ fontFamily: "system-ui, sans-serif", maxWidth: 720, margin: "2rem auto", padding: "0 1rem" }}>
        <header>
          <h1>PokeGenie Raid Queue</h1>
          <p style={{ color: "#666" }}>Join the line · wait your turn · claim a slot</p>
        </header>
        {children}
      </body>
    </html>
  );
}
