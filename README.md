# km-conf

Editor de arquivos de configuração nativo para Mac: **TOML**, **JSON**, **JSONC**
(JSON com comentários e vírgula final, o de `tsconfig.json` e `.vscode/settings.json`)
e **.env** (variáveis de ambiente `CHAVE=valor`).
Abre o arquivo pelo Finder (duplo clique ou "Abrir com"), mostra cada valor num
campo do tipo certo e, ao salvar, troca no arquivo **só os trechos dos valores
alterados**: comentários, ordem, espaços, aspas, escapes, forma dos números, CRLF
e BOM ficam exatamente como estavam.

Swift/AppKit + SwiftUI, sem dependências. Os leitores são próprios (precisam saber
a posição de cada valor no texto): o de TOML 1.0 passa na suíte oficial
[toml-test](https://github.com/toml-lang/toml-test); o de JSON passa na
[JSONTestSuite](https://github.com/nst/JSONTestSuite) (todos os `y_` aceitos, todos
os `n_` recusados; os `i_` estão em [Limitações](#json-e-jsonc)). O de `.env` segue
as regras do `dotenv` (Node/Ruby), escritas em [Regras do .env](#regras-do-env).

Parte do ecossistema de utilitários `km-*` (ver também `km-clip`). Chamava-se
`km-toml`; o nome mudou porque o plano é editar vários formatos. Hoje: TOML, JSON,
JSONC e .env. Planejados: INI e YAML (ver [Próximos formatos](#próximos-formatos)).

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
open -a "$PWD/km-conf.app" exemplos/config.json
open -a "$PWD/km-conf.app" exemplos/config.jsonc
open -a "$PWD/km-conf.app" exemplos/.env
# ou
open km-conf.app --args exemplos/config.toml
```

O formato vem do nome do arquivo: extensão `.toml`, `.json` ou `.jsonc`; e `.env`
para o arquivo chamado exatamente `.env`, para `.env.qualquer-coisa` (`.env.local`,
`.env.production`) e para `qualquer-coisa.env` (`producao.env`). O nome conta mais
que o tipo que o macOS dá ao arquivo: para `.env` o sistema devolve extensão vazia e
o tipo genérico `public.data`, e para `.env.local`, a extensão `local` (há um teste
que confere isso). Arquivos `.json` também podem ter comentários e vírgula final
(como o `tsconfig.json`); o app reconhece e mostra "JSONC" no modo Texto.

No painel de abrir (⌘O), todo arquivo pode ser escolhido; arquivos que começam com
ponto (`.env`) ficam ocultos no painel até ⌘⇧. (Comando-Shift-ponto).

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

O app declara que edita `.toml` (tipo `public.toml`), `.json` (`public.json`),
`.jsonc` e `.env` (o macOS não declara estes; o app declara
`br.com.kogut.km-conf.jsonc` e `br.com.kogut.km-conf.env`, derivados de texto puro),
mas **não** se registra como padrão. O tipo `.env` declarado só cobre nomes como
`producao.env`: `.env` e `.env.local` não têm extensão `env` para o sistema, então o
Finder não os associa ao km-conf; abra-os pelo `open -a`, pelo ⌘O do app ou
arrastando para o ícone. Para associar uma extensão:

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

### .env

- Todo valor é texto e não há seções: o formulário mostra uma seção só, "Variáveis".
  Um comentário `a | b | c` vira escolha, como no TOML.
- Linha que o leitor não entende é erro (com linha e coluna), em vez de ser
  ignorada como no `dotenv`: assim nada some ao gravar. Chave repetida também é
  erro, para não editar a variável errada.
- Valor de várias linhas: só entre aspas. Ao editar, o trecho novo usa `\n` (aspas
  duplas) ou a quebra do arquivo (aspas simples que já ocupavam várias linhas).
- A coloração do modo Texto é por linha; valores entre aspas de várias linhas
  ficam coloridos só na primeira.
- Criar ou apagar variáveis: pelo modo Texto.

### Regras do .env

Não há norma oficial; estas são as regras exatas que o km-conf aceita, escolhidas
pelo que o `dotenv` do Node e o do Ruby fazem em comum.

- Arquivo em UTF-8, com ou sem BOM; quebras LF ou CRLF (mantidas ao gravar).
  CR sozinho é erro.
- Cada linha é uma destas:
  - em branco (só espaços e tabulações);
  - comentário: `#` no começo (espaços antes são permitidos);
  - `CHAVE=valor`, com `export ` opcional na frente, espaços e tabulações
    opcionais no começo da linha e em volta do `=`.
- Chave: letras ASCII, dígitos, `_`, `.` e `-` (`[A-Za-z0-9_.-]+`). `export=1` é a
  variável `export`; `export A=1` é a variável `A`.
- Valor sem aspas: vai até o primeiro `#` ou o fim da linha; espaços e tabulações
  nas pontas não fazem parte dele (`A = x y  # c` → `x y`). O `#` começa o
  comentário mesmo colado (`A=abc#def` → `abc`, como no `dotenv`). Valor vazio
  (`A=`) é texto vazio.
- `'aspas simples'`: literal, sem escapes; pode ter `#` e ocupar várias linhas.
- `"aspas duplas"`: escapes `\n` (quebra de linha), `\r`, `\"` e `\\`; qualquer
  outra barra fica como está (`"c:\pasta"` → `c:\pasta`). Pode ocupar várias linhas.
- Dentro de aspas, uma quebra CRLF vale como `\n` (como no `dotenv`).
- Depois das aspas, só espaços e um comentário `#` opcional.
- Crase (`` ` ``) não é aspas: `` A=`x` `` é o texto `` `x` ``.
- `${VAR}` e `$VAR` **não** são expandidos: são texto.
- Comentários em linhas próprias logo acima da variável (sem linha em branco no
  meio) e o comentário no fim da linha viram a ajuda do campo.

Ao gravar, o tipo de aspas se mantém:

- sem aspas continua sem aspas se o valor novo couber: vazio, ou sem espaço,
  tabulação, `#`, aspas (`"`, `'`, `` ` ``) nem caracteres de controle. Se não
  couber, aspas duplas;
- aspas simples continuam simples se o valor não tiver `'` nem CR (e quebra de
  linha só se o original já tinha); senão, aspas duplas;
- aspas duplas continuam duplas: o começo e o fim que não mudaram são copiados
  byte a byte, e o trecho novo escapa só `\`, `"`, quebra de linha e CR.

### Próximos formatos

A parte própria de cada formato fica em `Formato.swift` (qual leitor, qual escritor
e o que o formato não aceita) e em um par `LeitorX.swift`/`FormatarX.swift`; `Gravar`,
`Edicao`, `Campos` e a interface já são comuns. Para acrescentar um formato:

- **INI**: falta escolher um dialeto (não há norma: `;` ou `#`, `:` ou `=`, seções
  aninhadas com ponto, aspas, continuação de linha, chaves repetidas) e escrever o
  leitor. O resto (seções `[x]` → `Cabecalho`, valores texto) já existe.
- **YAML**: leitor grande (estilos de bloco e de fluxo, âncoras, tags, textos `|` e
  `>`, vários documentos); a gravação de listas que mudam de tamanho precisaria de
  um escritor de bloco próprio, porque `Formatar.lista` só sabe listas `[ … ]`.

### Mudanças de nome no código (para quem usa o `ConfCore`)

Os nomes antigos continuam valendo como apelidos:

| antes | agora |
|---|---|
| `DocumentoTOML` | `DocumentoConf` (com `formato`, `valorRaiz` e `nomeFormato`; `raiz` ainda é a `Tabela`) |
| `EdicaoTOML(bytes)` | `Edicao(bytes, formato:)` (`.toml` por padrão) |
| `ErroTOML` | `ErroLeitura` (com `formato`; a mensagem diz "TOML inválido" ou "JSON inválido") |

Também: `Formato` (`.toml`, `.json`, `.env`) despacha ler, ler um valor e escrever,
e `Formato(nomeArquivo:)` escolhe pelo nome;
`Gravar.aplicar(bytes, alteracoes:, formato:)`; `Valor.nulo`; `TipoCampo.cru.nome`
é "texto cru" e `nome(em: formato)` dá "TOML" ou "JSON".

## Organização

```
Package.swift
Sources/ConfCore/      leitores, modelo e gravação (sem interface)
  Formato.swift        TOML, JSON ou .env: qual leitor e qual escritor usar
  Leitor.swift         TOML 1.0 → estrutura, com intervalo de bytes de cada valor
  LeitorJSON.swift     JSON/JSONC → estrutura, com intervalos e comentários
  Gravar.swift         troca só os trechos alterados, no estilo original (TOML)
  FormatarJSON.swift   escreve valores JSON no estilo do original
  LeitorEnv.swift      .env → estrutura, com intervalos e comentários
  FormatarEnv.swift    escreve valores .env mantendo o tipo de aspas
  Campos.swift         estrutura → seções e campos da tela
  Edicao.swift         estado de um arquivo aberto; diferença por linhas
  Modelo.swift         tipos (Valor, DataHora, Entrada, DocumentoConf, …)
Sources/km-conf/       o app (NSDocument + SwiftUI)
Tests/ConfCoreTests/   suítes toml-test e JSONTestSuite (Fixtures/, licença MIT),
                       tsconfig.json de exemplo, arquivos .env (Fixtures/env/)
                       e testes de gravação
exemplos/config.toml
exemplos/config.json
exemplos/config.jsonc
exemplos/.env
```

### Diagnóstico sem teclado

```sh
KM_CONF_AUTOTESTE="/tmp/x/config.toml|/tmp/x/saida" km-conf.app/Contents/MacOS/km-conf
KM_CONF_AUTOTESTE="/tmp/x/config.json|/tmp/x/saida-json" km-conf.app/Contents/MacOS/km-conf
KM_CONF_AUTOTESTE="/tmp/x/config.jsonc|/tmp/x/saida-jsonc" km-conf.app/Contents/MacOS/km-conf
KM_CONF_AUTOTESTE="/tmp/x/.env|/tmp/x/saida-env" km-conf.app/Contents/MacOS/km-conf
```

O arquivo precisa ser uma cópia de `exemplos/config.toml`, `exemplos/config.json`,
`exemplos/config.jsonc` ou `exemplos/.env` (o roteiro conta com os campos deles; a
cópia do `.env` pode se chamar `.env`, `.env.local` ou `algo.env`). Abre a **cópia** (ele é alterado e depois restaurado), altera três
valores pelo mesmo caminho dos controles, salva, desfaz, testa o modo Texto e a
recarga por mudança externa, e grava `relatorio.txt` e fotos da janela na pasta
de saída.
