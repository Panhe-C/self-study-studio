import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from PIL import Image
from pypdf import PdfReader


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "build-product-guide-pdf.py"


class ProductGuidePdfTests(unittest.TestCase):
    def test_builds_an_a4_pdf_from_ordered_page_images(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            pages = root / "pages"
            pages.mkdir()
            Image.new("RGB", (794, 1123), "#F4F1EB").save(pages / "a4-02.png")
            Image.new("RGB", (794, 1123), "#6657D9").save(pages / "a4-01.png")
            output = root / "guide.pdf"

            subprocess.run(
                [sys.executable, str(SCRIPT), str(pages), str(output)],
                check=True,
                capture_output=True,
                text=True,
            )

            reader = PdfReader(output)
            self.assertEqual(len(reader.pages), 2)
            first = reader.pages[0]
            self.assertAlmostEqual(float(first.mediabox.width), 595.5, delta=0.5)
            self.assertAlmostEqual(float(first.mediabox.height), 842.25, delta=0.5)


if __name__ == "__main__":
    unittest.main()
