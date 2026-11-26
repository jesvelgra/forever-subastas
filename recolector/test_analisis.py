"""Pruebas del análisis con un historial simulado."""

import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

import analisis as a
import recolector as r

HIERBA, POCION, VIAL = 2447, 118, 3371


def simular(dir_datos: Path, dias: int, inicio: datetime):
    """Hierba: más barata a las 5 h de Madrid y más cara a las 21 h; se venden 2/h (más por la tarde)."""
    filas_por_ts = []
    for h in range(dias * 24):
        ts = inicio + timedelta(hours=h)
        hora_local = ts.astimezone(a.ZONA).hour
        precio = 100
        if hora_local == 5:
            precio = 80
        elif hora_local == 21:
            precio = 130
        vendidas = 4 if 18 <= hora_local <= 22 else 2
        fila_h = {"ts": ts.strftime("%Y-%m-%dT%H:%M:%SZ"), "casa": 110, "tipo": "c", "item": HIERBA,
                  "n": 10, "cant": 200, "min": precio - 5, "p10": precio, "p25": precio + 5, "p50": precio + 10,
                  "nuevas": vendidas, "vend_seg": vendidas, "vend_prob": 0, "valor_vend": vendidas * 110,
                  "retiradas": 0, "caducadas": 0, "horas": "" if h == 0 else 1.0}
        fila_p = dict(fila_h, item=POCION, min=900, p10=950, p25=1000, p50=1100,
                      vend_seg=1, valor_vend=1000, nuevas=1)
        ruta = dir_datos / ts.strftime("%Y/%m/%d") / f"{ts:%Y%m%dT%H%M}_casa110_c.csv.gz"
        r.escribir_csv(ruta, [fila_h, fila_p])
        filas_por_ts.append(ts)
    return filas_por_ts


class PruebasAnalisis(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dd = Path(self.tmp.name) / "datos"
        self.inicio = datetime(2026, 11, 20, 0, 21, tzinfo=timezone.utc)
        self.tss = simular(self.dd, 5, self.inicio)
        self.ahora = self.tss[-1] + timedelta(minutes=10)
        self.res = a.analizar(self.dd, 110, ahora=self.ahora)

    def tearDown(self):
        self.tmp.cleanup()

    def test_horas_baratas_y_caras(self):
        h = self.res["items"][HIERBA]
        self.assertEqual(h["bh"], 5)
        self.assertEqual(h["sh"], 21)
        self.assertGreater(h["ab"], 10)

    def test_ventas_y_precio_real(self):
        h = self.res["items"][HIERBA]
        # 19 h a 2/h + 5 h a 4/h = 58 al día
        self.assertAlmostEqual(h["vd"], 58, delta=3)
        self.assertEqual(h["pv"], 110)
        self.assertEqual(self.res["items"][POCION]["pv"], 1000)

    def test_precio_compra_24h(self):
        self.assertEqual(self.res["items"][HIERBA]["cmp"], 100)
        self.assertEqual(self.res["items"][HIERBA]["min"], 95)

    def test_recetas_y_lua(self):
        estaticos = {
            "profesiones": [{"id": 171, "nombre": "Alquimia", "niveles": [{"id": 1, "nombre": "Alquimia"}]}],
            "recetas": {"2330": {"prof": 171, "nombre": "Poción de curación menor", "item": POCION, "cant": 1,
                                 "reag": [[HIERBA, 2], [VIAL, 1]]}},
            "items": {str(VIAL): {"n": "Vial vacío", "compra": 20, "lote": 5},
                      str(POCION): {"n": "Poción de curación menor", "venta": 5},
                      str(HIERBA): {"n": "Flor de paz"}},
        }
        vendedor = a.precios_vendedor(estaticos, {})
        self.assertEqual(vendedor[VIAL], 4)
        recetas = a.calcular_recetas(estaticos, self.res["items"], vendedor)
        self.assertEqual(len(recetas), 1)
        rec = recetas[0]
        self.assertEqual(rec["coste"], 2 * 100 + 4)
        self.assertEqual(rec["venta"], 950)          # 1000 menos el 5 % de la subasta
        self.assertEqual(rec["beneficio"], 950 - 204)
        self.assertEqual(rec["donde"], "real")
        ruta = Path(self.tmp.name) / "Datos.lua"
        a.escribir_lua(ruta, self.res, recetas, estaticos)
        texto = ruta.read_text("utf-8")
        self.assertIn("ForeverSubastasDatos = {", texto)
        self.assertIn('"Poción de curación menor"', texto)
        self.assertIn("[171]=\"Alquimia\"", texto)

    def test_mercado_general(self):
        precio_h = self.res["mercado"]["precio_h"]
        self.assertEqual(min(range(24), key=lambda h: precio_h[h] or 9), 5)


if __name__ == "__main__":
    unittest.main()
