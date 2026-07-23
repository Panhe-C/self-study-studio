import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Self Study Studio — Learning Workspace",
  description:
    "Plan deliberately, practice on iPhone, and review evidence in one personal learning journal.",
  icons: {
    icon: "/app-icon.png",
    shortcut: "/app-icon.png",
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <head>
        <script
          defer
          src="https://cdn.apple-cloudkit.com/ck/2/CloudKit.js"
        />
      </head>
      <body>{children}</body>
    </html>
  );
}
