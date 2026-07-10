#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptPath = fileURLToPath(import.meta.url);
const rootDir = path.resolve(path.dirname(scriptPath), "..");
const outputPath = process.env.PACE_BLOCKER_REPORT_PATH || path.join(rootDir, "release/app-store/blocker-report.json");
const readinessScript = path.join(rootDir, "scripts/verify-app-store-readiness.sh");

const result = spawnSync(readinessScript, {
  cwd: rootDir,
  env: process.env,
  encoding: "utf8"
});

const output = [result.stdout, result.stderr].filter(Boolean).join("");
const lines = output.split(/\r?\n/).filter(Boolean);
const values = {};
const blockers = [];
const warnings = [];

for (const line of lines) {
  if (line.startsWith("blocker=")) {
    blockers.push(line.slice("blocker=".length));
    continue;
  }
  if (line.startsWith("warning=")) {
    warnings.push(line.slice("warning=".length));
    continue;
  }
  const match = line.match(/^([A-Za-z0-9_]+)=(.*)$/);
  if (match) {
    values[match[1]] = match[2];
  }
}

const report = {
  generated_at: new Date().toISOString(),
  app: "PaceDesk",
  bundle_id: "com.amitpatnaik.pace",
  readiness: values.app_store_readiness || (result.status === 0 ? "pass" : "blocked"),
  exit_status: result.status,
  blockers,
  warnings,
  tooling: {
    selected_developer_dir: values.selected_developer_dir || null,
    full_xcode: values.full_xcode || null,
    developer_tooling: values.developer_tooling || null,
    upload_tool: values.upload_tool || null,
    upload_tool_version: values.upload_tool_version || null,
    upload_credentials: values.upload_credentials || null
  },
  provisioning: {
    profile_dirs: Number(values.provisioning_profile_dirs || 0),
    profiles: Number(values.provisioning_profiles || 0),
    matching_profiles: Number(values.matching_provisioning_profiles || 0),
    embedded_profile: values.embedded_provisioning_profile || null
  },
  package: {
    bundle_id: values.bundle_id || null,
    distribution: values.distribution || null,
    bundle_icon: values.bundle_icon || null,
    privacy_manifest: values.privacy_manifest || null,
    privacy_tracking: values.privacy_tracking || null,
    sandbox_entitlement: values.sandbox_entitlement || null,
    product_package: values.product_package || null
  },
  assets: {
    status: values.app_store_assets || null,
    mac_screenshot_dir: values.mac_screenshot_dir || null,
    mac_screenshot_count: Number(values.mac_screenshot_count || 0)
  },
  raw_readiness_output: lines
};

fs.mkdirSync(path.dirname(outputPath), { recursive: true });
fs.writeFileSync(outputPath, `${JSON.stringify(report, null, 2)}\n`);
console.log(`app_store_blocker_report=pass path="${outputPath}" readiness=${report.readiness} blockers=${blockers.length}`);
