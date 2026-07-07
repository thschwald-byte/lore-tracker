#!/usr/bin/env python3
"""
Issue #679: pdeathsig-Wrapper für Sidecar-uvicorns.

Wenn der BEAM ordentlich beendet, ruft `Worker.Sidecar.terminate/2` den
uvicorn-Kindprozess per SIGTERM. Aber wenn der BEAM CRASHT oder SIGKILL bekommt
(kein `terminate/2`, Session-Fenster geschlossen, `kill -9 beam.smp`), wird
uvicorn reparented auf PID 1 und läuft weiter — hält Modell + VRAM. Über einen
Nachmittag Eval-Läufe sammeln sich Kopien an, GPU füllt sich.

Dieser Shim setzt `PR_SET_PDEATHSIG=SIGTERM` vor `execvp`: der Linux-Kernel
schickt uvicorn SIGTERM SOFORT wenn der Parent (BEAM / erl_child_setup) stirbt.
Portable auf Linux; auf anderen POSIX-Systemen fällt es auf ein reines execvp
zurück (Verhalten wie vorher, kein Regression).

Usage:  pdeathsig_exec.py <program> [args...]
"""

import os
import sys


def _install_pdeathsig() -> None:
    # Linux-spezifisch. Auf anderen OSes (macOS, BSD) hat prctl keinen
    # PR_SET_PDEATHSIG — dann bleibt der Shim ein reiner execvp-Wrapper.
    if sys.platform != "linux":
        return

    try:
        import ctypes

        libc = ctypes.CDLL("libc.so.6", use_errno=True)
        # PR_SET_PDEATHSIG = 1, SIGTERM = 15
        rc = libc.prctl(1, 15, 0, 0, 0)
        if rc != 0:
            errno = ctypes.get_errno()
            sys.stderr.write(
                f"pdeathsig_exec: prctl(PR_SET_PDEATHSIG) failed (errno={errno}) — continuing\n"
            )
    except OSError as e:
        # libc nicht ladbar — fällt auf reines execvp zurück.
        sys.stderr.write(f"pdeathsig_exec: libc load failed ({e}) — continuing\n")


def main(argv: list[str]) -> None:
    if len(argv) < 2:
        sys.stderr.write("usage: pdeathsig_exec.py <program> [args...]\n")
        sys.exit(2)

    _install_pdeathsig()
    program = argv[1]
    os.execvp(program, argv[1:])


if __name__ == "__main__":
    main(sys.argv)
