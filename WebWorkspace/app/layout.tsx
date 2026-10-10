import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Self Study Studio — 个人学习工作台",
  description:
    "查看学习项目与下一步，整理计划，在 iPhone 上练习并记录，再回到网页查看学习证据与复盘。",
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
    <html lang="zh-CN">
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
