# Ideia arquivada: biblioteca Rust multi-formato para editar configuração sem perda

**Situação:** arquivada em 2026-10-10. Nenhum código foi escrito.
**Decisão:** o km-conf segue como **app visual multi-formato** (Swift). A biblioteca
em Rust não segue.
**Origem:** bloco "Núcleo em Rust" do Sitroom: missão de pesquisa `941f79c0` e
missão de experimento `c12e0096`. O experimento foi cancelado antes de começar.

Este documento guarda a ideia, a pesquisa e o desenho do experimento para que
alguém possa retomá-la se surgir um fato novo, sem refazer o caminho.

## A ideia

Uma biblioteca open-source escrita inteiramente em Rust que lê, edita e grava
vários formatos de configuração (TOML, JSON/JSONC e, mais tarde, YAML, INI e .env)
**sem perder comentários nem formatação**. Ao gravar, ela troca só os bytes dos
valores alterados, que é a mesma garantia do núcleo `Sources/ConfCore` do km-conf.

A premissa tinha duas metades:

1. não existe biblioteca só em Rust, multi-formato e sem perda (e em especial
   não existe edição de JSON/JSONC sem perda em Rust);
2. há gente que quer uma.

## Por que foi arquivada

A pesquisa (missão `941f79c0`, dados consultados em 2026-10-10) derrubou a
primeira metade:

