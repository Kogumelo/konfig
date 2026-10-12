---
description: Instala o Konfig novo em /Applications — confere que o checkout está no main e limpo, roda os testes, compila com ./build.sh --install e confere o carimbo e o ícone do que foi instalado.
argument-hint: (ignorado) o Kommand passa o ref; instala-se sempre o main do checkout principal
allowed-tools: Bash
---

# /km-instalar — trocar o Konfig de /Applications pelo build do main

Use depois do merge, quando o que está no `main` precisa virar o app que o
Finder abre. É o que o botão de deploy do Kommand dispara.

Você **confere, compila e instala**. Não escreve no git: não faz merge, não
commita, não faz push. **Se um portão falhar, pare e diga qual** — não conserte
por conta própria.

O repositório é `~/Kogumelo/Ferramentas/konfig`. Os blocos abaixo chamam esse
caminho de `$R`, e todo comando roda com `-C "$R"` ou dentro de `$R` — também
quando você foi chamado de dentro de uma worktree:

```
R=~/Kogumelo/Ferramentas/konfig
```

`$ARGUMENTS` (o ref que o Kommand manda) não escolhe o que se instala: aqui o
merge já foi feito pelo botão de merge, e o que vai para /Applications é sempre
o `main` do checkout principal. Se `$ARGUMENTS` não for `main` nem vazio, avise
e siga com o `main`.

## 1. Ramo e limpeza

```
git -C "$R" branch --show-current                                              # tem que ser main
git -C "$R" diff --quiet HEAD && echo LIMPO                                    # tem que sair LIMPO
git -C "$R" status --porcelain -- Sources Resources Info.plist Package.swift icon   # tem que sair VAZIO
```

- **Fora do `main`:** pare. O rodapé do app mostra o commit de onde o build
  saiu; um build de branch põe lá um hash que o `main` não tem.
- **Arquivo versionado alterado:** pare e liste. O build sairia com `-dirty` no
  rodapé, e o app instalado não corresponderia a commit nenhum.
- **Arquivo não versionado em `Sources/` ou `Resources/`:** pare também. O
  Swift compila tudo o que está em `Sources/` e o `build.sh` copia tudo de
  `Resources/`, versionado ou não — e o `git diff` não vê esse caso, por isso o
  terceiro comando. Não versionado fora dessas pastas (anexos, `.DS_Store`) não
  entra no app e não barra nada.

## 2. Testes do núcleo

```
swift test --package-path "$R"
```

Qualquer falha = pare. (O autoteste da janela, `KONFIG_SELFTEST`, abre janelas
na tela do operador: **não** rode aqui.)

## 3. Guardar o que está instalado e instalar

```
plutil -extract KonfigCommit raw /Applications/Konfig.app/Contents/Info.plist 2>/dev/null || echo "(sem carimbo: build anterior a f2ce024)"   # guarde: ANTERIOR
"$R/build.sh" --install
```

O `--install` troca `/Applications/Konfig.app` e o registra de novo no Launch
Services, que é o que faz o "Abrir Com" do Finder pegar o ícone novo.

## 4. Conferir o que foi instalado

```
plutil -extract KonfigCommit raw /Applications/Konfig.app/Contents/Info.plist   # = hash curto do HEAD, sem -dirty
git -C "$R" rev-parse --short HEAD
ls /Applications/Konfig.app/Contents/Resources/Konfig.icns                      # tem que existir
codesign --verify /Applications/Konfig.app && echo ASSINATURA-OK
```

- carimbo diferente do HEAD, ou com `-dirty`: algo escapou do passo 1 — diga o quê;
- sem `Konfig.icns`: o "Abrir Com" volta a mostrar o quadrado branco — foi
  exatamente o defeito de 12/10/2026, quando o /Applications tinha um build de
  antes do ícone existir.

## Saída (em português)

Um bloco curto: ✅/⚠️ por portão, o commit instalado e o ANTERIOR, e o que
entrou entre os dois (`git -C "$R" log --oneline <ANTERIOR>..HEAD`, quando havia
carimbo). Se o `build.sh` avisou que o Konfig está aberto, repita o aviso: a
versão velha segue rodando até o operador fechar (⌘Q) e abrir de novo. Se o
Finder ainda mostrar o ícone antigo, a saída é `killall Finder`.
