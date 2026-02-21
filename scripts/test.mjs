#!/usr/bin/env node
// Wrapper that translates --grep (Jest/Mocha style) to vitest's -t flag
import { execSync } from "child_process";

const args = process.argv.slice(2);
const vitestArgs = [];

for (let i = 0; i < args.length; i++) {
  if (args[i] === "--grep" && i + 1 < args.length) {
    vitestArgs.push("-t", args[i + 1]);
    i++;
  } else {
    vitestArgs.push(args[i]);
  }
}

const cmd = `npx vitest run ${vitestArgs.map((a) => `"${a}"`).join(" ")}`;
try {
  execSync(cmd, { stdio: "inherit" });
} catch {
  process.exit(1);
}
