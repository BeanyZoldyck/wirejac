// Copy to config.js for local Meta app → API wiring.
// Deploy injects config.js automatically (do not commit real keys).
window.WIREJAC = {
  apiBaseUrl: "https://YOUR_LAMBDA_URL.lambda-url.us-west-2.on.aws/",
  apiKey: "PASTE_SHARED_TEAM_KEY",
  sessionId: "training-001"
};
