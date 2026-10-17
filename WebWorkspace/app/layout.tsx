import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Self Study Studio — 学习内容进度",
  description: "建立自学项目，查看学习内容进度和下一单元。",
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
      <body>{children}</body>
    </html>
  );
}
