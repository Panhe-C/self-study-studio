#!/usr/bin/env python3

import argparse
import json
from pathlib import Path

from PIL import Image


A4_PIXEL_SIZE = (794, 1123)
PDF_DPI = 96


def parse_args():
    parser = argparse.ArgumentParser(
        description="Build an A4 PDF from the rendered product-guide page images."
    )
    parser.add_argument("input_dir", type=Path)
    parser.add_argument("output_file", type=Path)
    return parser.parse_args()


def load_pages(input_dir):
    page_paths = sorted(input_dir.glob("a4-*.png"))
    if not page_paths:
        raise SystemExit(f"No rendered A4 pages found in {input_dir}")

    pages = []
    for page_path in page_paths:
        with Image.open(page_path) as source:
            if source.size != A4_PIXEL_SIZE:
                raise SystemExit(
                    f"Unexpected page size for {page_path.name}: "
                    f"{source.size[0]}x{source.size[1]}"
                )
            pages.append(source.convert("RGB"))
    return page_paths, pages


def main():
    args = parse_args()
    page_paths, pages = load_pages(args.input_dir)
    args.output_file.parent.mkdir(parents=True, exist_ok=True)
    first, rest = pages[0], pages[1:]
    first.save(
        args.output_file,
        "PDF",
        resolution=PDF_DPI,
        save_all=True,
        append_images=rest,
        title="Self Study Studio 产品功能手册",
        author="Self Study Studio",
        creator="scripts/build-product-guide-pdf.py",
    )
    print(
        json.dumps(
            {
                "pageCount": len(page_paths),
                "pageSizePixels": list(A4_PIXEL_SIZE),
                "dpi": PDF_DPI,
                "output": str(args.output_file),
            },
            ensure_ascii=False,
        )
    )


if __name__ == "__main__":
    main()
