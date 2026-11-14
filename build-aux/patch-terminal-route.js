#!/usr/bin/env node
"use strict";

// Upstream 26.818 routes a newly-created local thread through
// `client-local-thread`, but its terminal target resolver groups that route
// with routes that cannot own terminals. Opening a terminal consequently
// creates no tab, and the empty panel immediately collapses.
//
// Keep this patch deliberately narrow and fail on bundle drift. The rewrite
// moves `client-local-thread` beside `home`, whose target already uses the
// client thread id plus the pending cwd/host. Both replacements have the same
// total byte length, so ASAR offsets and file sizes remain unchanged.

const crypto = require("crypto");
const fs = require("fs");

const CASE_LABEL_SOURCE = "case(?:`[^`]+`|\"[^\"]+\"|'[^']+')\\s*:";
const NULL_ROUTE_GROUP = new RegExp(
  `(?:${CASE_LABEL_SOURCE}\\s*)+return\\s+null\\b;?`,
  "g",
);

function routeCasePattern(kind, flags = "") {
  return new RegExp(`case(?:\`${kind}\`|"${kind}"|'${kind}')\\s*:`, flags);
}

function lastRouteCase(source, kind, before) {
  const pattern = routeCasePattern(kind, "g");
  let match;
  let last;
  while ((match = pattern.exec(source)) && match.index < before) {
    last = match;
  }
  return last;
}

function hasRouteCase(source, kind) {
  return routeCasePattern(kind).test(source);
}

function die(message) {
  console.error(`patch-terminal-route: ${message}`);
  process.exit(1);
}

function walkFiles(node, path = "", files = []) {
  for (const [name, entry] of Object.entries(node.files || {})) {
    const entryPath = path ? `${path}/${name}` : name;
    if (entry.files) {
      walkFiles(entry, entryPath, files);
    } else if (entry.offset != null && entry.size > 0 && name.endsWith(".js")) {
      files.push({ entry, path: entryPath });
    }
  }
  return files;
}

function digest(buffer) {
  return crypto.createHash("sha256").update(buffer).digest("hex");
}

function updateIntegrity(entry, contents) {
  const integrity = entry.integrity;
  if (!integrity || integrity.algorithm !== "SHA256") {
    die("target bundle entry has no supported SHA256 integrity metadata");
  }
  const blockSize = integrity.blockSize;
  if (!Number.isSafeInteger(blockSize) || blockSize <= 0) {
    die("target bundle entry has an invalid integrity block size");
  }

  integrity.hash = digest(contents);
  integrity.blocks = [];
  for (let offset = 0; offset < contents.length; offset += blockSize) {
    integrity.blocks.push(digest(contents.subarray(offset, offset + blockSize)));
  }
}

