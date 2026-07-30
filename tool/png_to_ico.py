from pathlib import Path
import sys

from PIL import Image


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("Verwendung: png_to_ico.py QUELLE.png ZIEL.ico")

    source = Path(sys.argv[1])
    destination = Path(sys.argv[2])
    destination.parent.mkdir(parents=True, exist_ok=True)

    with Image.open(source) as image:
        rgba = image.convert("RGBA")
        rgba.save(
            destination,
            format="ICO",
            sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)],
        )


if __name__ == "__main__":
    main()
