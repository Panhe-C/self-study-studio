export default function LegacyLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <>
    <script defer src="https://cdn.apple-cloudkit.com/ck/2/CloudKit.js" />
    {children}
  </>;
}
