# Secure deployment setup

This repository contains no Firebase password or PIN. Complete these owner-only steps before the first deployment.

1. In Firebase Authentication, keep the existing shared owner account enabled.
2. Copy that account's Firebase UID. Set it as the Functions parameter LEGACY_OWNER_UID.
3. Generate the Super Admin PIN secret locally with: node functions/make-pin-hash.js
4. Save the generated value as the Firebase Functions secret ADMIN_PIN_HASH.
5. Deploy Functions and Firestore rules.
6. Register a Firebase Web App for project the-king-ebce5 and replace the web appId in lib/main.dart.
7. Add the final website hostname to Firebase Authentication → Authorized domains.
8. Deploy the Flutter web build.

Both Sohag and Azizul use the same protected Super Admin PIN secret. Existing staff PINs are migrated from plaintext to a salted scrypt hash on their first successful secure login.
