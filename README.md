# km-conf

Editor de arquivos de configuração nativo para Mac: **TOML**, **JSON** e **JSONC**
(JSON com comentários e vírgula final, o de `tsconfig.json` e `.vscode/settings.json`).
Abre o arquivo pelo Finder (duplo clique ou "Abrir com"), mostra cada valor num
campo do tipo certo e, ao salvar, troca no arquivo **só os trechos dos valores
alterados**: comentários, ordem, espaços, aspas, escapes, forma dos números, CRLF
e BOM ficam exatamente como estavam.

Swift/AppKit + SwiftUI, sem dependências. Os leitores são próprios (precisam saber
a posição de cada valor no texto): o de TOML 1.0 passa na suíte oficial
[toml-test](https://github.com/toml-lang/toml-test); o de JSON passa na
[JSONTestSuite](https://github.com/nst/JSONTestSuite) (todos os `y_` aceitos, todos
os `n_` recusados; os `i_` estão em [Limitações](#json-e-jsonc)).

Parte do ecossistema de utilitários `km-*` (ver também `km-clip`). Chamava-se
`km-toml`; o nome mudou porque o plano é editar vários formatos. Hoje: TOML, JSON
e JSONC. Planejados: .env, INI e YAML.

## Compilar

```sh
./build.sh
```

Gera `km-conf.app` nesta pasta, assinado localmente (`codesign --sign -`).
Precisa do Xcode (Swift 6) e roda no macOS 14 ou mais novo. O build em release
demora alguns minutos.

Testes do núcleo (leitores, gravação, campos):

```sh
swift test
```

O núcleo (`ConfCore`) também compila e passa nos testes no Linux; lá o
`Package.swift` deixa de fora o app, que depende do AppKit:

```sh
docker run --rm -v "$PWD":/src:ro swift:6.0 \
  bash -c 'cp -r /src /tmp/w && cd /tmp/w && rm -rf .build && swift test'
```

## Usar

```sh
open -a "$PWD/km-conf.app" exemplos/config.toml
open -a "$PWD/km-conf.app" exemplos/config.jsonc
# ou
open km-conf.app --args exemplos/config.toml
```

O formato vem da extensão: `.toml`, `.json` ou `.jsonc`. Arquivos `.json` também
podem ter comentários e vírgula final (como o `tsconfig.json`); o app reconhece e
mostra "JSONC" no modo Texto.

(O `open -a` não aceita caminho relativo como `./km-conf.app`; use o caminho completo.)

Aberto sem arquivo, o app mostra o painel de abrir.

### A janela

- **Barra lateral**: a raiz do arquivo, cada `[tabela]` e cada item de
  `[[lista de tabelas]]` (agrupados pelo nome da lista; o item ganha o nome do
  campo `nome`, `name`, `titulo`, `title` ou `id`, se houver). Em JSON, cada
  objeto `{…}` aninhado é uma seção (com o caminho, como `compilerOptions.paths`)
  e uma lista só de objetos vira um grupo, com um item por objeto, como a
  `[[lista]]` do TOML. Um ponto azul marca as seções com alteração não salva.
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
    do valor, validado ao confirmar. Em JSON, o mesmo vale para listas mistas,
    listas vazias e `null` (texto JSON do valor).

  Os comentários acima da linha e no fim dela aparecem como ajuda do campo. Em
  JSONC valem `// …` e `/* … */`, acima do membro ou no fim da linha (antes ou
  depois da vírgula) — inclusive a dica de escolha `a | b | c`.
- **Texto** (⌘2): o arquivo inteiro editável, com cores simples. O texto só é
  aplicado ao documento se for válido no formato do arquivo (TOML, ou JSON/JSONC);
  enquanto não for, o erro aparece com
  linha e coluna e a linha fica marcada. Vale ao voltar para o Formulário (⌘1),
  ao clicar em Aplicar (⌘↩) ou ao salvar. As aspas "inteligentes" do macOS ficam
  desligadas. Se um JSON puro ganhar comentário ou vírgula final, o rodapé avisa
  (vale, mas nem todo programa aceita JSONC).
- **Painel de alterações** (botão à direita na barra ou ⌥⌘I): cada trecho que vai
  mudar no disco, com a linha antes e depois. Clicar leva à seção do campo.

### Salvar, desfazer, reverter

O app usa o sistema de documentos do macOS, então:

- ⌘S salva. **Antes de sobrescrever**, o arquivo como estava vai para
  `<arquivo>.bak` (`config.toml.bak`, `tsconfig.json.bak`), ao lado dele.
- ⌘Z / ⇧⌘Z desfazem e refazem cada alteração de campo e cada "Aplicar" do modo Texto.
- O título mostra "— Editado" enquanto há alteração pendente.
- Arquivo › Reverter Para volta à última versão salva (ou a versões anteriores).
- Se outro programa gravar no arquivo e não houver edição pendente, a janela
  recarrega sozinha. Se houver, o macOS avisa "alterado por outro aplicativo" ao salvar.
- Antes de gravar, o resultado é relido pelo leitor e conferido; se não for válido
  ou os valores não baterem, nada é gravado e aparece o erro. Um JSON puro não
  vira JSONC pelo formulário: um valor cru com comentário é recusado.

## Abrir com duplo clique

O app declara que edita `.toml` (tipo `public.toml`), `.json` (`public.json`) e
`.jsonc` (o macOS não declara este; o app declara `br.com.kogut.km-conf.jsonc`),
mas **não** se registra como padrão. Para isso:

1. Copie `km-conf.app` para `/Applications` (opcional, mas assim ele não depende desta pasta).
2. No Finder, selecione um arquivo da extensão › Arquivo › Obter Informações (⌘I).
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

### JSON e JSONC

- JSON5 (chaves sem aspas, aspas simples, `Infinity`, hexadecimal) não é aceito.
- Texto: as partes do começo e do fim que não mudaram são copiadas byte a byte
  (escapes inclusive); o trecho novo segue o hábito do original: `\/` se ele
  escapava a barra, `\u00e9` se escapava acentos, mesma caixa no hexadecimal.
- Número: inteiro continua inteiro; decimal continua decimal, com expoente se
  havia (`1.5e3` → `2.0e3`, mesma letra `e`/`E` e o `+`) e com pelo menos as
  mesmas casas depois do ponto (`1.50` → `2.25`, `1.50` → `3.00`). JSON não tem
  infinito nem NaN: o valor é recusado.
- Chave repetida: vale a última (como em JavaScript, Python e Go; o
  `JSONSerialization` da Apple fica com a primeira). Só a última aparece no
  formulário, e é ela que é gravada.
- Raiz que não é objeto: uma lista de objetos vira um grupo de itens; qualquer
  outro valor aparece como um campo só, "(raiz)".
- Comentários antes do `{` inicial não aparecem como ajuda (não pertencem a nenhum campo).
- Casos que a especificação deixa a critério de quem lê (`i_` da JSONTestSuite):
  - **aceitos**: números fora do alcance — inteiro que não cabe em 64 bits vira
    decimal aproximado, expoente enorme vira infinito ou zero (só são reescritos
    se o campo for editado, e infinito não pode ser gravado); BOM UTF-8 no começo
    (mantido ao gravar).
  - **recusados**: arquivo que não é UTF-8 (ISO-8859-1, UTF-16, sequências
    inválidas); escape `\u` de surrogate sem par (`"\uD800"`), que não cabe num
    texto Unicode válido; mais de 128 níveis de listas/objetos um dentro do outro.

### Mudanças de nome no código (para quem usa o `ConfCore`)

Os nomes antigos continuam valendo como apelidos:

| antes | agora |
|---|---|
| `DocumentoTOML` | `DocumentoConf` (com `formato`, `valorRaiz` e `nomeFormato`; `raiz` ainda é a `Tabela`) |
| `EdicaoTOML(bytes)` | `Edicao(bytes, formato:)` (`.toml` por padrão) |
| `ErroTOML` | `ErroLeitura` (com `formato`; a mensagem diz "TOML inválido" ou "JSON inválido") |

Também: `Formato` (`.toml`, `.json`) despacha ler, ler um valor e escrever;
`Gravar.aplicar(bytes, alteracoes:, formato:)`; `Valor.nulo`; `TipoCampo.cru.nome`
é "texto cru" e `nome(em: formato)` dá "TOML" ou "JSON".

## Organização

```
Package.swift
Sources/ConfCore/      leitores, modelo e gravação (sem interface)
  Formato.swift        TOML ou JSON: qual leitor e qual escritor usar
  Leitor.swift         TOML 1.0 → estrutura, com intervalo de bytes de cada valor
  LeitorJSON.swift     JSON/JSONC → estrutura, com intervalos e comentários
  Gravar.swift         troca só os trechos alterados, no estilo original (TOML)
  FormatarJSON.swift   escreve valores JSON no estilo do original
  Campos.swift         estrutura → seções e campos da tela
  Edicao.swift         estado de um arquivo aberto; diferença por linhas
  Modelo.swift         tipos (Valor, DataHora, Entrada, DocumentoConf, …)
Sources/km-conf/       o app (NSDocument + SwiftUI)
Tests/ConfCoreTests/   suítes toml-test e JSONTestSuite (Fixtures/, licença MIT),
                       tsconfig.json de exemplo e testes de gravação
exemplos/config.toml
exemplos/config.jsonc
```

### Diagnóstico sem teclado

```sh
KM_CONF_AUTOTESTE="/tmp/x/config.toml|/tmp/x/saida" km-conf.app/Contents/MacOS/km-conf
KM_CONF_AUTOTESTE="/tmp/x/config.jsonc|/tmp/x/saida-json" km-conf.app/Contents/MacOS/km-conf
```

O arquivo precisa ser uma cópia de `exemplos/config.toml` ou `exemplos/config.jsonc`
(o roteiro conta com os campos deles). Abre a **cópia** (ele é alterado e depois restaurado), altera três
valores pelo mesmo caminho dos controles, salva, desfaz, testa o modo Texto e a
recarga por mudança externa, e grava `relatorio.txt` e fotos da janela na pasta
de saída.
