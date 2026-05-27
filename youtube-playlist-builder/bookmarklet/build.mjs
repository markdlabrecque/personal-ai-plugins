#!/usr/bin/env node
// Build the bookmarklet URL from the readable source.
// Strips line comments and collapses whitespace, then percent-encodes.
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(here, "add-to-playlist.js"), "utf8");

const stripped = src
  .split("\n")
  .filter((l) => !/^\s*\/\//.test(l))
  .join("\n")
  .replace(/\s+/g, " ")
  .trim();

const url = "javascript:" + encodeURIComponent(stripped);
writeFileSync(join(here, "add-to-playlist.bookmarklet.txt"), url + "\n");
console.log("Wrote add-to-playlist.bookmarklet.txt (" + url.length + " chars)");
