module.exports = {
  getIncrementLevel: (commits) => {
    const order = ['major', 'minor', 'patch'];
    let level = null;

    for (const commit of commits) {
      // commit.footer only contains the last paragraph's git trailers.
      // If Change-type is separated from Co-Authored-By by a blank line it
      // won't appear there, so also scan the raw body as a fallback.
      const fromFooter = (
        (commit.footer || {})['Change-type'] ||
        (commit.footer || {})['change-type'] ||
        ''
      ).toLowerCase().trim();

      const bodyMatch = /^change-type:\s*(\w+)/im.exec(commit.body || '');
      const explicit = fromFooter || (bodyMatch ? bodyMatch[1].toLowerCase() : '');

      if (order.includes(explicit)) {
        if (level === null || order.indexOf(explicit) < order.indexOf(level)) {
          level = explicit;
        }
        continue;
      }

      // Treat Dependabot dependency bumps as patch when no Change-type present.
      // commit.subject may be the full first line OR just the conventional-commit
      // description part (after "type(scope): "), so check multiple fields plus a
      // JSON-serialised fallback that catches any field name versionist uses.
      const commitJson = JSON.stringify(commit).toLowerCase();
      if (/dependabot/i.test(commitJson) || /build\(deps\)/.test(commitJson)) {
        level = level === 'major' || level === 'minor' ? level : 'patch';
      }
    }

    return level;
  },

  // 'updateVersion' is the correct Versionist hook for a custom function
  updateVersion: (cwd, version, cb) => {
    const fs = require('fs');
    const path = require('path');

    // Update balena.yml
    const balenaYmlPath = path.join(cwd, 'balena.yml');
    let balenaYml = fs.readFileSync(balenaYmlPath, 'utf8');
    balenaYml = balenaYml.replace(/^version:.*$/m, `version: ${version}`);
    fs.writeFileSync(balenaYmlPath, balenaYml);

    // Update VERSION file
    fs.writeFileSync(path.join(cwd, 'VERSION'), version + '\n');

    cb();
  }
};