"use strict";
const crypto = require("node:crypto");
const readline = require("node:readline");
const rl = readline.createInterface({input: process.stdin, output: process.stdout});
rl.question("Super Admin PIN: ", (pin) => {
  if (!/^\d{4,12}$/.test(pin.trim())) {
    console.error("PIN must contain 4–12 digits.");
    process.exitCode = 1;
  } else {
    const salt = crypto.randomBytes(16).toString("hex");
    const hash = crypto.scryptSync(pin.trim(), salt, 64).toString("hex");
    console.log(salt + ":" + hash);
  }
  rl.close();
});
