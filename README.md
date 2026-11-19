# POC: Android-to-Android in-app audio call (WebRTC)

`server/` Node signaling server · `app/` Flutter app · `.github/workflows/build-apk.yml` cloud APK build.
No local Flutter/Android install needed.

## 1. Deploy the signaling server (free, gives you wss://)
Push this repo to GitHub, then on https://render.com: New > Web Service > pick the repo,
Root Directory `server`, Build `npm install`, Start `npm start`.
You get `https://xxx.onrender.com` -> your server URL is `wss://xxx.onrender.com`.
(Free tier sleeps after idle; first connect may take ~30s. Fine for a POC.)

## 2. (Recommended) TURN server
Without TURN, calls can fail on some mobile networks. Free option: create an account at
https://www.metered.ca (Open Relay) and copy the TURN URL(s), username, credential.

## 3. Build the APK on GitHub
Repo > Settings > Secrets and variables > Actions:
- Variables: `SERVER_URL` = wss://xxx.onrender.com ; `TURN_URL` = turn:host:80,turn:host:443 (optional)
- Secrets: `TURN_USER`, `TURN_CRED` (optional)
Then Actions > "Build APK" > Run workflow. Download artifact `poc-call-apk` (contains app-release.apk).

## 4. Give to customer
Send app-release.apk. They open it, allow "install unknown apps", install, open the app,
type a name (e.g. alice) and tap Connect. Second person does the same (bob). Alice types bob > Call.
Both must have the app open (no push notifications in this POC). Allow microphone when asked.
