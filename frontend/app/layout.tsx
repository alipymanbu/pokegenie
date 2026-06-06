import type { ReactNode } from "react";
import "./globals.css";

export const metadata = {
  title: "PokeGenie Raid Queue",
  description: "Fairly reserve a slot in a high-demand Pokémon GO raid.",
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body>
        <header className="site-header">
          <div className="container">
            <span className="pokeball" aria-hidden />
            <div>
              <h1 className="site-title">PokeGenie Raid Queue</h1>
              <p className="site-tagline">Join the line · wait your turn · claim a slot</p>
            </div>
          </div>
        </header>
        <div className="container">
          <main>{children}</main>
        </div>
      </body>
    </html>
  );
}
