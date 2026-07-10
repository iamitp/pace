#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const rootDir = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const manifestPath = path.resolve(rootDir, "release/app-store/manifest.json");
const manifest = fs.existsSync(manifestPath) ? JSON.parse(fs.readFileSync(manifestPath, "utf8")) : {};

const keyId = process.env.PACE_ASC_API_KEY;
const issuerId = process.env.PACE_ASC_API_ISSUER;
const appId = process.env.PACE_ASC_APP_ID || "6783367958";
const marketingVersion = process.env.PACE_VERSION || manifest.version || "0.1.1";
const buildVersion = process.env.PACE_BUILD_VERSION || manifest.build_version || marketingVersion;
const pkgPath = path.resolve(process.env.PACE_APPSTORE_PKG || manifest.pkg || "release/app-store/PaceDesk-AppStore.pkg");

if (!keyId || !issuerId) {
  console.error("app_store_direct_upload=blocked reason=missing_api_credentials required_env=PACE_ASC_API_KEY,PACE_ASC_API_ISSUER");
  process.exit(80);
}

if (!fs.existsSync(pkgPath)) {
  console.error(`app_store_direct_upload=blocked reason=missing_pkg path="${pkgPath}"`);
  process.exit(81);
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
    path.resolve(rootDir, "private_keys", `AuthKey_${keyId}.p8`),
    path.join(os.homedir(), "private_keys", `AuthKey_${keyId}.p8`),
    path.join(os.homedir(), ".private_keys", `AuthKey_${keyId}.p8`),
    path.join(os.homedir(), ".appstoreconnect", "private_keys", `AuthKey_${keyId}.p8`),
    path.resolve(rootDir, "private_keys", `ApiKey_${keyId}.p8`),
    path.join(os.homedir(), "private_keys", `ApiKey_${keyId}.p8`),
    path.join(os.homedir(), ".private_keys", `ApiKey_${keyId}.p8`),
    path.join(os.homedir(), ".appstoreconnect", "private_keys", `ApiKey_${keyId}.p8`)
  ].filter(Boolean);

  return candidates.find((candidate) => fs.existsSync(candidate));
}

const keyPath = findKeyFile();
if (!keyPath) {
  console.error(`app_store_direct_upload=blocked reason=missing_api_private_key key_id=${keyId}`);
  process.exit(82);
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

async function api(label, method, pathname, body, timeout = 60000) {
  const response = await fetch(`https://api.appstoreconnect.apple.com${pathname}`, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: "application/json",
      ...(body ? { "Content-Type": "application/json" } : {})
    },
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(timeout)
  });
  const text = await response.text();
  let payload = null;
  if (text) {
    try {
      payload = JSON.parse(text);
    } catch {
      payload = { raw: text };
    }
  }
  if (!response.ok) {
    const error = payload?.errors?.[0];
    const detail = error?.detail || error?.title || response.statusText;
    throw new Error(`${label} status=${response.status} code=${error?.code || "unknown"} detail=${detail}`);
  }
  console.log(`${label}=ok status=${response.status}`);
  return payload;
}

function checksumPayload(uploadFileId, fileHash, compositeHash) {
  return {
    data: {
      type: "buildUploadFiles",
      id: uploadFileId,
      attributes: {
        uploaded: true,
        sourceFileChecksums: {
          file: { algorithm: "MD5", hash: fileHash },
          composite: { algorithm: "MD5", hash: compositeHash }
        }
      }
    }
  };
}

async function commitUploadFile(uploadFileId, fileHash, compositeHash) {
  try {
    return await api(
      "commit_asset_file",
      "PATCH",
      `/v1/buildUploadFiles/${uploadFileId}`,
      checksumPayload(uploadFileId, fileHash, compositeHash)
    );
  } catch (error) {
    const foundComposite = error.message.match(/found ([a-f0-9]{32}-1-\d+)/i)?.[1];
    if (!foundComposite || process.env.PACE_DIRECT_UPLOAD_ACCEPT_FOUND_CHECKSUM === "0") {
      throw error;
    }
    const foundFile = foundComposite.split("-")[0];
    console.log("commit_asset_file=retrying_with_received_checksum");
    return await api(
      "commit_asset_file_retry",
      "PATCH",
      `/v1/buildUploadFiles/${uploadFileId}`,
      checksumPayload(uploadFileId, foundFile, foundComposite),
      Number(process.env.PACE_DIRECT_UPLOAD_COMMIT_TIMEOUT_MS || 180000)
    );
  }
}

