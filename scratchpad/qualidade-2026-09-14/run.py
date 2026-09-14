#!/usr/bin/env python3
"""Compila um medidor isolado usando os objetos do swift build -c release."""
import argparse
import subprocess
import tempfile
from pathlib import Path

here = Path(__file__).resolve().parent
root = here.parent.parent
parser = argparse.ArgumentParser()
parser.add_argument("tool", choices=["measure", "confirm", "render", "endtoend"])
parser.add_argument("args", nargs="*")
a = parser.parse_args()
source = {"measure": "Measure.swift", "confirm": "Confirm.swift", "render": "Render.swift", "endtoend": "EndToEnd.swift"}[a.tool]
build = root / ".build/arm64-apple-macosx/release"
objects = (build / "tradutor-verify.product/Objects.LinkFileList").read_text().splitlines()
nemo = root / ".build/artifacts/fluidaudio/NemoTextProcessing/NemoTextProcessing.xcframework/macos-arm64_x86_64"
with tempfile.TemporaryDirectory(prefix="tradutor-qualidade-build-") as tmp:
    tmp = Path(tmp)
    response = tmp / "objects.txt"
    response.write_text("\n".join(p for p in objects if "/tradutor_verify.build/" not in p) + "\n")
    exe = tmp / ("tradutor-qualidade-" + a.tool)
    command = ["swiftc", "-target", "arm64-apple-macosx15.0", "-parse-as-library", "-O", "-I", str(build / "Modules"),
               "-I", str(nemo / "Headers"), "-L", str(nemo), "-ltext_processing_rs"]
    for name in ["FastClusterWrapper", "MachTaskSelfWrapper"]:
        headers = root / ".build/checkouts/FluidAudio/Sources" / name / "include"
        command += ["-Xcc", "-fmodule-map-file=" + str(headers / "module.modulemap"), "-I", str(headers)]
    command += [str(here / source), "@" + str(response), "-lc++", "-o", str(exe)]
    subprocess.run(command, cwd=root, check=True)
    subprocess.run([str(exe), *a.args], cwd=root, check=True)
