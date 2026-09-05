// js-yaml legacy-API compatibility shim.
//
// We pin js-yaml to the 5.x line to pick up the fix for the quadratic `!!omap`
// CPU-DoS (CVE-2026-59870 / GHSA-5p4m-2wfm-xmqj), which was never backported to
// the 3.x/4.x lines that our transitive dependency chain would otherwise resolve.
//
// The catch: `balena-settings-client` (pulled in by `balena-sdk`) still calls the
// legacy `safeLoad` / `safeLoadAll` / `safeDump` APIs, which js-yaml 4.0 renamed
// to `load` / `loadAll` / `dump` and removed. Because the override forces a single
// hoisted js-yaml instance, we can restore those aliases on the shared module
// object here. `require('js-yaml')` inside balena-settings-client is lazy (called
// at parse time), so mutating the module before the first settings read is enough.
//
// Import this module for its side effect BEFORE anything that touches balena-sdk.
// eslint-disable-next-line @typescript-eslint/no-var-requires
const jsYaml: Record<string, unknown> = require('js-yaml')

const legacyAliases: ReadonlyArray<readonly [string, string]> = [
  ['safeLoad', 'load'],
  ['safeLoadAll', 'loadAll'],
  ['safeDump', 'dump'],
]

for (const [legacy, current] of legacyAliases) {
  if (typeof jsYaml[legacy] !== 'function' && typeof jsYaml[current] === 'function') {
    jsYaml[legacy] = jsYaml[current]
  }
}
