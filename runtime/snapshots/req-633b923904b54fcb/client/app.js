const canvas = document.querySelector("#motion-chart");
const context = canvas.getContext("2d");
const sampleCount = document.querySelector("#sample-count");
const colors = ["#76f4a8", "#ffbd69", "#75a7ff"];
let count = 48;

function draw() {
  const width = canvas.width;
  const height = canvas.height;
  context.clearRect(0, 0, width, height);
  context.strokeStyle = "#1d3026";
  context.lineWidth = 1;
  for (let x = 0; x <= width; x += 100) {
    context.beginPath(); context.moveTo(x, 0); context.lineTo(x, height); context.stroke();
  }
  for (let y = 0; y <= height; y += 60) {
    context.beginPath(); context.moveTo(0, y); context.lineTo(width, y); context.stroke();
  }
  colors.forEach((color, axis) => {
    context.strokeStyle = color;
    context.lineWidth = 3;
    context.beginPath();
    for (let x = 0; x < width; x += 8) {
      const impulse = x > 670 && x < 760 ? Math.sin((x - 670) / 14) * 66 : 0;
      const y = height / 2 + Math.sin(x / (37 + axis * 8) + axis) * 22 + impulse * (axis + 1) / 3;
      if (x === 0) context.moveTo(x, y); else context.lineTo(x, y);
    }
    context.stroke();
  });
  sampleCount.textContent = String(count++);
}

draw();
setInterval(draw, 900);