function uploadPart(partPath, operation, label) {
  const headerPath = path.join(tempDir, `${label}.headers`);
  const args = [
    "--silent",
    "--show-error",
    "--fail-with-body",
    "--http1.1",
    "--dump-header",
    headerPath,
    "--request",
    operation.method || "PUT",
    "--header",
    "Expect:"
  ];
  for (const header of operation.requestHeaders || []) {
    args.push("--header", `${header.name}: ${header.value}`);
  }
  args.push("--data-binary", `@${partPath}`, "--write-out", "\n%{http_code} %{size_upload}", operation.url);

  const output = execFileSync("/usr/bin/curl", args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    maxBuffer: 1024 * 1024
  });
  const result = output.trim().split("\n").pop() || "";
  const [status, uploadedBytes] = result.split(/\s+/);
  const headers = fs.existsSync(headerPath) ? fs.readFileSync(headerPath, "utf8") : "";
  const entityTag = headers
    .split(/\r?\n/)
    .map((line) => line.match(/^etag:\s*"?([^"\r\n]+)"?/i)?.[1])
    .find(Boolean);
  console.log(`${label}=uploaded status=${status} bytes=${uploadedBytes || "unknown"}${entityTag ? " etag=present" : ""}`);
  return entityTag;
}

const packageBytes = fs.readFileSync(pkgPath);
const packageSize = packageBytes.length;
const fileMd5 = crypto.createHash("md5").update(packageBytes).digest("hex");
const compositeMd5 = `${fileMd5}-1-${packageSize}`;
const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "pace-direct-upload-"));
let buildUploadId;

console.log(`app_store_direct_upload=starting app_id=${appId} marketing_version=${marketingVersion} build_version=${buildVersion} pkg="${pkgPath}" bytes=${packageSize}`);

try {
  const buildUpload = await api("create_build_upload", "POST", "/v1/buildUploads", {
    data: {
      type: "buildUploads",
      attributes: {
        cfBundleShortVersionString: marketingVersion,
        cfBundleVersion: buildVersion,
        platform: "MAC_OS"
      },
      relationships: {
        app: { data: { type: "apps", id: appId } }
      }
    }
  });
  buildUploadId = buildUpload.data.id;
  console.log(`build_upload_id=${buildUploadId}`);

  const uploadFile = await api("create_asset_file", "POST", "/v1/buildUploadFiles", {
    data: {
      type: "buildUploadFiles",
      attributes: {
        assetType: "ASSET",
        fileName: path.basename(pkgPath),
        fileSize: packageSize,
        uti: "com.apple.pkg"
      },
      relationships: {
        buildUpload: { data: { type: "buildUploads", id: buildUploadId } }
      }
    }
  });
  const uploadFileId = uploadFile.data.id;
  const operations = uploadFile.data.attributes?.uploadOperations || [];
  console.log(`asset_file_id=${uploadFileId} upload_operations=${operations.length}`);
  if (operations.length === 0) {
    throw new Error("No upload operations returned for package asset");
  }

  const entityTags = [];
  for (let index = 0; index < operations.length; index += 1) {
    const operation = operations[index];
    const offset = Number(operation.offset ?? 0);
    const length = Number(operation.length ?? packageSize);
    const headerNames = (operation.requestHeaders || []).map((header) => header.name).join(",");
    console.log(`asset_part_${index + 1}=reserved offset=${offset} length=${length} headers=${headerNames || "none"}`);
    const partPath = offset === 0 && length === packageSize ? pkgPath : path.join(tempDir, `part-${index + 1}`);
    if (partPath !== pkgPath) {
      fs.writeFileSync(partPath, packageBytes.subarray(offset, offset + length));
    }
    const entityTag = uploadPart(partPath, operation, `asset_part_${index + 1}`);
    if (entityTag) {
      entityTags.push(entityTag);
    }
  }
  const uploadedFileMd5 = entityTags.length === 1 ? entityTags[0] : fileMd5;
  const uploadedCompositeMd5 = entityTags.length === 1 ? `${entityTags[0]}-1-${packageSize}` : compositeMd5;

  const committed = await commitUploadFile(uploadFileId, uploadedFileMd5, uploadedCompositeMd5);

  console.log(`commit_asset_state=${committed.data.attributes?.assetDeliveryState?.state || "unknown"}`);
  console.log(`app_store_direct_upload=submitted build_upload_id=${buildUploadId} version=${buildVersion}`);
} catch (error) {
  console.error(`app_store_direct_upload=blocked reason=app_store_connect_api_error message="${error.message.replaceAll('"', "'")}"`);
  if (buildUploadId && process.env.PACE_DIRECT_UPLOAD_SKIP_CLEANUP !== "1") {
    try {
      const response = await fetch(`https://api.appstoreconnect.apple.com/v1/buildUploads/${buildUploadId}`, {
        method: "DELETE",
        headers: { Authorization: `Bearer ${token}` },
        signal: AbortSignal.timeout(30000)
      });
      console.error(`cleanup_build_upload status=${response.status}`);
    } catch (cleanupError) {
      console.error(`cleanup_build_upload=blocked message="${cleanupError.message.replaceAll('"', "'")}"`);
    }
  }
  process.exit(85);
} finally {
  fs.rmSync(tempDir, { recursive: true, force: true });
}
