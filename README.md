# The King Lead Web

Installable Flutter PWA for iPhone, iPad, Android, and desktop browsers. It uses the same Firebase project and Firestore collections as The King Lead Android app.

## Install on iPhone

Open the hosted website in Safari, tap **Install App**, then use **Share → Add to Home Screen → Add**.

## GitHub Pages

1. Open **Settings → Pages**.
2. Set **Source** to **GitHub Actions**.
3. Run **Build and Deploy Web App** from the Actions tab.

The workflow builds with the repository base path /the-king-lead-web/.

## Custom subdomain

When moving to a custom subdomain, update the Flutter base href to / and add the final hostname to Firebase Authentication's authorized domains.

## Security note

The current Android app and this PWA share one Firebase Authentication account. For strong server-enforced Super Admin permissions, migrate to separate Firebase Auth users with custom role claims.
