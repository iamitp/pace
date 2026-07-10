#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptPath = fileURLToPath(import.meta.url);
const rootDir = path.resolve(path.dirname(scriptPath), "..");

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: rootDir,
    env: process.env,
    encoding: "utf8",
    ...options
  });
  return {
    status: result.status,
    stdout: result.stdout || "",
    stderr: result.stderr || "",
    output: `${result.stdout || ""}${result.stderr || ""}`
  };
}

function sleep(seconds) {
  spawnSync("/bin/sleep", [String(seconds)], { cwd: rootDir });
}

function runBuildCheck() {
  let last = null;
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    last = run("node", ["./scripts/check-app-store-builds.mjs"]);
    if (last.output.includes("app_store_build_check=pass")) {
      return last;
    }
    if (attempt < 3) {
      sleep(10);
    }
  }
  return last;
}

function parseKeyOutput(output) {
  const values = {};
  const repeated = {};
  const lines = output.split(/\r?\n/).filter(Boolean);
  for (const line of lines) {
    const match = line.match(/^([A-Za-z0-9_]+)=(.*)$/);
    if (!match) continue;
    const [, key, value] = match;
    if (values[key] === undefined) {
      values[key] = value;
    } else {
      repeated[key] ||= [values[key]];
      repeated[key].push(value);
    }
  }
  return { values, repeated, lines };
}

function keyValues(parsed, key) {
  if (parsed.repeated[key]) return parsed.repeated[key];
  if (parsed.values[key] !== undefined) return [parsed.values[key]];
  return [];
}

function exists(relativePath) {
  return fs.existsSync(path.join(rootDir, relativePath));
}

function executable(relativePath) {
  try {
    const stats = fs.statSync(path.join(rootDir, relativePath));
    return Boolean(stats.mode & 0o111);
  } catch {
    return false;
  }
}

function add(rows, id, requirement, status, evidence) {
  rows.push({ id, requirement, status, evidence });
}

const readiness = run("./scripts/verify-app-store-readiness.sh", []);
const readinessParsed = parseKeyOutput(readiness.output);
const r = readinessParsed.values;
const readinessBlockers = keyValues(readinessParsed, "blocker");
const hasApiCredentials = Boolean(process.env.PACE_ASC_API_KEY && process.env.PACE_ASC_API_ISSUER);
const buildCheck = hasApiCredentials ? runBuildCheck() : null;
const gitStatus = run("/usr/bin/git", ["status", "--short"]);

const rows = [];

add(
  rows,
  "source_tree",
  "restore and commit the source tree",
  gitStatus.stdout.trim() === "" ? "pass" : "unverified",
  gitStatus.stdout.trim() === "" ? "git status is clean" : `git status has changes: ${JSON.stringify(gitStatus.stdout.trim())}`
);

add(
  rows,
  "packaging_lane",
  "add the App Store packaging lane",
  executable("scripts/package-app-store.sh") && executable("scripts/verify-app-store-readiness.sh") && executable("scripts/submit-app-store.sh") ? "pass" : "blocked",
  "package, readiness, and submission scripts are present and executable"
);

add(
  rows,
  "developer_tooling",
  "install or select full Xcode or Transporter tooling",
  r.developer_tooling === "full_xcode" || r.developer_tooling === "local_transporter" ? "pass" : "blocked",
  `developer_tooling=${r.developer_tooling || "missing"} upload_tool=${r.upload_tool || "missing"} version=${r.upload_tool_version || "unknown"}`
);

add(
  rows,
  "sandbox_entitlements",
  "add sandbox entitlements",
  r.entitlements_file === "present" && r.sandbox_entitlement === "present" ? "pass" : "blocked",
  `entitlements_file=${r.entitlements_file || "missing"} sandbox_entitlement=${r.sandbox_entitlement || "missing"}`
);

add(
  rows,
  "app_store_feature_gating",
  "add App Store-safe feature gating",
  r.distribution === "app-store" && readiness.output.includes("distribution=app-store") ? "pass" : "blocked",
  `distribution=${r.distribution || "missing"}`
);

