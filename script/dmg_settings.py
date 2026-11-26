from pathlib import Path

# dmgbuild provides the values passed with -D in `defines`.
app = Path(defines["app"]).resolve(strict=True)
files = [str(app)]
symlinks = {"Applications": "/Applications"}

format = "UDZO"
background = str(Path("script/dmg-background.tiff").resolve(strict=True))
window_rect = ((180, 140), (660, 360))
icon_size = 104
text_size = 13
icon_locations = {app.name: (172, 147), "Applications": (488, 147)}
