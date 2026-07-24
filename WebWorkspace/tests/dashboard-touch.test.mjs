import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

function atRuleBody(source, atRule) {
  const start = source.indexOf(atRule);
  assert.notEqual(start, -1, `Expected ${atRule}`);

  const openingBrace = source.indexOf("{", start);
  let depth = 0;

  for (let index = openingBrace; index < source.length; index += 1) {
    if (source[index] === "{") depth += 1;
    if (source[index] === "}") depth -= 1;
    if (depth === 0) return source.slice(openingBrace + 1, index);
  }

  assert.fail(`Expected ${atRule} to have a closing brace`);
}

test("keeps every Dashboard button at least 44 pixels on coarse pointers at every viewport", async () => {
  const css = await readFile(
    new URL("../app/globals.css", import.meta.url),
    "utf8",
  );
  const coarsePointerRules = atRuleBody(css, "@media (pointer: coarse)");

  assert.match(
    coarsePointerRules,
    /\.workspace-shell:has\(\.portfolio-dashboard\) button\s*\{[^}]*min-width:\s*44px;[^}]*min-height:\s*44px/,
  );
});

test("retains the Dashboard narrow-screen layout rules", async () => {
  const css = await readFile(
    new URL("../app/globals.css", import.meta.url),
    "utf8",
  );
  const narrowRules = atRuleBody(css, "@media (max-width: 540px)");

  assert.match(narrowRules, /\.portfolio-pulse\s*\{[^}]*grid-template-columns:\s*1fr/);
  assert.match(narrowRules, /\.portfolio-period\s*\{[^}]*width:\s*100%/);
  assert.match(
    narrowRules,
    /\.portfolio-project-card > footer\s*\{[^}]*flex-direction:\s*column/,
  );
});
