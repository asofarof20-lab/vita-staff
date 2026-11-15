from pathlib import Path
from PIL import Image
ROOT = Path(__file__).resolve().parent.parent
image = Image.open(ROOT / "assets" / "vitanet-icon.jpg").convert("RGB")
for size in (192, 512):
    image.resize((size, size), Image.Resampling.LANCZOS).save(ROOT / f"vitanet-icon-{size}.png", format="PNG", optimize=True)
desktop = ROOT / "desktop"
desktop.mkdir(parents=True, exist_ok=True)
image.save(desktop / "vitanet.ico", format="ICO", sizes=[(16,16),(24,24),(32,32),(48,48),(64,64),(128,128),(256,256)])
android_res = ROOT / "android" / "app" / "src" / "main" / "res"
for density, size in {"mipmap-mdpi":48,"mipmap-hdpi":72,"mipmap-xhdpi":96,"mipmap-xxhdpi":144,"mipmap-xxxhdpi":192}.items():
    folder = android_res / density
    folder.mkdir(parents=True, exist_ok=True)
    image.resize((size,size), Image.Resampling.LANCZOS).save(folder / "ic_launcher.png", format="PNG", optimize=True)
print("VITANET icons generated from the original logo.")
