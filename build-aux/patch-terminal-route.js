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

const CLIENT_CASE = "case`client-local-thread`:";
const HOME_CASE = "case`home`:";
const PATCHED_PREFIX = `${CLIENT_CASE}${HOME_CASE}`;
const VULNERABLE_TAIL =
  "case`new-thread-panel`:case`chatgpt-thread`:case`client-local-thread`:" +
  "case`remote-thread`:case`other`:return null";
const PATCHED_TAIL =
  "case`new-thread-panel`:case`chatgpt-thread`:case`remote-thread`:" +
  "case`other`:return null";

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
    const tailIndex = source.indexOf(VULNERABLE_TAIL);
    if (tailIndex !== -1) {
      if (source.indexOf(VULNERABLE_TAIL, tailIndex + 1) !== -1) {
        die(`multiple vulnerable resolvers in ${file.path}`);
      }
      const homeIndex = source.lastIndexOf(HOME_CASE, tailIndex);
      const resolverPrefix = source.slice(Math.max(0, homeIndex - 100), homeIndex);
      const resolverBody = source.slice(homeIndex, tailIndex);
      if (
        homeIndex === -1 ||
        tailIndex - homeIndex > 700 ||
        !/function\s+[A-Za-z_$][\w$]*\(([A-Za-z_$][\w$]*)\)\{(?:if\(\1\.get\([A-Za-z_$][\w$]*\)\)return null;)?switch\(\1\.value\.routeKind\)\{$/.test(
          resolverPrefix,
        ) ||
        !resolverBody.includes(".value.clientThreadId") ||
        !resolverBody.includes("conversationId:") ||
        !resolverBody.includes("cwd:") ||
        !resolverBody.includes("hostId:")
      ) {
        die(`terminal resolver shape changed in ${file.path}`);
      }
      vulnerable.push({ contents, file, homeIndex, position, source, tailIndex });
    }

    const patchedTailIndex = source.indexOf(PATCHED_TAIL);
    if (patchedTailIndex !== -1) {
      const patchedPrefixIndex = source.lastIndexOf(PATCHED_PREFIX, patchedTailIndex);
      const patchedBody = source.slice(patchedPrefixIndex, patchedTailIndex);
      if (
        patchedPrefixIndex !== -1 &&
        patchedTailIndex - patchedPrefixIndex <= 700 &&
        patchedBody.includes(".value.clientThreadId") &&
        patchedBody.includes("conversationId:") &&
        patchedBody.includes("cwd:") &&
        patchedBody.includes("hostId:")
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
  const beforeTail = target.source.slice(target.homeIndex, target.tailIndex);
  const patchedTail = VULNERABLE_TAIL.replace(CLIENT_CASE, "");
  const originalSpan = `${beforeTail}${VULNERABLE_TAIL}`;
  const patchedSpan = `${CLIENT_CASE}${beforeTail}${patchedTail}`;
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
  if (!verified.includes(PATCHED_PREFIX) || verified.includes(VULNERABLE_TAIL)) {
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
