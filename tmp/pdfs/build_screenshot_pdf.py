from pathlib import Path

from PIL import Image
from reportlab.lib.pagesizes import A4
from reportlab.pdfgen import canvas


SOURCES = [
    Path("/Users/matthewchew/Desktop/Screenshot 2026-08-30 at 1.03.45\u202fPM.png"),
    Path("/Users/matthewchew/Desktop/Screenshot 2026-08-30 at 1.03.49\u202fPM.png"),
    Path("/Users/matthewchew/Desktop/Screenshot 2026-08-30 at 1.03.53\u202fPM.png"),
    Path("/Users/matthewchew/Desktop/Screenshot 2026-08-30 at 1.04.10\u202fPM.png"),
    Path("/Users/matthewchew/Desktop/Screenshot 2026-08-30 at 1.04.14\u202fPM.png"),
    Path("/Users/matthewchew/Desktop/Screenshot 2026-08-30 at 1.04.19\u202fPM.png"),
]

OUTPUT = Path(
    "/Users/matthewchew/Desktop/CoachPlanner/output/pdf/"
    "Die With A Smile - Guitar Tab.pdf"
)


def main() -> None:
    missing = [str(path) for path in SOURCES if not path.is_file()]
    if missing:
        raise FileNotFoundError(f"Missing source screenshots: {missing}")

    page_width, page_height = A4
    pdf = canvas.Canvas(
        str(OUTPUT),
        pagesize=A4,
        pageCompression=1,
        invariant=1,
    )
    pdf.setTitle("Die With A Smile - Guitar Tab")
    pdf.setSubject("Six-page guitar tablature assembled from screenshots")
    pdf.setCreator("Codex")

    for source in SOURCES:
        with Image.open(source) as image:
            image_width, image_height = image.size

        scale = min(page_width / image_width, page_height / image_height)
        draw_width = image_width * scale
        draw_height = image_height * scale
        x = (page_width - draw_width) / 2
        y = (page_height - draw_height) / 2

        pdf.setFillColorRGB(1, 1, 1)
        pdf.rect(0, 0, page_width, page_height, fill=1, stroke=0)
        pdf.drawImage(
            str(source),
            x,
            y,
            width=draw_width,
            height=draw_height,
            preserveAspectRatio=True,
            anchor="c",
            mask="auto",
        )
        pdf.showPage()

    pdf.save()


if __name__ == "__main__":
    main()
