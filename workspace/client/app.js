const canvas = document.querySelector("#motion-chart");
const context = canvas.getContext("2d");
const sampleCount = document.querySelector("#sample-count");
const sessionLabel = document.querySelector("#session-id");
const statusEl = document.querySelector("#stream-status");
const colors = ["#76f4a8", "#ffbd69", "#75a7ff"];

const config = window.WIREJAC || {};
const apiBaseUrl = (config.apiBaseUrl || "").replace(/\/$/, "");
const apiKey = config.apiKey || "";
const sessionId = config.sessionId || "training-001";

let samples = [];
let mockCount = 48;

if (sessionLabel) {
  sessionLabel.textContent = sessionId;
}

function setStatus(text, live) {
  if (!statusEl) return;
  statusEl.textContent = text;
  statusEl.dataset.live = live ? "1" : "0";
}

function drawSeries(points) {
  const width = canvas.width;
  const height = canvas.height;
  context.clearRect(0, 0, width, height);
  context.strokeStyle = "#1d3026";
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
  axes.forEach((axis, axisIndex) => {
    context.strokeStyle = colors[axisIndex];
    context.lineWidth = 3;
    context.beginPath();
    if (points.length < 2) {
      for (let x = 0; x < width; x += 8) {
        const impulse = x > 670 && x < 760 ? Math.sin((x - 670) / 14) * 66 : 0;
        const y =
          height / 2 +
          Math.sin(x / (37 + axisIndex * 8) + axisIndex) * 22 +
          (impulse * (axisIndex + 1)) / 3;
        if (x === 0) context.moveTo(x, y);
        else context.lineTo(x, y);
      }
    } else {
      points.forEach((sample, index) => {
        const x = (index / Math.max(points.length - 1, 1)) * (width - 1);
        const value = Number(sample[axis]) || 0;
        const y = height / 2 - value * 12;
        if (index === 0) context.moveTo(x, y);
        else context.lineTo(x, y);
      });
    }
    context.stroke();
  });

  sampleCount.textContent = String(
    points.length > 0 ? points.length : mockCount++
  );
}

async function fetchSamples() {
  if (!apiBaseUrl) {
    setStatus("offline demo", false);
    drawSeries([]);
    return;
  }
  try {
    const url = new URL("/api/samples", apiBaseUrl);
    url.searchParams.set("session_id", sessionId);
    const headers = {};
    if (apiKey) headers["X-Api-Key"] = apiKey;
    const response = await fetch(url, { headers });
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }
    const payload = await response.json();
    samples = Array.isArray(payload.samples) ? payload.samples : [];
    setStatus("live from API", true);
    drawSeries(samples.slice(-120));
  } catch (err) {
    setStatus("API unreachable", false);
    drawSeries(samples.slice(-120));
    console.warn("samples fetch failed", err);
  }
}

drawSeries([]);
fetchSamples();
setInterval(fetchSamples, apiBaseUrl ? 2000 : 900);