function resolverShape(source, homeIndex, routeIndex, prefixIndex = homeIndex) {
  const resolverPrefix = source.slice(Math.max(0, prefixIndex - 100), prefixIndex);
  const resolverBody = source.slice(homeIndex, routeIndex);
  return (
    routeIndex - homeIndex <= 700 &&
    /function\s+[A-Za-z_$][\w$]*\(([A-Za-z_$][\w$]*)\)\{(?:if\(\1\.get\([A-Za-z_$][\w$]*\)\)return null;)?switch\(\1\.value\.routeKind\)\{$/.test(
      resolverPrefix,
    ) &&
    resolverBody.includes(".value.clientThreadId") &&
    resolverBody.includes("conversationId:") &&
    resolverBody.includes("cwd:") &&
    resolverBody.includes("hostId:")
  );
}

const args = process.argv.slice(2);
const checkOnly = args[0] === "--check";
const asarPath = args[checkOnly ? 1 : 0];
if (!asarPath || args.length !== (checkOnly ? 2 : 1)) {
  die("usage: patch-terminal-route.js [--check] APP.ASAR");
}

const fd = fs.openSync(asarPath, checkOnly ? "r" : "r+");
try {
  const prelude = Buffer.alloc(16);
  if (fs.readSync(fd, prelude, 0, prelude.length, 0) !== prelude.length) {
    die("ASAR prelude is truncated");
  }
  const headerSize = prelude.readUInt32LE(12);
  if (prelude.readUInt32LE(0) !== 4 || headerSize === 0 || headerSize > 64 << 20) {
    die("unsupported ASAR header");
  }

  const headerBuffer = Buffer.alloc(headerSize);
  if (fs.readSync(fd, headerBuffer, 0, headerSize, 16) !== headerSize) {
    die("ASAR header is truncated");
  }

  let header;
  try {
    header = JSON.parse(headerBuffer.toString("utf8"));
  } catch (error) {
    die(`invalid ASAR header JSON: ${error.message}`);
  }

  const dataOffset = 8 + prelude.readUInt32LE(4);
  const vulnerable = [];
  let alreadyPatched = 0;

  for (const file of walkFiles(header)) {
    const contents = Buffer.alloc(file.entry.size);
    const position = dataOffset + Number(file.entry.offset);
    if (fs.readSync(fd, contents, 0, contents.length, position) !== contents.length) {
      die(`archive entry is truncated: ${file.path}`);
    }

    const source = contents.toString("utf8");
    const nullRouteGroups = [...source.matchAll(NULL_ROUTE_GROUP)];
    for (const group of nullRouteGroups) {
      const clientMatch = routeCasePattern("client-local-thread").exec(group[0]);
      if (!clientMatch) {
        continue;
      }
      if (
        routeCasePattern("client-local-thread", "g").test(
          group[0].slice(clientMatch.index + clientMatch[0].length),
        )
      ) {
        die(`multiple vulnerable resolvers in ${file.path}`);
      }

      const clientIndex = group.index + clientMatch.index;
      const homeMatch = lastRouteCase(source, "home", clientIndex);
      const homeIndex = homeMatch ? homeMatch.index : -1;
      if (homeIndex === -1 || !resolverShape(source, homeIndex, clientIndex)) {
        die(`terminal resolver shape changed in ${file.path}`);
      }
      vulnerable.push({
        clientIndex,
        clientLabel: clientMatch[0],
        contents,
        file,
        homeIndex,
        position,
        source,
      });
    }

    const patchedClientCases = routeCasePattern("client-local-thread", "g");
    let patchedMatch;
    while ((patchedMatch = patchedClientCases.exec(source))) {
      const homeIndex = patchedMatch.index + patchedMatch[0].length;
      const homeMatch = routeCasePattern("home").exec(source.slice(homeIndex));
      if (
        homeMatch &&
        homeMatch.index === 0 &&
        resolverShape(source, homeIndex, homeIndex + 700, patchedMatch.index)
      ) {
        alreadyPatched += 1;
      }
    }
  }

  if (vulnerable.length === 0) {
    if (alreadyPatched === 1) {
      console.log("patch-terminal-route: already patched");
      process.exit(0);
    }
    die("vulnerable terminal resolver not found; review the upstream bundle");
  }
  if (vulnerable.length !== 1 || alreadyPatched !== 0) {
    die("expected exactly one unpatched terminal resolver");
  }

  const target = vulnerable[0];
  const beforeClient = target.source.slice(target.homeIndex, target.clientIndex);
  const originalSpan = `${beforeClient}${target.clientLabel}`;
  const patchedSpan = `${target.clientLabel}${beforeClient}`;
  if (Buffer.byteLength(originalSpan) !== Buffer.byteLength(patchedSpan)) {
    die("internal error: terminal route rewrite changed byte length");
  }

  if (checkOnly) {
    console.log(`patch-terminal-route: would patch ${target.file.path}`);
    process.exit(0);
  }

  const patchedContents = Buffer.from(target.contents);
  // homeIndex counts UTF-16 code units; the buffer write needs a byte offset.
  const homeByteOffset = Buffer.byteLength(target.source.slice(0, target.homeIndex), "utf8");
  patchedContents.write(patchedSpan, homeByteOffset, "utf8");
  const verified = patchedContents.toString("utf8");
  const stillVulnerable = [...verified.matchAll(NULL_ROUTE_GROUP)].some((group) =>
    hasRouteCase(group[0], "client-local-thread"),
  );
  const patchedClientIndex = verified.indexOf(patchedSpan);
  if (patchedClientIndex === -1 || stillVulnerable) {
    die("internal error: terminal route rewrite did not verify");
  }

  updateIntegrity(target.file.entry, patchedContents);
  const updatedHeader = Buffer.from(JSON.stringify(header), "utf8");
  if (updatedHeader.length !== headerSize) {
    die("ASAR integrity update changed header length");
  }

  fs.writeSync(fd, patchedContents, 0, patchedContents.length, target.position);
  fs.writeSync(fd, updatedHeader, 0, updatedHeader.length, 16);
  fs.fsyncSync(fd);
  console.log(`patch-terminal-route: patched ${target.file.path}`);
} finally {
  fs.closeSync(fd);
}
