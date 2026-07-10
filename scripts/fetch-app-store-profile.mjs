#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const bundleIdentifier = process.env.PACE_BUNDLE_ID || "com.amitpatnaik.pace";
const keyId = process.env.PACE_ASC_API_KEY;
const issuerId = process.env.PACE_ASC_API_ISSUER;
const profileName = process.env.PACE_ASC_PROFILE_NAME || "Pace Mac App Store";
const outputPath = process.env.PACE_PROFILE_OUTPUT || path.resolve("release/app-store/Pace-AppStore.provisionprofile");
const createBundleId = process.env.PACE_ASC_CREATE_BUNDLE_ID === "1";
const createProfile = process.env.PACE_ASC_CREATE_PROFILE === "1";
const certificateId = process.env.PACE_ASC_CERTIFICATE_ID;

if (!keyId || !issuerId) {
  console.error("profile_fetch=blocked reason=missing_api_credentials required_env=PACE_ASC_API_KEY,PACE_ASC_API_ISSUER");
  process.exit(60);
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
  console.error(`profile_fetch=blocked reason=missing_api_private_key key_id=${keyId}`);
  process.exit(61);
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

async function api(pathname, options = {}) {
  const response = await fetch(`https://api.appstoreconnect.apple.com${pathname}`, {
    ...options,
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      ...(options.headers || {})
    }
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

async function findBundleId() {
  const query = new URLSearchParams({ "filter[identifier]": bundleIdentifier, limit: "10" });
  const response = await api(`/v1/bundleIds?${query}`);
  return response.data?.[0] || null;
}

async function createBundleIdResource() {
  return (await api("/v1/bundleIds", {
    method: "POST",
    body: JSON.stringify({
      data: {
        type: "bundleIds",
        attributes: {
          identifier: bundleIdentifier,
          name: "Pace",
          platform: "MAC_OS"
        }
      }
    })
  })).data;
}

async function findProfiles(bundleId) {
  const query = new URLSearchParams({
    "filter[bundleId]": bundleId,
    "filter[profileType]": "MAC_APP_STORE",
    limit: "20",
    sort: "-createdDate"
  });
  const response = await api(`/v1/profiles?${query}`);
  return response.data || [];
}

async function listCertificates() {
  const response = await api("/v1/certificates?limit=200");
  return response.data || [];
}

async function createProfileResource(bundleId) {
  if (!certificateId) {
    const certificates = await listCertificates();
    console.error("profile_fetch=blocked reason=missing_certificate_id required_env=PACE_ASC_CERTIFICATE_ID");
    for (const certificate of certificates) {
      const attributes = certificate.attributes || {};
      console.error(`candidate_certificate id=${certificate.id} type=${attributes.certificateType || "unknown"} name="${attributes.displayName || attributes.name || "unknown"}" expires="${attributes.expirationDate || "unknown"}"`);
    }
    process.exit(62);
  }

  return (await api("/v1/profiles", {
    method: "POST",
    body: JSON.stringify({
      data: {
        type: "profiles",
        attributes: {
          name: profileName,
          profileType: "MAC_APP_STORE"
        },
        relationships: {
          bundleId: {
            data: { type: "bundleIds", id: bundleId }
          },
          certificates: {
            data: [{ type: "certificates", id: certificateId }]
          }
        }
      }
    })
  })).data;
}

function writeProfile(profile) {
  const content = profile.attributes?.profileContent;
  const uuid = profile.attributes?.uuid || profile.id;
  if (!content) {
    console.error(`profile_fetch=blocked reason=missing_profile_content profile_id=${profile.id}`);
    process.exit(63);
  }
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, Buffer.from(content, "base64"));
  console.log(`profile_fetch=pass profile_id=${profile.id} uuid=${uuid} path="${outputPath}"`);
}

let bundle = await findBundleId();
if (!bundle && createBundleId) {
  bundle = await createBundleIdResource();
  console.log(`bundle_id_create=pass id=${bundle.id} identifier=${bundleIdentifier}`);
}

if (!bundle) {
  console.error(`profile_fetch=blocked reason=bundle_id_not_found bundle_id=${bundleIdentifier} hint=run_with_PACE_ASC_CREATE_BUNDLE_ID=1_to_create`);
  process.exit(64);
}

let profiles = await findProfiles(bundle.id);
if (profiles.length === 0 && createProfile) {
  const profile = await createProfileResource(bundle.id);
  profiles = [profile];
  console.log(`profile_create=pass id=${profile.id} name="${profile.attributes?.name || profileName}"`);
}

if (profiles.length === 0) {
  console.error(`profile_fetch=blocked reason=profile_not_found bundle_id=${bundleIdentifier} hint=run_with_PACE_ASC_CREATE_PROFILE=1_and_PACE_ASC_CERTIFICATE_ID_to_create`);
  process.exit(65);
}

writeProfile(profiles[0]);
