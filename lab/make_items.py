from PIL import Image, ImageDraw
import os
D = os.path.dirname(os.path.abspath(__file__))
def sword(color, guard, path):
    im = Image.new("RGBA", (112, 112), (0, 0, 0, 0)); d = ImageDraw.Draw(im)
    d.polygon([(56, 6), (66, 20), (62, 74), (50, 74), (46, 20)], fill=color, outline=(60, 40, 0))
    d.rectangle([30, 74, 82, 82], fill=guard); d.rectangle([52, 82, 60, 102], fill=(110, 60, 20)); d.ellipse([49, 100, 63, 110], fill=guard)
    im.save(path)
sword((250, 200, 40), (40, 90, 220), D + "/golden.png")
sword((200, 205, 215), (120, 120, 120), D + "/silver.png")
im = Image.new("RGBA", (112, 112), (0, 0, 0, 0)); d = ImageDraw.Draw(im); d.polygon([(56, 8), (100, 24), (92, 76), (56, 104), (20, 76), (12, 24)], fill=(40, 80, 200), outline=(230, 230, 230)); im.save(D + "/shield.png")
im = Image.new("RGBA", (112, 112), (0, 0, 0, 0)); d = ImageDraw.Draw(im); d.rectangle([48, 10, 64, 34], fill=(150, 100, 60)); d.ellipse([22, 30, 90, 104], fill=(220, 30, 60)); im.save(D + "/potion.png")
# The picture the user "uploads": the golden sword on a plain background, bigger.
ref = Image.new("RGB", (400, 400), (245, 245, 245)); g = Image.open(D + "/golden.png").resize((300, 300)); ref.paste(g, (50, 50), g); ref.save(D + "/ref-golden.jpg", quality=90)
