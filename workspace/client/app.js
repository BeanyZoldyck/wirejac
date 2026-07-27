const canvas = document.querySelector("#motion-chart");
const context = canvas.getContext("2d");
const sampleCount = document.querySelector("#sample-count");
const sessionLabel = document.querySelector("#session-id");
const statusEl = document.querySelector("#stream-status");
const statusDot = document.querySelector("#status-dot");
const lastUpdate = document.querySelector("#last-update");
const gyroX = document.querySelector("#gyro-x");
const gyroY = document.querySelector("#gyro-y");
const gyroZ = document.querySelector("#gyro-z");
const colors = ["#a0d8a0", "#70d090", "#40a060"];

const config = window.WIREJAC || {};
const apiBaseUrl = (config.apiBaseUrl || "").replace(/\/$/, "");
const apiKey = config.apiKey || "";
const sessionId = config.sessionId || "training-001";

let samples = [];
let fetching = false;

if (sessionLabel) {
  sessionLabel.textContent = sessionId;
}

function setStatus(text, live) {
  if (!statusEl) return;
  statusEl.textContent = text;
  statusEl.dataset.live = live ? "1" : "0";
  statusDot.classList.toggle("live", live);
}

function drawSeries(points) {
  const width = canvas.width;
  const height = canvas.height;
  context.clearRect(0, 0, width, height);
  context.strokeStyle = "#1a5030";
  context.lineWidth = 1;
  for (let x = 0; x <= width; x += 100) {
    context.beginPath();
    context.moveTo(x, 0);
    context.lineTo(x, height);
    context.stroke();
  }
  for (let y = 0; y <= height; y += 60) {
    context.beginPath();
    context.moveTo(0, y);
    context.lineTo(width, y);
    context.stroke();
  }

  const axes = ["x", "y", "z"];
  const maxMagnitude = Math.max(
    10,
    ...points.flatMap((sample) => axes.map((axis) => Math.abs(Number(sample[axis]) || 0)))
  );
  axes.forEach((axis, axisIndex) => {
    context.strokeStyle = colors[axisIndex];
    context.lineWidth = 3;
    context.beginPath();
    if (points.length >= 2) {
      points.forEach((sample, index) => {
        const x = (index / Math.max(points.length - 1, 1)) * (width - 1);
        const value = Number(sample[axis]) || 0;
        const y = height / 2 - (value / maxMagnitude) * height * 0.42;
        if (index === 0) context.moveTo(x, y);
        else context.lineTo(x, y);
      });
    }
    context.stroke();
  });

  const latest = points.at(-1);
  gyroX.textContent = latest ? Number(latest.x).toFixed(2) : "--";
  gyroY.textContent = latest ? Number(latest.y).toFixed(2) : "--";
  gyroZ.textContent = latest ? Number(latest.z).toFixed(2) : "--";
}

async function fetchSamples() {
  if (fetching) return;
  if (!apiBaseUrl) {
    setStatus("API not configured", false);
    drawSeries([]);
    return;
  }
  fetching = true;
  try {
    const url = new URL("/api/samples", apiBaseUrl);
    url.searchParams.set("session_id", sessionId);
    url.searchParams.set("_", String(Date.now()));
    const headers = {};
    if (apiKey) headers["X-Api-Key"] = apiKey;
    const response = await fetch(url, { headers, cache: "no-store" });
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }
    const payload = await response.json();
    samples = Array.isArray(payload.samples) ? payload.samples : [];
    sampleCount.textContent = String(samples.length);
    const latest = samples.at(-1);
    const isFresh = latest && Date.now() - Number(latest.captured_at_ms) < 3000;
    setStatus(isFresh ? "LIVE - ESP32 GYRO" : "GY-521 DISCONNECTED", Boolean(isFresh));
    if (samples.length) {
      lastUpdate.textContent = `last sample ${new Date(Number(latest.captured_at_ms)).toLocaleTimeString()}`;
    }
    drawSeries(samples.slice(-120));
  } catch (err) {
    setStatus("API unreachable", false);
    drawSeries(samples.slice(-120));
    console.warn("samples fetch failed", err);
  } finally {
    fetching = false;
  }
}

drawSeries([]);
fetchSamples();
setInterval(fetchSamples, apiBaseUrl ? 400 : 900);