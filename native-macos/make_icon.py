from PIL import Image, ImageDraw

S = 1024
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)

# macOS-style rounded body with margin
m = 100
body = [m, m, S - m, S - m]
d.rounded_rectangle(body, radius=190, fill=(79, 70, 229, 255))  # indigo #4f46e5

white = (255, 255, 255, 255)
edge = (255, 255, 255, 210)

top = (512, 372)
bottoms = [(360, 664), (512, 664), (664, 664)]

# edges (coordinator -> workers)
for b in bottoms:
    d.line([top, b], fill=edge, width=18)

def node(c, r, fill):
    d.ellipse([c[0]-r, c[1]-r, c[0]+r, c[1]+r], fill=fill)

# worker nodes (outlined)
for b in bottoms:
    node(b, 46, white)
    node(b, 30, (79, 70, 229, 255))
# coordinator node (solid)
node(top, 66, white)

img.save("/tmp/wjicon/icon_1024.png")
print("saved")
