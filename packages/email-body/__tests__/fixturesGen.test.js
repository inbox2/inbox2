// Freshness guard for the flattened native fixtures bundle.
//
// fixtures/email/fixtures.gen.json is the single file the iOS/Android WebView tests
// embed (they can't read the repo's cases/*.html at runtime). It is generated from
// manifest.json + the case files by bin/gen-email-fixtures. This asserts it is in
// sync — i.e. someone added/edited a fixture but forgot to regenerate. Fix with:
//   bin/gen-email-fixtures
import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import path from 'node:path';

const here = path.dirname(fileURLToPath(import.meta.url));
const genPath = path.resolve(here, '../../../fixtures/email/fixtures.gen.json');
const require = createRequire(import.meta.url);
const generator = require(path.resolve(here, '../../../bin/gen-email-fixtures'));

describe('fixtures.gen.json', () => {
  it('is up to date with manifest.json + cases/ (run bin/gen-email-fixtures)', () => {
    expect(readFileSync(genPath, 'utf8')).toBe(generator.build());
  });
});
