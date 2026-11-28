"""Quita del árbol del repositorio las descargas de más de DIAS_CONSERVAR días.

El análisis solo usa las últimas 4 semanas, y lo antiguo sigue en el historial de git: así cada ejecución
descarga y recorre menos ficheros aunque pasen los meses.
"""
from __future__ import annotations

import os
import shutil
from datetime import date, timedelta
from pathlib import Path

DIAS_CONSERVAR = 45


def podar(dir_datos: Path, dias: int = DIAS_CONSERVAR, hoy: date | None = None) -> list[Path]:
    hoy = hoy or date.today()
    limite = hoy - timedelta(days=dias)
    borrados = []
    for base in (dir_datos, dir_datos / "tramos"):
        for d in sorted(base.glob("[0-9][0-9][0-9][0-9]/[0-9][0-9]/[0-9][0-9]")):
            try:
                fecha = date(int(d.parent.parent.name), int(d.parent.name), int(d.name))
            except ValueError:
                continue
            if fecha < limite:
                shutil.rmtree(d)
                borrados.append(d)
        # Meses y años que se han quedado vacíos.
        for d in sorted(base.glob("[0-9][0-9][0-9][0-9]/[0-9][0-9]"), reverse=True):
            if d.is_dir() and not any(d.iterdir()):
                d.rmdir()
        for d in sorted(base.glob("[0-9][0-9][0-9][0-9]")):
            if d.is_dir() and not any(d.iterdir()):
                d.rmdir()
    return borrados


if __name__ == "__main__":
    base = Path(os.environ.get("DIR_BASE", ".")) / "datos"
    quitados = podar(base, int(os.environ.get("DIAS_CONSERVAR", DIAS_CONSERVAR)))
    print(f"Días quitados del árbol: {len(quitados)}")
