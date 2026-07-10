#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const bundleIdentifier = process.env.PACE_BUNDLE_ID || "com.amitpatnaik.pace";
const version = process.env.PACE_VERSION || "0.1.1";
const buildVersionToFind = process.env.PACE_BUILD_VERSION || version;
const keyId = process.env.PACE_ASC_API_KEY;
const issuerId = process.env.PACE_ASC_API_ISSUER;

if (!keyId || !issuerId) {
  console.error("app_store_build_check=blocked reason=missing_api_credentials required_env=PACE_ASC_API_KEY,PACE_ASC_API_ISSUER");
  process.exit(80);
}

function base64url(input) {
  return Buffer.from(input)
    .toString("base64")
    .replace(/=/g, "")
    .replace(/\+/g, "-")
    .replace(/\//g, "_");
}

function findKeyFile() {
  const explicit = process.env.PACE_ASC_API_KEY_PATH;
  const candidates = [
    explicit,
    path.resolve("private_keys", `AuthKey_${keyId}.p8`),
    path.join(os.homedir(), "private_keys", `AuthKey_${keyId}.p8`),
    path.join(os.homedir(), ".private_keys", `AuthKey_${keyId}.p8`),
    path.join(os.homedir(), ".appstoreconnect", "private_keys", `AuthKey_${keyId}.p8`),
    path.resolve("private_keys", `ApiKey_${keyId}.p8`),
    path.join(os.homedir(), "private_keys", `ApiKey_${keyId}.p8`),
    path.join(os.homedir(), ".private_keys", `ApiKey_${keyId}.p8`),
    path.join(os.homedir(), ".appstoreconnect", "private_keys", `ApiKey_${keyId}.p8`)
  ].filter(Boolean);

  return candidates.find((candidate) => fs.existsSync(candidate));
}

const keyPath = findKeyFile();
if (!keyPath) {
  console.error(`app_store_build_check=blocked reason=missing_api_private_key key_id=${keyId}`);
  process.exit(81);
}

function makeJwt() {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "ES256", kid: keyId, typ: "JWT" };
  const payload = {
    iss: issuerId,
    iat: now,
    exp: now + 20 * 60,
    aud: "appstoreconnect-v1"
  };
  const signingInput = `${base64url(JSON.stringify(header))}.${base64url(JSON.stringify(payload))}`;
  const signature = crypto.sign("sha256", Buffer.from(signingInput), {
    key: fs.readFileSync(keyPath, "utf8"),
    dsaEncoding: "ieee-p1363"
  });
  return `${signingInput}.${base64url(signature)}`;
}

const token = makeJwt();

async function api(pathname) {
  const response = await fetch(`https://api.appstoreconnect.apple.com${pathname}`, {
    headers: { Authorization: `Bearer ${token}` }
  });
  const text = await response.text();
  let body = null;
  if (text) {
    try {
      body = JSON.parse(text);
    } catch {
      body = { raw: text };
    }
  }
  if (!response.ok) {
    const detail = body?.errors?.[0]?.detail || body?.errors?.[0]?.title || body?.raw || response.statusText;
    throw new Error(`status=${response.status} detail=${detail}`);
  }
  return body;
}

try {
  const appQuery = new URLSearchParams({ "filter[bundleId]": bundleIdentifier, limit: "10" });
  const apps = await api(`/v1/apps?${appQuery}`);
  const app = apps.data?.[0];
  if (!app) {
    console.error(`app_store_build_check=blocked reason=app_record_not_found bundle_id=${bundleIdentifier}`);
    process.exit(82);
  }

  const buildQuery = new URLSearchParams({
    "filter[app]": app.id,
    limit: "10",
    sort: "-uploadedDate"
  });
  const builds = await api(`/v1/builds?${buildQuery}`);
  const rows = builds.data || [];

  if (rows.length === 0) {
    console.error(`app_store_build_check=blocked reason=no_builds_found app_id=${app.id} bundle_id=${bundleIdentifier}`);
    process.exit(83);
  }

  let matched = false;
  for (const build of rows) {
    const attributes = build.attributes || {};
    const buildVersion = attributes.version || "unknown";
    const processingState = attributes.processingState || "unknown";
    const uploadedDate = attributes.uploadedDate || "unknown";
    console.log(`build id=${build.id} version=${buildVersion} processing_state=${processingState} uploaded=${uploadedDate}`);
    if (buildVersion === buildVersionToFind) {
      matched = true;
      console.log(`app_store_build_check=pass build_id=${build.id} version=${buildVersion} marketing_version=${version} processing_state=${processingState}`);
      break;
    }
  }

  if (!matched) {
    console.error(`app_store_build_check=blocked reason=version_not_found version=${buildVersionToFind} marketing_version=${version}`);
    process.exit(84);
  }
} catch (error) {
  console.error(`app_store_build_check=blocked reason=app_store_connect_api_error message="${error.message.replaceAll('"', "'")}"`);
  process.exit(85);
}