add(
  rows,
  "privacy_manifest",
  "embed App Store privacy manifest",
  r.privacy_manifest === "present" && r.privacy_tracking === "false" ? "pass" : "blocked",
  `privacy_manifest=${r.privacy_manifest || "missing"} privacy_tracking=${r.privacy_tracking || "missing"}`
);

add(
  rows,
  "listing_assets",
  "prepare App Store listing assets",
  r.app_store_assets === "pass" && Number(r.mac_screenshot_count || 0) >= 1 ? "pass" : "blocked",
  `app_store_assets=${r.app_store_assets || "missing"} mac_screenshot_count=${r.mac_screenshot_count || 0}`
);

add(
  rows,
  "apple_distribution_identity",
  "sign with Apple distribution identities",
  r.app_signing_identity === "present" && r.installer_certificate === "present" ? "pass" : "blocked",
  `app_signing_identity=${r.app_signing_identity || "missing"} installer_certificate=${r.installer_certificate || "missing"}`
);

add(
  rows,
  "provisioning_profile",
  "provision with matching Mac App Store profile",
  r.embedded_provisioning_profile === "present" || Number(r.matching_provisioning_profiles || 0) > 0 ? "pass" : "blocked",
  `matching_profiles=${r.matching_provisioning_profiles || 0} embedded_profile=${r.embedded_provisioning_profile || "missing"}`
);

add(
  rows,
  "archive_package",
  "produce an archive or package",
  r.product_package === "present" && exists("release/app-store/PaceDesk-AppStore.pkg") ? "pass" : "blocked",
  `product_package=${r.product_package || "missing"} pkg=release/app-store/PaceDesk-AppStore.pkg`
);

add(
  rows,
  "validation",
  "validate the App Store package",
  r.app_store_readiness === "pass" ? "pass" : "blocked",
  `app_store_readiness=${r.app_store_readiness || "blocked"} blockers=${readinessBlockers.join(" | ") || "none"}`
);

add(
  rows,
  "upload",
  "upload to App Store Connect where possible",
  buildCheck?.output.includes("app_store_build_check=pass") ? "pass" : "blocked",
  buildCheck?.output.trim().split(/\r?\n/).find((line) => line.startsWith("app_store_build_check=")) || (hasApiCredentials ? `build_check_exit=${buildCheck?.status}` : "API credentials are missing")
);

add(
  rows,
  "submission_state",
  "verify App Store Connect submission state",
  buildCheck?.output.includes("app_store_build_check=pass") ? "pass" : "blocked",
  buildCheck?.output.trim().split(/\r?\n/).find((line) => line.startsWith("build id=")) || buildCheck?.output.trim().split(/\r?\n/).find((line) => line.startsWith("app_store_build_check=")) || (hasApiCredentials ? `build_check_exit=${buildCheck?.status}` : "API credentials are missing")
);

add(
  rows,
  "blocker_record",
  "record external blockers precisely",
  readinessBlockers.length === 0 && buildCheck?.output.includes("app_store_build_check=pass")
    ? "pass"
    : exists("release/app-store/blocker-report.json") && readinessBlockers.length
      ? "pass"
      : "unverified",
  readinessBlockers.length === 0 && buildCheck?.output.includes("app_store_build_check=pass")
    ? "no current blocker remains after valid App Store Connect build check"
    : exists("release/app-store/blocker-report.json")
      ? "release/app-store/blocker-report.json exists"
      : "blocker report missing"
);

const counts = rows.reduce(
  (acc, row) => {
    acc[row.status] = (acc[row.status] || 0) + 1;
    return acc;
  },
  {}
);

for (const row of rows) {
  console.log(`objective_item=${row.id} status=${row.status} evidence="${row.evidence.replaceAll('"', "'")}"`);
}

const blocked = counts.blocked || 0;
const unverified = counts.unverified || 0;
const passed = counts.pass || 0;
console.log(`objective_audit=${blocked === 0 && unverified === 0 ? "pass" : "blocked"} passed=${passed} blocked=${blocked} unverified=${unverified}`);

if (blocked > 0 || unverified > 0) {
  process.exit(1);
}
