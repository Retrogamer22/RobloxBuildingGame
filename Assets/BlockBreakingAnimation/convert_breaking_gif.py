from PIL import Image, ImageSequence
from pathlib import Path

# Your GIF file name
INPUT_GIF = "rainbow_breaking.gif"

# Output folder for frames
OUTPUT_DIR = Path("gif_frames")
OUTPUT_DIR.mkdir(exist_ok=True)

# Optional extras
MAKE_SPRITESHEET = True
MAKE_PREVIEW_GIF = True


def main():
    gif_path = Path(INPUT_GIF)

    if not gif_path.exists():
        print(f"Could not find GIF: {INPUT_GIF}")
        print("Make sure the GIF is in the same folder as this script.")
        return

    gif = Image.open(gif_path)

    frames = []
    durations = []

    for index, frame in enumerate(ImageSequence.Iterator(gif)):
        # Convert to RGBA so transparency is preserved properly
        frame_rgba = frame.convert("RGBA")

        output_path = OUTPUT_DIR / f"frame_{index:02d}.png"
        frame_rgba.save(output_path)

        frames.append(frame_rgba)
        durations.append(frame.info.get("duration", 100))

        print(f"Saved {output_path}")

    print(f"\nExported {len(frames)} frames.")

    # Optional: make a horizontal spritesheet
    if MAKE_SPRITESHEET and frames:
        width, height = frames[0].size

        sheet = Image.new(
            "RGBA",
            (width * len(frames), height),
            (0, 0, 0, 0)
        )

        for i, frame in enumerate(frames):
            sheet.paste(frame, (i * width, 0))

        sheet.save("gif_spritesheet.png")
        print("Saved spritesheet: gif_spritesheet.png")

    # Optional: make a preview GIF
    if MAKE_PREVIEW_GIF and frames:
        frames[0].save(
            "gif_preview.gif",
            save_all=True,
            append_images=frames[1:],
            duration=durations,
            loop=0,
            disposal=2
        )

        print("Saved preview GIF: gif_preview.gif")


if __name__ == "__main__":
    main()