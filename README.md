# Timbre

EQ de sistema para macOS, na barra de menus. Sem driver: usa process taps do Core Audio (macOS 14.2+).

Recursos: EQ paramétrico (até 24 bandas) com analisador de espectro, volume por app, sala simulada (reverb), plugins Audio Unit, preset por saída e limitador fixo no fim da cadeia.

```
apps ─► taps (global + 1 por app com volume próprio) ─► aggregate device ─► IOProc
IOProc ─► AVAudioEngine (render manual): EQ → plugins → sala → limitador ─► saída padrão
```

## Uso

```bash
./scripts/bundle.sh          # gera build/Timbre.app (assinatura ad hoc)
open build/Timbre.app
.build/release/Timbre --selftest
```

Diagnóstico: `open --env TIMBRE_DEBUG=1 --stderr /caminho/log build/Timbre.app` registra os taps e o pico do sinal.

Configuração: `~/Library/Application Support/Timbre/settings.json`.

## Limites conhecidos

- Assinatura ad hoc: cada build novo pode pedir a permissão de áudio de novo.
- Não rode junto com o eqMac: ele vira a saída padrão e o áudio passa por dois EQs.
- A curva desenhada usa as fórmulas RBJ; o `AVAudioUnitEQ` pode diferir um pouco.
- Um plugin que não aceita estéreo Float32 pode derrubar o app ao montar a cadeia.
