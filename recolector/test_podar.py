import tempfile
import unittest
from datetime import date
from pathlib import Path

import podar


class PruebasPodar(unittest.TestCase):
    def test_quita_lo_antiguo_y_deja_lo_reciente(self):
        with tempfile.TemporaryDirectory() as tmp:
            raiz = Path(tmp)
            for rel in ("2026/09/01/a.csv.gz", "2026/11/27/b.csv.gz", "tramos/2026/09/01/c.csv.gz",
                        "tramos/2026/11/27/d.csv.gz", "estaticos/recetas.json", "analisis/recetas.csv"):
                (raiz / rel).parent.mkdir(parents=True, exist_ok=True)
                (raiz / rel).write_text("x")
            quitados = podar.podar(raiz, 45, hoy=date(2026, 11, 28))
            self.assertEqual(len(quitados), 2)
            self.assertFalse((raiz / "2026/09").exists())
            self.assertFalse((raiz / "tramos/2026/09").exists())
            self.assertTrue((raiz / "2026/11/27/b.csv.gz").exists())
            self.assertTrue((raiz / "tramos/2026/11/27/d.csv.gz").exists())
            self.assertTrue((raiz / "estaticos/recetas.json").exists())
            self.assertTrue((raiz / "analisis/recetas.csv").exists())


if __name__ == "__main__":
    unittest.main()
