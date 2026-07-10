#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const appId = process.env.PACE_ASC_APP_ID || "6783367958";
const bundleIdentifier = process.env.PACE_BUNDLE_ID || "com.amitpatnaik.pace";
const keyId = process.env.PACE_ASC_API_KEY;
const issuerId = process.env.PACE_ASC_API_ISSUER;

const requiredLocalizationFields = ["description", "keywords", "supportUrl"];
const optionalLocalizationFields = ["marketingUrl", "promotionalText", "whatsNew"];

if (!keyId || !issuerId) {
  console.error("app_store_version_readback=blocked reason=missing_api_credentials required_env=PACE_ASC_API_KEY,PACE_ASC_API_ISSUER");
  process.exit(90);
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
  console.error(`app_store_version_readback=blocked reason=missing_api_private_key key_id=${keyId}`);
  process.exit(91);
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
const apiBase = "https://api.appstoreconnect.apple.com";

function apiUrl(pathname) {
  if (pathname.startsWith("http://") || pathname.startsWith("https://")) {
    return pathname;
  }
  return `${apiBase}${pathname}`;
}

function safePath(pathname) {
  const url = new URL(apiUrl(pathname));
  return `${url.pathname}${url.search}`;
}

function errorDetail(body, response) {
  const error = body?.errors?.[0];
  if (error) {
    return [error.status, error.code, error.title, error.detail].filter(Boolean).join(": ");
  }
  return body?.raw || response.statusText;
}

async function api(pathname, options = {}) {
  const response = await fetch(apiUrl(pathname), {
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
    if (options.allow404 && response.status === 404) {
      return null;
    }
    throw new Error(`path=${safePath(pathname)} status=${response.status} detail=${errorDetail(body, response)}`);
  }
  return body || {};
}

async function apiAll(pathname, options = {}) {
  const rows = [];
  let next = pathname;
  while (next) {
    const body = await api(next, options);
    if (!body) {
      return rows;
    }
    rows.push(...(body.data || []));
    next = body.links?.next || null;
  }
  return rows;
}

async function apiOne(pathname) {
  const body = await api(pathname, { allow404: true });
  return body?.data || null;
}

function valueToken(value) {
  if (value === undefined || value === null || value === "") {
    return "none";
  }
  if (Array.isArray(value)) {
    return value.length ? value.join(",") : "none";
  }
  if (typeof value === "boolean") {
    return value ? "true" : "false";
  }
  const text = String(value);
  if (/^[A-Za-z0-9._:/@+=,-]+$/.test(text)) {
    return text;
  }
  return JSON.stringify(text);
}

function printLine(label, fields) {
  const parts = [label];
  for (const [key, value] of Object.entries(fields)) {
    parts.push(`${key}=${valueToken(value)}`);
  }
  console.log(parts.join(" "));
}

function hasValue(value) {
  return typeof value === "string" ? value.trim().length > 0 : value !== undefined && value !== null;
}

function summarizeLocalization(localization) {
  const attributes = localization.attributes || {};
  const missingRequired = requiredLocalizationFields.filter((field) => !hasValue(attributes[field]));
  const missingOptional = optionalLocalizationFields.filter((field) => !hasValue(attributes[field]));
  return {
    locale: attributes.locale || "unknown",
    textCompleteness: missingRequired.length === 0 ? "complete" : "missing_required_fields",
    missingRequired,
    missingOptional
  };
}

async function fetchVersionState(version) {
  const versionId = version.id;
  const [build, submission, localizations] = await Promise.all([
    apiOne(`/v1/appStoreVersions/${versionId}/build`),
    apiOne(`/v1/appStoreVersions/${versionId}/appStoreVersionSubmission`),
    apiAll(`/v1/appStoreVersions/${versionId}/appStoreVersionLocalizations?limit=200`, { allow404: true })
  ]);

  const localizationStates = [];
  for (const localization of localizations) {
    const screenshotSets = await apiAll(`/v1/appStoreVersionLocalizations/${localization.id}/appScreenshotSets?limit=200`, { allow404: true });
    const screenshotStates = [];
    for (const screenshotSet of screenshotSets) {
      const screenshots = await apiAll(`/v1/appScreenshotSets/${screenshotSet.id}/appScreenshots?limit=200`, { allow404: true });
      screenshotStates.push({ screenshotSet, screenshots });
    }
    localizationStates.push({ localization, screenshotStates });
  }

  return { version, build, submission, localizationStates };
}

try {
  const appQuery = new URLSearchParams({ "filter[bundleId]": bundleIdentifier, limit: "10" });
  const apps = await api(`/v1/apps?${appQuery}`);
  const app = (apps.data || []).find((candidate) => candidate.id === appId) || apps.data?.[0];

  if (!app) {
    console.error(`app_store_version_readback=blocked reason=app_record_not_found app_id=${appId} bundle_id=${bundleIdentifier}`);
    process.exit(92);
  }

  if (app.id !== appId) {
    console.error(`app_store_version_readback=blocked reason=app_id_bundle_mismatch expected_app_id=${appId} actual_app_id=${app.id} bundle_id=${bundleIdentifier}`);
    process.exit(93);
  }

  const appAttributes = app.attributes || {};
  printLine("app_store_app", {
    app_id: app.id,
    bundle_id: appAttributes.bundleId || bundleIdentifier,
    name: appAttributes.name,
    sku: appAttributes.sku,
    primary_locale: appAttributes.primaryLocale
  });

  const versions = await apiAll(`/v1/apps/${appId}/appStoreVersions?limit=200`);
  printLine("appStoreVersions", {
    app_id: appId,
    bundle_id: bundleIdentifier,
    count: versions.length
  });

  if (versions.length === 0) {
    console.error(`app_store_version_readback=blocked reason=no_app_store_versions app_id=${appId} bundle_id=${bundleIdentifier}`);
    process.exit(94);
  }

  const states = await Promise.all(versions.map((version) => fetchVersionState(version)));
  let attachedBuildCount = 0;
  let completeLocalizationCount = 0;
  let screenshotSetCount = 0;
  let screenshotCount = 0;
  let submissionCount = 0;

  for (const state of states) {
    const attributes = state.version.attributes || {};
    printLine("appStoreVersion", {
      version_id: state.version.id,
      platform: attributes.platform,
      version: attributes.versionString,
      app_store_state: attributes.appStoreState,
      release_type: attributes.releaseType,
      earliest_release_date: attributes.earliestReleaseDate,
      created_date: attributes.createdDate,
      downloadable: attributes.downloadable
    });

    if (state.build) {
      attachedBuildCount += 1;
      const buildAttributes = state.build.attributes || {};
      printLine("attached_build", {
        version_id: state.version.id,
        status: "present",
        build_id: state.build.id,
        build_version: buildAttributes.version,
        processing_state: buildAttributes.processingState,
        uploaded_date: buildAttributes.uploadedDate,
        expired: buildAttributes.expired,
        min_os_version: buildAttributes.minOsVersion,
        computed_min_mac_os_version: buildAttributes.computedMinMacOsVersion
      });
    } else {
      printLine("attached_build", {
        version_id: state.version.id,
        status: "missing"
      });
    }

    if (state.submission) {
      submissionCount += 1;
      const submissionAttributes = state.submission.attributes || {};
      printLine("submission_relationship", {
        version_id: state.version.id,
        status: "present",
        submission_id: state.submission.id,
        submission_type: state.submission.type,
        state: submissionAttributes.state || "relationship_present"
      });
    } else {
      printLine("submission_relationship", {
        version_id: state.version.id,
        status: "missing"
      });
    }

    if (state.localizationStates.length === 0) {
      printLine("localization", {
        version_id: state.version.id,
        status: "missing",
        text_completeness: "missing_required_fields",
        missing_required: requiredLocalizationFields
      });
      printLine("screenshot_set", {
        version_id: state.version.id,
        status: "missing",
        count: 0
      });
      continue;
    }

    for (const localizationState of state.localizationStates) {
      const localizationSummary = summarizeLocalization(localizationState.localization);
      const localScreenshotSetCount = localizationState.screenshotStates.length;
      const localScreenshotCount = localizationState.screenshotStates.reduce((sum, screenshotState) => sum + screenshotState.screenshots.length, 0);
      if (localizationSummary.textCompleteness === "complete") {
        completeLocalizationCount += 1;
      }
      screenshotSetCount += localScreenshotSetCount;
      screenshotCount += localScreenshotCount;

      printLine("localization", {
        version_id: state.version.id,
        localization_id: localizationState.localization.id,
        locale: localizationSummary.locale,
        text_completeness: localizationSummary.textCompleteness,
        missing_required: localizationSummary.missingRequired,
        missing_optional: localizationSummary.missingOptional,
        screenshot_sets: localScreenshotSetCount,
        screenshots: localScreenshotCount
      });

      if (localizationState.screenshotStates.length === 0) {
        printLine("screenshot_set", {
          version_id: state.version.id,
          localization_id: localizationState.localization.id,
          locale: localizationSummary.locale,
          status: "missing",
          count: 0
        });
        continue;
      }

      for (const screenshotState of localizationState.screenshotStates) {
        const screenshotSetAttributes = screenshotState.screenshotSet.attributes || {};
        printLine("screenshot_set", {
          version_id: state.version.id,
          localization_id: localizationState.localization.id,
          locale: localizationSummary.locale,
          set_id: screenshotState.screenshotSet.id,
          display_type: screenshotSetAttributes.screenshotDisplayType,
          screenshots: screenshotState.screenshots.length
        });
      }
    }
  }

  printLine("app_store_version_readback", {
    status: "pass",
    app_id: appId,
    bundle_id: bundleIdentifier,
    versions: versions.length,
    versions_with_attached_build: attachedBuildCount,
    complete_localizations: completeLocalizationCount,
    screenshot_sets: screenshotSetCount,
    screenshots: screenshotCount,
    submission_relationships: submissionCount
  });
} catch (error) {
  console.error(`app_store_version_readback=blocked reason=app_store_connect_api_error message=${valueToken(error.message.replaceAll('"', "'"))}`);
  process.exit(95);
}
