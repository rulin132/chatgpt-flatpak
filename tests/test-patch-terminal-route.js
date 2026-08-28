#!/usr/bin/env node
"use strict";

const assert = require("assert");
const crypto = require("crypto");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const repo = path.resolve(__dirname, "..");
const patcher = path.join(repo, "build-aux", "patch-terminal-route.js");
const work = fs.mkdtempSync(path.join(os.tmpdir(), "terminal-route-test-"));

const clientCase = "case`client-local-thread`:";
const vulnerableTail =
  "case`new-thread-panel`:case`chatgpt-thread`:case`client-local-thread`:" +
  "case`remote-thread`:case`other`:return null";
const source = Buffer.from(
  "const i18n=`caf\u00e9 \u4e2d\u6587 \ud83d\ude00`;" +
    "function route(e){switch(e.value.routeKind){case`home`:{let t=e.get(cwd),n=e.get(host);" +
    "return{conversationId:e.value.clientThreadId,conversationTitle:null,cwd:t,hostId:n}}" +
    "case`local-thread`:return{conversationId:e.value.conversationId,conversationTitle:null," +
    `cwd:e.get(cwd),hostId:e.get(host)};${vulnerableTail}}}`,
);

function hash(buffer) {
  return crypto.createHash("sha256").update(buffer).digest("hex");
}

function makeAsar(asarPath, contents) {
  const blockSize = 64;
  const integrity = {
    algorithm: "SHA256",
    blockSize,
    blocks: [],
    hash: hash(contents),
  };
  for (let offset = 0; offset < contents.length; offset += blockSize) {
    integrity.blocks.push(hash(contents.subarray(offset, offset + blockSize)));
  }
  const header = {
    files: {
      webview: {
        files: {
          assets: {
            files: {
              "app-initial-test.js": {
                integrity,
                offset: "0",
                size: contents.length,
              },
            },
          },
        },
      },
    },
  };
  const headerBytes = Buffer.from(JSON.stringify(header));
  const alignedHeaderSize = (headerBytes.length + 3) & ~3;
  const prelude = Buffer.alloc(16);
  prelude.writeUInt32LE(4, 0);
  prelude.writeUInt32LE(8 + alignedHeaderSize, 4);
  prelude.writeUInt32LE(4 + headerBytes.length, 8);
  prelude.writeUInt32LE(headerBytes.length, 12);
  const dataOffset = 16 + alignedHeaderSize;
  const archive = Buffer.alloc(dataOffset + contents.length);
  prelude.copy(archive, 0);
  headerBytes.copy(archive, 16);
  contents.copy(archive, dataOffset);
  fs.writeFileSync(asarPath, archive);
}

function readAsar(asarPath) {
  const archive = fs.readFileSync(asarPath);
  const headerSize = archive.readUInt32LE(12);
  const header = JSON.parse(archive.subarray(16, 16 + headerSize).toString());
  const entry = header.files.webview.files.assets.files["app-initial-test.js"];
  const dataOffset = 8 + archive.readUInt32LE(4);
  const contents = archive.subarray(dataOffset, dataOffset + entry.size);
  return { contents, entry };
}

function run(...args) {
  return spawnSync(process.execPath, [patcher, ...args], { encoding: "utf8" });
}

try {
  const asarPath = path.join(work, "app.asar");
  makeAsar(asarPath, source);

  let result = run("--check", asarPath);
  assert.strictEqual(result.status, 0, result.stderr);
  assert.match(result.stdout, /would patch/);
  assert.ok(readAsar(asarPath).contents.includes(Buffer.from(vulnerableTail)));

  result = run(asarPath);
  assert.strictEqual(result.status, 0, result.stderr);
  assert.match(result.stdout, /patched/);

  const patched = readAsar(asarPath);
  const patchedText = patched.contents.toString();
  const expectedText = source
    .toString()
    .replace("case`home`:", `${clientCase}case\`home\`:`)
    .replace(vulnerableTail, vulnerableTail.replace(clientCase, ""));
  assert.strictEqual(patched.contents.length, source.length);
  assert.strictEqual(patchedText, expectedText);
  assert.strictEqual(patched.entry.integrity.hash, hash(patched.contents));
  assert.deepStrictEqual(
    patched.entry.integrity.blocks,
    Array.from(
      { length: Math.ceil(patched.contents.length / patched.entry.integrity.blockSize) },
      (_, index) =>
        hash(
          patched.contents.subarray(
            index * patched.entry.integrity.blockSize,
            (index + 1) * patched.entry.integrity.blockSize,
          ),
        ),
    ),
  );

  result = run(asarPath);
  assert.strictEqual(result.status, 0, result.stderr);
  assert.match(result.stdout, /already patched/);

  const unsupportedPath = path.join(work, "unsupported.asar");
  makeAsar(unsupportedPath, Buffer.from("console.log('upstream changed')"));
  result = run(unsupportedPath);
  assert.notStrictEqual(result.status, 0);
  assert.match(result.stderr, /review the upstream bundle/);

  console.log("patch-terminal-route: 4 ok, 0 failed");
} finally {
  fs.rmSync(work, { force: true, recursive: true });
}
