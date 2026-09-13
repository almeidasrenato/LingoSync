"""Compila somente o arnês; requer swift build -c release concluído."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[2]
build=root/'.build/release'
fluid=root/'.build/checkouts/FluidAudio'
output=Path(tempfile.gettempdir())/'tradutor-noise-bench'
args=['swiftc',str(Path(__file__).with_name('NoiseBench.swift')),'-parse-as-library','-swift-version','5','-O','-I',str(build/'Modules'),'-module-cache-path',str(Path(tempfile.gettempdir())/'tradutor-pontual-modules')]
for wrapper in ['FastClusterWrapper','MachTaskSelfWrapper']:
 include=fluid/'Sources'/wrapper/'include'
 args+=['-Xcc','-fmodule-map-file='+str(include/'module.modulemap'),'-Xcc','-I'+str(include)]
lib=root/'.build/artifacts/fluidaudio/NemoTextProcessing/NemoTextProcessing.xcframework/macos-arm64_x86_64'
args+=['-I',str(lib/'Headers'),str(lib/'libtext_processing_rs.a'),'-lc++','-o',str(output)]
objects=(build/'tradutor-verify.product/Objects.LinkFileList').read_text().splitlines()
# O @main do verificador é substituído pelo do arnês; o núcleo é o mesmo.
# O SwiftPM escreve os caminhos entre aspas SIMPLES; tirar so as duplas
# deixava a aspa no caminho e o swiftc nao achava objeto nenhum.
args+=[o.strip('"\'') for o in objects if '/tradutor_verify.build/' not in o]
subprocess.run(args,cwd=root,check=True)
print(output)
