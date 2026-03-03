module.exports = {
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