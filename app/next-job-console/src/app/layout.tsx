import type { Metadata } from "next";
import { Space_Grotesk, IBM_Plex_Mono } from "next/font/google";
import "./globals.css";

const bodyFont = Space_Grotesk({ subsets: ["latin"], variable: "--font-body" });
const monoFont = IBM_Plex_Mono({ subsets: ["latin"], weight: ["400", "500"], variable: "--font-mono" });

export const metadata: Metadata = {
  title: "Practice Bank Job Console",
  description: "Next.js dashboard for triggering ACA jobs via Flask wrapper API",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="ja">
      <body className={`${bodyFont.variable} ${monoFont.variable}`}>{children}</body>
    </html>
  );
}
