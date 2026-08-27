import fs from 'node:fs';

const [serverPath, manifestPath, releaseTag, arm64File, armv7File] = process.argv.slice(2);
if (!serverPath || !manifestPath || !releaseTag || !arm64File || !armv7File) {
  console.error('Usage: node patch-frontend-android-entry.mjs server.cjs manifest.json release-tag arm64.apk armv7.apk');
  process.exit(64);
}

const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
const version = manifest.versionName;
const build = manifest.versionCode;
if (manifest.schemaVersion !== 1 || manifest.packageName !== 'com.hkmovie67.app'
    || typeof version !== 'string' || !Number.isInteger(build)) {
  throw new Error('Android update manifest does not meet the frontend route contract');
}

const marker = `hkmovie67-android-origin-build${build}-r1`;
const anchor = 'if (FRONTEND_ONLY) {';
const releaseBase = `https://github.com/HKMovie67/HKMovie67/releases/download/${releaseTag}`;
const arm64URL = `${releaseBase}/${arm64File}`;
const armv7URL = `${releaseBase}/${armv7File}`;
const js = JSON.stringify;
const routeBlock = `// ${marker}
app.get("/api/health/android-entry", (_req, res) => {
  res.setHeader("Cache-Control", "no-store, max-age=0");
  res.json({ pagePresent: true, iconPresent: true, deleteAccountPagePresent: true,
    updateManifestPresent: true, version: ${js(version)}, build: ${build},
    pageRoute: "/android.html", updateManifestRoute: "/android-update.json" });
});
app.get("/android-update.json", (_req, res) => {
  res.setHeader("Cache-Control", "no-store, max-age=0");
  res.type("application/json");
  return res.sendFile("/app/dist/android-update.json");
});
app.get(["/android", "/android/"], (_req, res) => {
  res.setHeader("Cache-Control", "no-store, max-age=0");
  return res.redirect(301, "/android.html");
});
app.get([${js(`/downloads/HKMovie67-Android-${version}-build${build}.apk`)}, "/downloads/HKMovie67-Android-latest.apk"], (_req, res) => {
  res.setHeader("Cache-Control", "no-store, max-age=0");
  return res.redirect(302, ${js(arm64URL)});
});
app.get([${js(`/downloads/HKMovie67-Android-${version}-build${build}-armv7.apk`)}, "/downloads/HKMovie67-Android-latest-armv7.apk"], (_req, res) => {
  res.setHeader("Cache-Control", "no-store, max-age=0");
  return res.redirect(302, ${js(armv7URL)});
});
for (const [route, file] of [["/android.html", "android.html"], ["/android-icon.png", "android-icon.png"], ["/delete-account.html", "delete-account.html"]]) {
  app.get(route, (_req, res) => {
    res.setHeader("Cache-Control", route === "/android-icon.png" ? "public, max-age=86400" : "no-store, max-age=0");
    return res.sendFile("/app/dist/" + file);
  });
}
`;

let source = fs.readFileSync(serverPath, 'utf8');
if (!source.includes(marker)) {
  const anchorCount = source.split(anchor).length - 1;
  if (anchorCount !== 1) {
    throw new Error(`frontend proxy anchor: expected one token, found ${anchorCount}`);
  }
  source = source.replace(anchor, `${routeBlock}\n${anchor}`);
  fs.writeFileSync(serverPath, source);
}
for (const required of [marker, js(version), `build: ${build}`, arm64URL, armv7URL, '/app/dist/android-update.json']) {
  if (!source.includes(required)) throw new Error(`patched frontend is missing ${required}`);
}
console.log(`Android Build ${build} routes patched before the frontend gateway proxy.`);
