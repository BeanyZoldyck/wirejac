from PIL import Image, ImageDraw
S = 1024
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)
ORANGE = (249, 115, 22, 255)  # #f97316
m = 100
d.rounded_rectangle([m, m, S - m, S - m], radius=190, fill=ORANGE)
white = (255, 255, 255, 255)
edge = (255, 255, 255, 210)
top = (512, 372)
bottoms = [(360, 664), (512, 664), (664, 664)]
for b in bottoms:
    d.line([top, b], fill=edge, width=18)
def node(c, r, fill):
    d.ellipse([c[0]-r, c[1]-r, c[0]+r, c[1]+r], fill=fill)
for b in bottoms:
    node(b, 46, white); node(b, 30, ORANGE)
node(top, 66, white)
img.save("native-macos/icon_1024.png")
print("orange icon saved")
