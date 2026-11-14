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

function sourceWithPrefix(resolverPrefix) {
  return Buffer.from(
    source
      .toString()
      .replace("function route(e){switch(e.value.routeKind){", resolverPrefix),
  );
}

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

  const expandedPath = path.join(work, "expanded-routes.asar");
  const expandedSource = Buffer.from(
    source
      .toString()
      .replace(
        vulnerableTail,
        vulnerableTail.replace(
          "case`remote-thread`:",
          "case`new-route-kind`:case`remote-thread`:",
        ),
      ),
  );
  makeAsar(expandedPath, expandedSource);
  result = run("--check", expandedPath);
  assert.strictEqual(result.status, 0, result.stderr);
  result = run(expandedPath);
  assert.strictEqual(result.status, 0, result.stderr);
  const expandedPatched = readAsar(expandedPath).contents.toString();
  assert.ok(expandedPatched.includes("case`new-route-kind`:"));
  assert.ok(expandedPatched.includes(`${clientCase}case\`home\`:`));
  assert.ok(!expandedPatched.includes(`${clientCase}case\`remote-thread\`:`));
  result = run(expandedPath);
  assert.strictEqual(result.status, 0, result.stderr);
  assert.match(result.stdout, /already patched/);

  for (const [quote, quoteStyle] of [
    ['"', "double"],
    ["'", "single"],
  ]) {
    const routeCase = (kind) => `case${quote}${kind}${quote}:`;
    const clientLabel = routeCase("client-local-thread");
    const quotedPath = path.join(work, `quoted-${quoteStyle}.asar`);
    const quotedSource = Buffer.from(
      source
        .toString()
        .replace(/case`([^`]+)`:/g, (_, kind) => routeCase(kind)),
    );
    makeAsar(quotedPath, quotedSource);
    result = run("--check", quotedPath);
    assert.strictEqual(result.status, 0, result.stderr);
    result = run(quotedPath);
    assert.strictEqual(result.status, 0, result.stderr);
    const quotedPatched = readAsar(quotedPath).contents.toString();
    const quotedTail = vulnerableTail.replace(
      /case`([^`]+)`:/g,
      (_, kind) => routeCase(kind),
    );
    const expectedQuoted = quotedSource
      .toString()
      .replace(
        quotedTail,
        quotedTail.replace(clientLabel, ""),
      )
      .replace(routeCase("home"), `${clientLabel}${routeCase("home")}`);
    assert.strictEqual(quotedPatched, expectedQuoted);
    result = run(quotedPath);
    assert.strictEqual(result.status, 0, result.stderr);
    assert.match(result.stdout, /already patched/);
  }

  const guardedPath = path.join(work, "guarded.asar");
  makeAsar(
    guardedPath,
    sourceWithPrefix(
      "function W(e){if(e.get(_))return null;switch(e.value.routeKind){",
    ),
  );
  result = run("--check", guardedPath);
  assert.strictEqual(result.status, 0, result.stderr);
  assert.match(result.stdout, /would patch/);

  for (const [name, resolverPrefix] of [
    [
      "wrong-guard-parameter",
      "function W(e){if(t.get(_))return null;switch(e.value.routeKind){",
    ],
    [
      "wrong-switch-parameter",
      "function W(e){if(e.get(_))return null;switch(t.value.routeKind){",
    ],
  ]) {
    const unexpectedShapePath = path.join(work, `${name}.asar`);
    makeAsar(unexpectedShapePath, sourceWithPrefix(resolverPrefix));
    result = run("--check", unexpectedShapePath);
    assert.notStrictEqual(result.status, 0);
    assert.match(result.stderr, /terminal resolver shape changed/);
  }

  const unsupportedPath = path.join(work, "unsupported.asar");
  makeAsar(unsupportedPath, Buffer.from("console.log('upstream changed')"));
  result = run(unsupportedPath);
  assert.notStrictEqual(result.status, 0);
  assert.match(result.stderr, /review the upstream bundle/);

  console.log("patch-terminal-route: 9 ok, 0 failed");
} finally {
  fs.rmSync(work, { force: true, recursive: true });
}
