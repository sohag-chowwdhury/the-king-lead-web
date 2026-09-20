"use strict";

const crypto = require("node:crypto");
const {initializeApp} = require("firebase-admin/app");
const {getAuth} = require("firebase-admin/auth");
const {FieldValue, getFirestore} = require("firebase-admin/firestore");
const {defineSecret, defineString} = require("firebase-functions/params");
const {HttpsError, onCall} = require("firebase-functions/v2/https");

initializeApp();
const db = getFirestore();
const tenantUid = defineString("LEGACY_OWNER_UID");
const adminPinHash = defineSecret("ADMIN_PIN_HASH");
const region = "asia-south1";

const admins = [
  {id: "admin_sohag", name: "Sohag", role: "superadmin"},
  {id: "admin_azizul", name: "Azizul", role: "superadmin"},
];

function cleanText(value, max = 100) {
  return typeof value === "string" ? value.trim().slice(0, max) : "";
}

function encodePin(pin, salt = crypto.randomBytes(16).toString("hex")) {
  const hash = crypto.scryptSync(pin, salt, 64).toString("hex");
  return salt + ":" + hash;
}

function pinMatches(pin, encoded) {
  if (!encoded || !encoded.includes(":")) return false;
  const parts = encoded.split(":");
  const actual = crypto.scryptSync(pin, parts[0], 64);
  const expected = Buffer.from(parts[1], "hex");
  return actual.length === expected.length && crypto.timingSafeEqual(actual, expected);
}

function requireAdmin(request) {
  if (!request.auth || request.auth.token.role !== "superadmin") {
    throw new HttpsError("permission-denied", "Super Admin permission required.");
  }
}

function staffRef(staffId) {
  return db.doc("users/" + tenantUid.value() + "/staff/" + staffId);
}

async function applyRateLimit(request, userId) {
  const forwarded = cleanText(request.rawRequest.headers["x-forwarded-for"] || "unknown", 120);
  const key = crypto.createHash("sha256").update(forwarded + "|" + userId).digest("hex");
  const ref = db.doc("login_rate_limits/" + key);
  const now = Date.now();
  await db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(ref);
    const data = snapshot.data() || {};
    const withinWindow = now - (data.startedAt || 0) < 10 * 60 * 1000;
    const attempts = withinWindow ? (data.attempts || 0) + 1 : 1;
    if (attempts > 8) {
      throw new HttpsError("resource-exhausted", "অনেকবার চেষ্টা হয়েছে। ১০ মিনিট পরে চেষ্টা করুন।");
    }
    transaction.set(ref, {
      attempts,
      startedAt: withinWindow ? data.startedAt : now,
      expiresAt: new Date(now + 15 * 60 * 1000),
    });
  });
}

exports.listAppUsers = onCall({region}, async () => {
  const snapshot = await db.collection("users/" + tenantUid.value() + "/staff").get();
  const staff = snapshot.docs.map((doc) => {
    const data = doc.data();
    return {
      id: doc.id,
      name: cleanText(data.name) || "জানা নাই",
      role: "staff",
      active: data.active !== false,
      sessionVersion: Number(data.sessionVersion || 0),
    };
  });
  return {users: [...admins.map((item) => ({...item, active: true, sessionVersion: 0})), ...staff]};
});

exports.loginWithPin = onCall({region, secrets: [adminPinHash]}, async (request) => {
  const userId = cleanText(request.data?.userId, 80);
  const pin = cleanText(request.data?.pin, 20);
  if (!userId || !/^\d{4,12}$/.test(pin)) {
    throw new HttpsError("invalid-argument", "সঠিক User ও PIN দিন।");
  }
  await applyRateLimit(request, userId);
  let user;
  const admin = admins.find((item) => item.id === userId);
  if (admin) {
    if (!pinMatches(pin, adminPinHash.value())) {
      throw new HttpsError("unauthenticated", "PIN সঠিক নয়।");
    }
    user = {...admin, sessionVersion: 0};
  } else {
    const ref = staffRef(userId);
    const snapshot = await ref.get();
    if (!snapshot.exists) throw new HttpsError("not-found", "User পাওয়া যায়নি।");
    const data = snapshot.data();
    if (data.active === false) throw new HttpsError("permission-denied", "এই User Block করা আছে।");
    let valid = pinMatches(pin, data.pinHash);
    if (!valid && typeof data.pin === "string" && data.pin === pin) {
      valid = true;
      await ref.update({pinHash: encodePin(pin), pin: FieldValue.delete()});
    }
    if (!valid) throw new HttpsError("unauthenticated", "PIN সঠিক নয়।");
    user = {
      id: userId,
      name: cleanText(data.name) || "জানা নাই",
      role: "staff",
      sessionVersion: Number(data.sessionVersion || 0),
    };
  }
  const claims = {
    appUserId: user.id,
    role: user.role,
    sessionVersion: user.sessionVersion,
    tenantUid: tenantUid.value(),
  };
  const token = await getAuth().createCustomToken(tenantUid.value(), claims);
  return {token, user};
});

exports.upsertStaff = onCall({region}, async (request) => {
  requireAdmin(request);
  const name = cleanText(request.data?.name);
  const pin = cleanText(request.data?.pin, 20);
  const suppliedId = cleanText(request.data?.staffId, 100);
  if (!name || (!suppliedId && !/^\d{4,12}$/.test(pin)) || (pin && !/^\d{4,12}$/.test(pin))) {
    throw new HttpsError("invalid-argument", "নাম এবং ৪–১২ সংখ্যার PIN দিন।");
  }
  const ref = suppliedId ? staffRef(suppliedId) : db.collection("users/" + tenantUid.value() + "/staff").doc();
  const current = await ref.get();
  await ref.set({
    name,
    ...(pin ? {pinHash: encodePin(pin), pin: FieldValue.delete()} : {}),
    role: "staff",
    active: current.exists ? current.data().active !== false : true,
    sessionVersion: current.exists ? Number(current.data().sessionVersion || 0) + (pin ? 1 : 0) : 0,
    updatedAt: FieldValue.serverTimestamp(),
    ...(current.exists ? {} : {createdAt: FieldValue.serverTimestamp()}),
  }, {merge: true});
  return {staffId: ref.id};
});

exports.resetStaffPin = onCall({region}, async (request) => {
  requireAdmin(request);
  const staffId = cleanText(request.data?.staffId, 100);
  const pin = cleanText(request.data?.pin, 20);
  if (!staffId || !/^\d{4,12}$/.test(pin)) throw new HttpsError("invalid-argument", "সঠিক PIN দিন।");
  await staffRef(staffId).update({
    pinHash: encodePin(pin),
    pin: FieldValue.delete(),
    sessionVersion: FieldValue.increment(1),
  });
  return {ok: true};
});

exports.forceStaffLogout = onCall({region}, async (request) => {
  requireAdmin(request);
  const staffId = cleanText(request.data?.staffId, 100);
  await staffRef(staffId).update({sessionVersion: FieldValue.increment(1)});
  return {ok: true};
});

exports.setStaffActive = onCall({region}, async (request) => {
  requireAdmin(request);
  const staffId = cleanText(request.data?.staffId, 100);
  await staffRef(staffId).update({
    active: request.data?.active === true,
    sessionVersion: FieldValue.increment(1),
  });
  return {ok: true};
});
