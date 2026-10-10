# km-conf

Editor de arquivos **TOML** nativo para Mac. Abre um `.toml` pelo Finder
(duplo clique ou "Abrir com"), mostra cada valor num campo do tipo certo e, ao
salvar, troca no arquivo **só os trechos dos valores alterados**: comentários,
ordem, espaços, aspas, base dos números, CRLF e BOM ficam exatamente como
estavam.

Swift/AppKit + SwiftUI, sem dependências. O leitor de TOML 1.0 é próprio (precisa
saber a posição de cada valor no texto) e passa na suíte oficial
[toml-test](https://github.com/toml-lang/toml-test).

Parte do ecossistema de utilitários `km-*` (ver também `km-clip`). Chamava-se
`km-toml`; o nome mudou porque o plano é editar também JSON, .env, INI e YAML.
Por enquanto, só TOML.

## Compilar

```sh
./build.sh
```

Gera `km-conf.app` nesta pasta, assinado localmente (`codesign --sign -`).
Precisa do Xcode (Swift 6) e roda no macOS 14 ou mais novo. O build em release
demora alguns minutos.

Testes do núcleo (leitor, gravação, campos):

```sh
swift test
```

## Usar

```sh
open -a "$PWD/km-conf.app" exemplos/config.toml
# ou
open km-conf.app --args exemplos/config.toml
```

(O `open -a` não aceita caminho relativo como `./km-conf.app`; use o caminho completo.)

Aberto sem arquivo, o app mostra o painel de abrir.

### A janela

- **Barra lateral**: a raiz do arquivo, cada `[tabela]` e cada item de
  `[[lista de tabelas]]` (agrupados pelo nome da lista; o item ganha o nome do
  campo `nome`, `name`, `titulo`, `title` ou `id`, se houver). Um ponto azul marca
  as seções com alteração não salva.
- **Formulário**, um controle por tipo:
  - texto: caixa de texto (confirma com Return ou ao sair do campo; Esc desfaz a digitação);
  - inteiro e decimal: caixa numérica; o inteiro continua inteiro e, ao gravar,
    mantém a base (`0xff`, `0o755`, `0b1010`) e o agrupamento com `_`;
  - verdadeiro/falso: chave liga/desliga;
  - **escolha**: se o comentário acima da chave (ou no fim da linha) tiver o
    formato `a | b | c`, o texto vira uma lista de opções;
  - os 4 tipos de data/hora (com fuso, data-hora local, data, hora): seletor de
    data, respeitando o tipo; o fuso do arquivo é mantido;
  - listas simples (todos os itens do mesmo tipo): etiquetas com × para remover e
    "+ adicionar";
  - listas mistas, listas de tabelas embutidas e tabelas embutidas: o texto TOML
    do valor, validado ao confirmar.

  Os comentários acima da linha e no fim dela aparecem como ajuda do campo.
- **Texto** (⌘2): o arquivo inteiro editável, com cores simples. O texto só é
  aplicado ao documento se for TOML válido; enquanto não for, o erro aparece com
  linha e coluna e a linha fica marcada. Vale ao voltar para o Formulário (⌘1),
  ao clicar em Aplicar (⌘↩) ou ao salvar. As aspas "inteligentes" do macOS ficam
  desligadas.
- **Painel de alterações** (botão à direita na barra ou ⌥⌘I): cada trecho que vai
  mudar no disco, com a linha antes e depois. Clicar leva à seção do campo.

### Salvar, desfazer, reverter

O app usa o sistema de documentos do macOS, então:

- ⌘S salva. **Antes de sobrescrever**, o arquivo como estava vai para
  `<arquivo>.toml.bak`, ao lado dele.
- ⌘Z / ⇧⌘Z desfazem e refazem cada alteração de campo e cada "Aplicar" do modo Texto.
- O título mostra "— Editado" enquanto há alteração pendente.
- Arquivo › Reverter Para volta à última versão salva (ou a versões anteriores).
- Se outro programa gravar no arquivo e não houver edição pendente, a janela
  recarrega sozinha. Se houver, o macOS avisa "alterado por outro aplicativo" ao salvar.
- Antes de gravar, o resultado é relido pelo leitor e conferido; se não for TOML
  válido ou os valores não baterem, nada é gravado e aparece o erro.

## Abrir `.toml` com duplo clique

O app declara que edita arquivos `.toml` (tipo `public.toml`), mas **não** se
registra como padrão. Para isso:

1. Copie `km-conf.app` para `/Applications` (opcional, mas assim ele não depende desta pasta).
2. No Finder, selecione um `.toml` › Arquivo › Obter Informações (⌘I).
3. Em "Abrir com", escolha km-conf e clique em **Alterar Tudo…**.

Sem isso, ele aparece em "Abrir com" (botão direito no arquivo).

## Limitações

- Criar chaves ou tabelas não é feito pelo formulário — use o modo Texto.
- Listas de várias linhas: se a **quantidade** de itens mudar, a lista é reescrita
  com o recuo do primeiro item e a vírgula final, se havia; comentários *dentro*
  dela se perdem. Mudando só o valor de itens, todo o resto da lista fica intacto.
- Uma lista simples que vira lista mista (ou o contrário) precisa ser editada pelo modo Texto.
- O seletor de data não edita fração de segundo (ela é mantida) e não mostra o ano 0000.
- Textos de várias linhas aparecem numa caixa que cresce, mas Return confirma; para quebrar linhas com conforto, use o modo Texto.
- O macOS salva automaticamente documentos editados (ao trocar de app, fechar a
  janela etc.), como no TextEdit. Cada gravação, inclusive a automática, renova
  o `.bak` com a versão anterior.
- Sem esquema de validação, Quick Look ou comparação entre arquivos.

## Organização

```
Package.swift
Sources/ConfCore/      leitor, modelo e gravação (sem interface)
  Leitor.swift         TOML 1.0 → estrutura, com intervalo de bytes de cada valor
  Gravar.swift         troca só os trechos alterados, no estilo original
  Campos.swift         estrutura → seções e campos da tela
  Edicao.swift         estado de um arquivo aberto; diferença por linhas
  Modelo.swift         tipos (Valor, DataHora, Entrada, …)
Sources/km-conf/       o app (NSDocument + SwiftUI)
Tests/ConfCoreTests/   suíte toml-test (Fixtures/, licença MIT) e testes de gravação
exemplos/config.toml
```

### Diagnóstico sem teclado

```sh
KM_CONF_AUTOTESTE="/tmp/x/config.toml|/tmp/x/saida" km-conf.app/Contents/MacOS/km-conf
```

Abre uma **cópia** do arquivo (ele é alterado e depois restaurado), altera três
valores pelo mesmo caminho dos controles, salva, desfaz, testa o modo Texto e a
recarga por mudança externa, e grava `relatorio.txt` e fotos da janela na pasta
de saída.