- **[edikt](https://github.com/jhheider/edikt)** é exatamente o produto imaginado:
  Rust puro, 7 formatos (JSONC/JSON5, TOML, YAML, INI, KDL, .env/.properties,
  frontmatter), edição "byte for byte", lançado em julho de 2026. Por dentro usa
  `toml_edit` e `kdl-rs`.
- **[jsonc-parser](https://crates.io/crates/jsonc-parser)** (do dprint), com a feature
  `cst`, já edita JSONC sem perda ("keeps every comment and every piece of
  whitespace"). Tem 11,3 milhões de downloads e o Deno o usa para editar o
  `deno.json` em `deno add` e `deno bump-version`. O "buraco do JSON" não existe.
- **[toml_edit](https://crates.io/crates/toml_edit)** resolve TOML há anos (892
  milhões de downloads).

A segunda metade fica de pé com ressalva: a dor de perder comentários é real e
antiga (yq [#515](https://github.com/mikefarah/yq/issues/515) com 156 👍, dasel
[#178](https://github.com/TomWright/dasel/issues/178), jq
[#1571](https://github.com/jqlang/jq/issues/1571)). Mas os pedidos são por
ferramentas de linha de comando, não por uma biblioteca Rust. As bibliotecas
multi-formato que já existem têm adoção quase nula: edikt com 336 downloads e 3★,
fig com 3,4 mil downloads e 11★, cada uma mantida por uma pessoa só.

Um protótipo com TOML e JSON repetiria o que `toml_edit` e `jsonc-parser` já
fazem, e o que o edikt já junta por cima deles.

Em compensação, a pesquisa **não achou nenhum app visual multi-formato** que grave
só os bytes alterados. Os concorrentes do app são de um formato só: Power TOML
Editor, JSON Editor (VDT Labs) e Tommy Flyleaf (TOML, Rust + egui). Daí a decisão
de investir no app.

## Panorama dos concorrentes (2026-10-10)

As colunas "preserva bytes?" repetem o que cada projeto declara: **nenhum deles foi
testado**.

| Nome | Linguagem | Formatos | Preserva bytes? | Downloads (crates.io) | Última versão | Licença |
|---|---|---|---|---|---|---|
| [fig](https://crates.io/crates/fig) / fig-sys | Zig, com ponte Rust | JSON/JSONC/JSON5, YAML, TOML, INI, .env, .properties, plist, NestedText, ZON | Diz que sim | 3.459 / 3.246 | v5.2.0, 2026-10-03 | MIT OR Apache-2.0 |
| [edikt](https://crates.io/crates/edikt) | Rust puro | JSONC/JSON5, TOML, YAML, INI, KDL, .env/.properties, frontmatter | Diz que sim | 336 (edikt-core: 14.538) | v0.8.1, 2026-09-29 | MIT OR Apache-2.0 |
| [patchloom](https://crates.io/crates/patchloom) | Rust | JSON, YAML, TOML (voltado a agentes de IA) | Diz preservar comentários; sem garantia byte a byte | 1.505 | v0.37.1, 2026-10-08 | MIT OR Apache-2.0 |
| [jsonc-parser](https://crates.io/crates/jsonc-parser) (`cst`) | Rust | JSON/JSONC | Sim | 11.300.339 | 0.34.0, 2026-09-27 | MIT |
| [json-five](https://crates.io/crates/json-five) | Rust | JSON5 | Diz "round-trip"; não verificado | 1.248.735 | 0.3.1, 2026-01-08 | MIT |
| [toml_edit](https://crates.io/crates/toml_edit) | Rust | TOML | Sim | 892.019.968 | 0.25.17, 2026-10-09 | MIT OR Apache-2.0 |
| [yaml-edit](https://crates.io/crates/yaml-edit) | Rust | YAML | Diz "lossless" | 152.999 | 0.3.2, 2026-09-17 | Apache-2.0 |
| [yamlpatch](https://crates.io/crates/yamlpatch) | Rust | YAML | Diz preservar comentários e formato | 354.622 | 1.30.1, 2026-09-09 | MIT |
| ini-roundtrip / ini-preserve / ini-edit | Rust | INI | Dizem que sim | 46.458 / 1.604 / 253 | 2025-12 a 2026-10 | MIT |
| [envq](https://crates.io/crates/envq) | Rust | .env | Diz "byte-preserving" | 479 | 0.1.4, 2026-09-20 | BSD-3-Clause |
| [Augeas](https://github.com/hercules-team/augeas) | C | formatos de `/etc` | Sim, mas com bugs abertos em TOML (#715, #699) | — | push em 2026-09-29 | LGPL-2.1 |
| dasel / yq | Go | vários | Não garantem | — | 2026 | MIT |

Sobre o **fig**: a ponte Rust é completa (editar, inserir, remover, renomear,
mover chaves, mexer em comentários), mas depende de uma biblioteca nativa em Zig
pré-compilada só para macOS arm64, Linux x64/arm64 (gnu), Windows x64, wasm32 e
iOS. Mac Intel e Linux musl ficam de fora.

Relatório completo da pesquisa: cartão `941f79c0` no Sitroom
(`~/.sitroom/tasks/closed/941f79c0.json`).

## O experimento que estava planejado (missão `c12e0096`)

Era um experimento de uma tarde, para decidir se a ideia continuava. Fica
registrado aqui caso seja retomado.

- **Onde:** pasta local nova, `~/Kogumelo/Ferramentas/km-conf-rs`, com `git init`.
  Nada no GitHub nem no crates.io sem o operador autorizar. O projeto Swift não
  seria tocado.
- **API mínima, igual para os dois formatos:** abrir a partir dos bytes; ler um
  valor por caminho (`servidor.porta`, `itens[2].nome`); mudar o valor de um
  caminho existente; gravar devolvendo os bytes.
- **TOML:** em cima do `toml_edit`, sem reescrever o leitor.
- **JSON/JSONC:** leitor próprio sem perda (comentários `//` e `/* */`, vírgula
  final opcional, espaços e ordem preservados; ao mudar um valor, só o trecho dele
  muda).
- **Testes:**
  - toml-test (copiar `Tests/ConfCoreTests/Fixtures` do km-conf): válidos aceitos,
    inválidos recusados e abrir/gravar sem mudança idêntico byte a byte;
  - JSON: casos com comentários, CRLF, BOM, escapes Unicode, números grandes e
    decimais, mais a [JSONTestSuite](https://github.com/nst/JSONTestSuite);
  - os mesmos arquivos e edições pelo pacote `fig`, registrando onde cada um
    preserva melhor ou pior.
- **Critério de sucesso (os três juntos):** toml-test inteiro passando; JSONC
  preservado byte a byte depois de editar um valor em todos os casos; e **uma
  vantagem concreta e medida sobre o fig** (um caso em que o fig perde bytes e
  este não, ou API, tamanho, compilação para WebAssembly). Sem vantagem medida,
  arquivar.
- **Fora do escopo:** YAML, INI, .env, ponte com Swift, ferramenta de terminal,
  inserir ou remover chaves, publicação.

Com o que a pesquisa mostrou, o experimento deveria comparar contra **edikt e
jsonc-parser**, não só contra o fig. Escrever um leitor JSONC próprio em Rust não
faz sentido: o `jsonc-parser` já faz isso.

## O que faria a ideia voltar

Reabrir só com um fato novo, por exemplo:

- um teste comparativo mostrar que edikt e fig **perdem bytes** em casos de borda
  (a suíte toml-test, a JSONTestSuite, arquivos com CRLF, BOM, escapes) e que
  `toml_edit` + `jsonc-parser` não resolvem esses casos;
- o edikt ou o fig serem abandonados e houver gente usando;
- o app km-conf precisar rodar fora do Mac (Linux, Windows, navegador via
  WebAssembly), o que tornaria um núcleo portável em Rust útil para o próprio app;
- pedidos explícitos por uma biblioteca assim (issues, discussões), coisa que a
  pesquisa não encontrou.

A vantagem que o km-conf já tem e que nenhum concorrente publica é a
**conformidade verificada contra suítes oficiais** (toml-test e JSONTestSuite). Se
a ideia voltar, é por aí que ela se diferencia, não por ser a primeira.

## Referências

Todos os links citados no relatório da missão `941f79c0`, consultados em
2026-10-10.

**fig**
- Pacotes: <https://crates.io/crates/fig>, <https://crates.io/crates/fig-sys>,
  <https://docs.rs/crate/fig>; dados de downloads: <https://crates.io/api/v1/crates/fig>
- Repositório e README ("Every other byte is preserved"): <https://github.com/diaryx-org/fig>
- API da ponte Rust: <https://github.com/diaryx-org/fig/blob/main/bindings/rust/fig/src/editor.rs>
- Alvos pré-compilados: <https://github.com/diaryx-org/fig/blob/main/bindings/rust/fig-sys/Cargo.toml>
- Única issue ("Nightly fuzz run failed"): <https://github.com/diaryx-org/fig/issues/1>
- Apresentação: <https://ziggit.dev/t/fig-convert-yaml-toml-jsonc-preserve-comments/16555>

**Outras bibliotecas**
- edikt: <https://crates.io/crates/edikt>, <https://github.com/jhheider/edikt>,
  <https://crates.io/crates/edikt-yaml>; quem puxa o edikt-core: <https://crates.io/crates/asimov-cli>
- patchloom: <https://crates.io/crates/patchloom>, <https://github.com/patchloom/patchloom>
- jsonc-parser: <https://crates.io/crates/jsonc-parser>,
  <https://docs.rs/jsonc-parser/latest/jsonc_parser/cst/index.html>,
  <https://docs.rs/jsonc-parser/latest/jsonc_parser/cst/struct.CstObject.html>
- Uso no Deno: <https://github.com/denoland/deno/blob/main/cli/tools/pm/mod.rs>,
  <https://github.com/denoland/deno/blob/main/cli/tools/bump_version.rs>
- JSON5: <https://crates.io/crates/json-five>, <https://crates.io/crates/json5format>,
  <https://crates.io/crates/monochromatic-jsonc-edit>
- TOML: <https://crates.io/crates/toml_edit>
- YAML: <https://crates.io/crates/yaml-edit>, <https://crates.io/crates/yamlpatch>
- INI: <https://crates.io/crates/ini-roundtrip>, <https://crates.io/crates/ini-preserve>,
  <https://crates.io/crates/ini-edit>
- .env: <https://crates.io/crates/envq>
- Augeas: <https://github.com/hercules-team/augeas>,
  <https://github.com/hercules-team/augeas/issues/715>,
  <https://github.com/hercules-team/augeas/issues/699>
- dasel e yq: <https://github.com/TomWright/dasel>, <https://github.com/mikefarah/yq>

**Sinais de demanda**
- yq: <https://github.com/mikefarah/yq/issues/515>, <https://github.com/mikefarah/yq/issues/19>,
  <https://github.com/mikefarah/yq/issues/442>, <https://github.com/mikefarah/yq/issues/2592>,
  <https://github.com/mikefarah/yq/issues/2536>
- dasel: <https://github.com/TomWright/dasel/issues/178>
- jq: <https://github.com/jqlang/jq/issues/1571>
- Renovate: <https://github.com/renovatebot/renovate/issues/12260>,
  <https://github.com/renovatebot/renovate/pull/38646>
- Zed: <https://github.com/zed-industries/zed/issues/40270>
- Downloads semanais fora do Rust: <https://api.npmjs.org/downloads/point/last-week/jsonc-parser>,
  <https://pypistats.org/api/packages/tomlkit/recent> (comment-json e ruamel.yaml
  vieram das mesmas APIs)
- Hacker News, "Show HN: Yqr": <https://news.ycombinator.com/item?id=48871455>
- Blog "Respectful" YAML Patching in Rust: <https://verrchu.github.io/blog/2-respectful-yaml-patching-in-rust/>

**Apps visuais**
- Power TOML Editor: <https://apps.apple.com/us/app/id1587914025>
  (data da versão: <https://www.iphoneaddict.fr/apps/mac/developpeurs/power-toml-editor.html>)
- JSON Editor (VDT Labs): <https://apps.apple.com/us/app/json-editor/id567740330?mt=12>
- Tommy Flyleaf: <https://github.com/excelano/flyleaf>
- Power YAML Editor: <https://apps.apple.com/us/app/id1565766176>
- Power JSON Editor: <https://apps.apple.com/app/power-json-editor/id499768540>

**Suítes de teste**
- toml-test: <https://github.com/toml-lang/toml-test>
- JSONTestSuite: <https://github.com/nst/JSONTestSuite>
