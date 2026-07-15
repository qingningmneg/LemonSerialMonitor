from __future__ import annotations

import argparse
import json
from pathlib import Path

import pypdfium2 as pdfium


def main() -> None:
    parser = argparse.ArgumentParser(description="Render every PDF page to a PNG for visual QA.")
    parser.add_argument("pdf", type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--scale", type=float, default=2.0)
    args = parser.parse_args()

    pdf_path = args.pdf.resolve(strict=True)
    output_dir = args.output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    document = pdfium.PdfDocument(str(pdf_path))
    outputs: list[dict[str, object]] = []
    try:
        for index in range(len(document)):
            page = document[index]
            try:
                bitmap = page.render(scale=args.scale)
                image = bitmap.to_pil()
                output = output_dir / f"page-{index + 1:03d}.png"
                image.save(output, "PNG", optimize=True)
                outputs.append(
                    {
                        "page": index + 1,
                        "path": str(output),
                        "width": image.width,
                        "height": image.height,
                        "bytes": output.stat().st_size,
                    }
                )
            finally:
                page.close()
    finally:
        document.close()
    print(json.dumps({"pdf": str(pdf_path), "pages": outputs}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
