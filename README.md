# Konfig

Editor de arquivos de configuração nativo para Mac: **TOML**, **JSON**, **JSONC**
(JSON com comentários e vírgula final, o de `tsconfig.json` e `.vscode/settings.json`),
**JSON5** (chaves sem aspas, aspas simples, hexadecimal, `Infinity`…), **.env**
(variáveis de ambiente `CHAVE=valor`), **INI** (`php.ini`, `.editorconfig`, `desktop.ini`…) e **YAML**
(o subconjunto dos arquivos de configuração: docker-compose, GitHub Actions, Kubernetes, `pubspec.yaml`, OpenAPI).
Abre o arquivo pelo Finder (duplo clique ou "Abrir com"), mostra cada valor num
campo do tipo certo e, ao salvar, troca no arquivo **só os trechos dos valores
alterados**: comentários, ordem, espaços, aspas, escapes, forma dos números, CRLF
e BOM ficam exatamente como estavam.

Swift/AppKit + SwiftUI, sem dependências. Os leitores são próprios (precisam saber
a posição de cada valor no texto): o de TOML 1.0 passa na suíte oficial
[toml-test](https://github.com/toml-lang/toml-test); o de JSON passa na
[JSONTestSuite](https://github.com/nst/JSONTestSuite) (todos os `y_` aceitos, todos
os `n_` recusados; os `i_` estão em [Limitações](#json-jsonc-e-json5)); o de JSON5
passa na suíte oficial [json5-tests](https://github.com/json5/json5-tests) (os 83
casos válidos aceitos e os 31 inválidos recusados, nenhum deixado de fora). O JSONC
não tem suíte oficial: há arquivos próprios em `Tests/ConfCoreTests/Fixtures/jsonc/`.
O de `.env` segue as regras do `dotenv` (Node/Ruby), escritas em [Regras do .env](#regras-do-env).
O INI não tem norma: o Konfig aceita um dialeto fixo, descrito em [Dialeto INI](#dialeto-ini) e
testado com arquivos próprios, com `.editorconfig` do projeto EditorConfig e com um trecho do
`php.ini-production` do PHP (`Tests/ConfCoreTests/Fixtures/ini/`).
O de YAML é testado com a suíte oficial [yaml-test-suite](https://github.com/yaml/yaml-test-suite)
(os 192 casos dentro do [subconjunto aceito](#yaml) lidos com os valores esperados, os 94 casos
inválidos recusados e os 116 que usam o que fica de fora recusados ou lidos sem diferença).

Parte da família de ferramentas da Kogumelo, que têm nome próprio começando por K
(ver também a Katraca). Chamava-se `km-toml` e depois `km-conf`: o primeiro nome mudou
porque o plano é editar vários formatos; o segundo, em 11/10/2026, quando as ferramentas
trocaram o prefixo `km-` pela inicial K. Hoje: TOML, JSON,
JSONC, JSON5, .env, INI e YAML (ver [Próximos formatos](#próximos-formatos)).

## Compilar

```sh
./build.sh
```

Gera `Konfig.app` nesta pasta, assinado localmente (`codesign --sign -`).
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
open -a "$PWD/Konfig.app" exemplos/config.toml
open -a "$PWD/Konfig.app" exemplos/config.json
open -a "$PWD/Konfig.app" exemplos/config.jsonc
open -a "$PWD/Konfig.app" exemplos/settings.jsonc
open -a "$PWD/Konfig.app" exemplos/config.json5
open -a "$PWD/Konfig.app" exemplos/.env
open -a "$PWD/Konfig.app" exemplos/config.ini
open -a "$PWD/Konfig.app" exemplos/config.yaml
# ou
open Konfig.app --args exemplos/config.toml
```

O formato vem do nome do arquivo: extensão `.toml`, `.json`, `.jsonc`, `.json5`, `.ini`, `.yaml` ou `.yml`
(também o arquivo chamado `.editorconfig`, que é INI); e `.env`
para o arquivo chamado exatamente `.env`, para `.env.qualquer-coisa` (`.env.local`,
`.env.production`) e para `qualquer-coisa.env` (`producao.env`). O nome conta mais
que o tipo que o macOS dá ao arquivo: para `.env` o sistema devolve extensão vazia e
o tipo genérico `public.data`, e para `.env.local`, a extensão `local` (há um teste
que confere isso).

**Um `.json` com comentário ou vírgula final é aberto como JSONC**, com o aviso
discreto "JSON com comentários" no pé da barra lateral, em vez de ser recusado. O
motivo: muitos arquivos de configuração com extensão `.json` são, na prática, JSONC
— o `settings.json` e o `launch.json` do VS Code, o `tsconfig.json`, o
`devcontainer.json`, o `.eslintrc.json`. Recusá-los deixaria o app inútil justamente
para eles, e o dono do arquivo já escolheu o dialeto (o programa que o lê aceita
comentários). O aviso existe porque o contrário não vale: nem todo programa que lê
JSON aceita comentário, e o nome do arquivo não conta isso a ninguém. O Konfig nunca
transforma um JSON puro em JSONC: um valor cru com comentário num `.json` sem
comentários é recusado ao gravar. Já o JSON5 só vale com a extensão `.json5` (um
`.json` com chave sem aspas é recusado, com linha e coluna).

No painel de abrir (⌘O), todo arquivo pode ser escolhido; arquivos que começam com
ponto (`.env`) ficam ocultos no painel até ⌘⇧. (Comando-Shift-ponto).

(O `open -a` não aceita caminho relativo como `./Konfig.app`; use o caminho completo.)

Aberto sem arquivo, o app mostra o painel de abrir.

### A janela

- **Barra lateral** (em YAML, como em JSON: cada mapa em bloco é uma seção e cada lista
  de mapas, um grupo): a raiz do arquivo, cada `[tabela]` e cada item de
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
  JSONC e JSON5 valem `// …` e `/* … */`, acima do membro ou no fim da linha (antes ou
  depois da vírgula) — inclusive a dica de escolha `a | b | c`.
  Comentário só vira ajuda se estiver colado à linha (sem linha em branco no meio).
  O comentário do começo do arquivo, separado da primeira chave ou seção por uma
  linha em branco, não é de nenhum campo: aparece em **Sobre o arquivo**, no topo
  da barra lateral, como está no arquivo (recuos mantidos), e pode ser editado ali:
  vale ao sair da caixa ou em Aplicar (⌘Return), entra no ⌘Z e, ao gravar, só as
  linhas de comentário que mudaram são reescritas (linha nova ganha o marcador da
  primeira linha do comentário, `#`, `;` ou `//`). Texto vazio apaga o comentário.
  Comentários soltos no meio do arquivo (com linha em branco antes da chave
  seguinte) continuam só no modo Texto.
- **Texto** (⌘2): o arquivo inteiro editável, com cores simples (em JSON, JSONC e
  JSON5: chaves em azul, textos em vermelho, comentários `//` e `/* */` em cinza; em
  JSON5 também as chaves sem aspas e os textos com aspas simples; em INI: `[seções]`
  em laranja, chaves em azul, comentários `;` e `#` em cinza, valores entre aspas em
  vermelho, com as mesmas regras de comentário do leitor; em YAML: chaves em azul,
  comentários `#` em cinza, textos entre aspas e o conteúdo dos blocos `|`/`>` em vermelho,
  `---` e `...` em laranja). O texto só é
  aplicado ao documento se for válido no formato do arquivo (TOML, JSON/JSONC, JSON5, .env, INI ou YAML);
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
`.jsonc`, `.json5`, `.env` e `.ini` (o macOS não declara estes quatro; o app declara
`br.com.kogut.konfig.jsonc`, `br.com.kogut.konfig.json5`,
`br.com.kogut.konfig.env` e `br.com.kogut.konfig.ini`, derivados de
`public.plain-text`), sempre com papel Editor e `LSHandlerRank` Alternate: **não**
se registra como padrão.

Para `.ini` há um detalhe: o **Xcode** importa o tipo `com.microsoft.ini` (derivado de
`public.text`) e, numa máquina com Xcode, é esse o tipo que o sistema dá aos arquivos
`.ini` (conferido no macOS 26 com `lsregister -dump`). Por isso o Konfig declara que
edita os dois, `br.com.kogut.konfig.ini` e `com.microsoft.ini`: com ou sem Xcode, ele
aparece em "Abrir com". O `.editorconfig` não tem extensão para o sistema; como o
`.env`, é reconhecido pelo nome dentro do app (`open -a`, ⌘O ou arrastar para o ícone).

Por que `public.plain-text` e não `public.json` como tipo-pai do `.jsonc` e do
`.json5`: num teste no macOS 26.7 com dois apps de mentira declarando extensões
novas, uma derivada de cada, o arquivo derivado de texto puro foi indexado pelo
Spotlight (importador RichText) e o derivado de `public.json` não teve importador
nenhum; o "Abrir com" do texto puro oferece os editores de texto (TextEdit, Xcode…);
e, como JSONC e JSON5 não são JSON válido, é melhor que programas que só aceitam
JSON estrito não se ofereçam para abri-los. Os dois tipos têm prévia no Quick Look. O tipo `.env` declarado só cobre nomes como
`producao.env`: `.env` e `.env.local` não têm extensão `env` para o sistema, então o
Finder não os associa ao Konfig; abra-os pelo `open -a`, pelo ⌘O do app ou
arrastando para o ícone. Para associar uma extensão:

1. Copie `Konfig.app` para `/Applications` (opcional, mas assim ele não depende desta pasta).
2. No Finder, selecione um arquivo da extensão › Arquivo › Obter Informações (⌘I).
3. Em "Abrir com", escolha Konfig e clique em **Alterar Tudo…**.

Sem isso, ele aparece em "Abrir com" (botão direito no arquivo).

Para YAML não há tipo a declarar: o macOS já tem `public.yaml` (extensões `.yaml` e `.yml`,
derivado de `public.text`; conferido no macOS 26 com `UTType(filenameExtension:)`). O Konfig
só diz que o edita, também com papel Editor e `LSHandlerRank` Alternate.

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

### JSON, JSONC e JSON5

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
- Comentários `//` antes do `{` inicial não aparecem como ajuda (não pertencem a nenhum campo):
  ficam em "Sobre o arquivo".
- Listas que mudam de quantidade de itens seguem a regra do TOML: reescritas com o
  recuo do primeiro item e a vírgula final se havia (em lista de uma linha ou de
  várias); comentários dentro delas se perdem. Mudando só valores de itens, os
  comentários ficam. Vírgula final de objeto nunca é tocada (só valores são reescritos).
- Casos que a especificação deixa a critério de quem lê (`i_` da JSONTestSuite):
  - **aceitos**: números fora do alcance — inteiro que não cabe em 64 bits vira
    decimal aproximado, expoente enorme vira infinito ou zero (só são reescritos
    se o campo for editado, e infinito não pode ser gravado); BOM UTF-8 no começo
    (mantido ao gravar).
  - **recusados**: arquivo que não é UTF-8 (ISO-8859-1, UTF-16, sequências
    inválidas); escape `\u` de surrogate sem par (`"\uD800"`), que não cabe num
    texto Unicode válido; mais de 128 níveis de listas/objetos um dentro do outro.

#### JSON5

Segue a especificação 1.0.0 (spec.json5.org). Além do que o JSONC aceita:

- chaves sem aspas que sejam identificadores do JavaScript (letras Unicode, `$`, `_`,
  dígitos depois do primeiro caractere, escapes `\uXXXX`), e chaves com aspas simples;
- textos com aspas simples; quebra de linha com `\` no fim da linha (LF, CRLF, CR,
  U+2028 ou U+2029); escapes `\'`, `\v`, `\0`, `\xHH` e qualquer outro caractere
  escapado vale ele mesmo (`\a` é `a`); `\1` a `\9` são erro;
- números hexadecimais (`0x1F`, `0XAB`, também com sinal), `Infinity`, `-Infinity`,
  `NaN`, sinal `+`, `.5` e `5.`; zero à esquerda (`010`) continua erro;
- espaços: tabulação vertical, avanço de página, espaço sem quebra (U+00A0), BOM no
  meio do arquivo, toda a categoria Unicode Zs e os separadores U+2028/U+2029;
  quebras de linha só com CR.

Ao gravar, cada valor mantém o estilo:

- aspas simples continuam simples (a `'` do texto novo é escapada como `\'`); aspas
  duplas continuam duplas; o começo e o fim que não mudaram são copiados byte a byte,
  inclusive escapes `\x41` e as quebras com `\`;
- inteiro hexadecimal continua hexadecimal, com o mesmo `0x`/`0X`, a mesma caixa
  dos dígitos e pelo menos a mesma largura (`0x00FF` → `0x000A`); negativo vira `-0x…`;
- `+` se mantém (`+7` → `+8`, `+1.50` → `+2.25`); `.5` → `.25`; `5.` → `6.` (e `6.5`
  quando o valor tem fração); infinito e NaN são gravados como `Infinity`, `-Infinity`
  e `NaN` (o JSON5 aceita, o JSON não);
- decimais seguem as regras do JSON (expoente, casas depois do ponto).

Limitações: inteiro maior que 64 bits (inclusive em hexadecimal) vira decimal
aproximado; escape `\u` de surrogate sem par é recusado, como no JSON; `-NaN` é
lido como NaN (o sinal some se o campo for editado); a chave nunca é reescrita (para
renomear, use o modo Texto); num arquivo só com CR como quebra, a linha dos erros
conta só LF e sai errada.

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

Não há norma oficial; estas são as regras exatas que o Konfig aceita, escolhidas
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

### INI

- Todo valor é texto; cada `[seção]` é um item da barra lateral e as chaves antes da
  primeira seção ficam em "Geral". Um comentário `a | b | c` vira escolha.
- Listas `chave[] = …` (estilo PHP) aparecem como etiquetas. Acrescentar um item
  acrescenta **uma linha**, logo depois da última da lista, copiando o começo dela
  (recuo, chave, separador e espaços); tirar um item tira **a linha dele** (o
  comentário que estava acima dela fica). Uma lista não pode ficar vazia pelo
  formulário: para apagá-la, use o modo Texto.
- Se outra chave estiver no meio dos itens de uma lista e as duas forem alteradas,
  as alterações são aplicadas uma de cada vez (o trecho da lista vai do primeiro
  ao último item e contém a outra chave); o resultado é o mesmo.
- Não há escapes: um valor com quebra de linha não pode ser gravado, nem um que
  precise de aspas e tenha aspas duplas **e** simples.
- O arquivo precisa estar em UTF-8 (com ou sem BOM). `desktop.ini` gravado pelo
  Windows costuma estar em UTF-16 ou na página de código do sistema: é recusado.
- Criar chaves e seções: pelo modo Texto.

### Dialeto INI

INI não tem norma: o Windows (`GetPrivateProfileString`), o PHP (`parse_ini_file`),
o Python (`configparser`) e o Git (`git config`) seguem regras diferentes. O Konfig
aceita exatamente estas, escolhidas para abrir sem surpresa os arquivos mais comuns
(`php.ini`, `.editorconfig`, `desktop.ini`, arquivos de jogos e programas Windows) e
para nunca adivinhar: o que é ambíguo é recusado, com linha e coluna, em vez de ser
lido de um jeito que o programa dono do arquivo talvez não leia.

- Arquivo em UTF-8, com ou sem BOM; quebras LF ou CRLF (mantidas ao gravar). CR
  sozinho é erro.
- **Linhas em branco** são preservadas e separam o comentário da chave seguinte.
- **Comentário de linha**: `;` ou `#` no começo da linha (espaços antes são
  permitidos). Os comentários logo acima de uma chave (sem linha em branco no meio)
  viram a ajuda do campo, sem as marcas repetidas (`;; texto` → `texto`).
- **Seção**: `[nome]`. Espaços dentro dos colchetes fazem parte do nome, tirando os
  das pontas (`[ CLI Server ]` → `CLI Server`). Pontos são literais: `[a.b]` é a
  seção `a.b`, não uma subseção de `a`. O nome vai até o primeiro `]` depois do qual
  só há espaços e, opcionalmente, um comentário; assim `[*.[ch]]` (EditorConfig) é a
  seção `*.[ch]` e `[a] ; nota` é a seção `a` com o comentário `nota`. Seção sem nome
  (`[]`) é erro. Uma seção que aparece de novo continua a primeira (as chaves se
  juntam; repetir uma chave entre as duas partes é erro).
- **Chaves antes da primeira seção** ficam na seção "Geral".
- **Par**: `chave = valor` ou `chave: valor`; vale o primeiro `=` ou `:` da linha
  (`url = http://x` tem a chave `url`). O separador e os espaços em volta dele
  nunca são reescritos. A chave é o texto antes do separador, sem os espaços das pontas.
- **Valor sem aspas**: os espaços das pontas não fazem parte dele (e ficam no
  arquivo). Termina num comentário: `;` ou `#` **depois de um espaço ou tabulação**
  (`a = x ; nota`). Colados, fazem parte do valor: `url = http://x/#a` e `a = b;c`.
  Dois casos no começo do valor: `;` é comentário (`a = ; nota` é valor vazio, como
  no PHP) e `#` é valor (`cor = #DD0000`, ver abaixo).
- **Valor entre aspas** duplas ou simples, **sem escapes** (`\` é uma barra); a aspa
  fecha na mesma linha, e depois dela só podem vir espaços e um comentário.
  `"  com espaços ; e # dentro  "` guarda tudo isso.
- **Todo valor é texto**: não há como saber se `On`, `yes` ou `1` é sim/não (o PHP
  diz que sim, o Python depende de quem lê, o EditorConfig só aceita `true`).
- **Listas no estilo PHP**: várias linhas `chave[] = valor` na mesma seção formam uma
  lista (`ext [] =` é a mesma lista). As chaves `extension` e `zend_extension`
  repetidas também formam lista (ver abaixo).
- **Chave repetida sem `[]` na mesma seção é recusada**, com linha e coluna: editar
  uma delas seria editar talvez a que o programa ignora. `x` e `x[]` na mesma seção
  também colidem.
- **Linha que não é seção, par nem comentário é recusada**, com linha e coluna.

Ao gravar, o tipo de aspas do valor se mantém: sem aspas continua sem aspas se o
texto couber (não vazio nas pontas, sem `;`, sem `#` no começo ou depois de espaço,
sem começar com aspas); se não couber, aspas duplas (ou simples, se o texto tiver
`"`). Aspas duplas continuam duplas e simples continuam simples, a menos que o texto
tenha essa aspa. Um valor vazio em `chave =` recebe um espaço depois do `=` (`chave = novo`).

**Ajustes feitos ao testar com arquivos reais** (a regra pedida no começo foi
mudada nestes pontos):

- `#` **no começo do valor é valor**, não comentário. O `php.ini-production` e o
  `php.ini-development` oficiais trazem `;highlight.string  = #DD0000` (e mais quatro
  cores): descomentada, a linha precisa dar a cor `#DD0000`, que é o que o PHP lê (o
  PHP não usa `#` como comentário desde a versão 7). Com a regra "`#` depois de
  espaço é comentário", o valor seria vazio. Ao gravar, um texto que começa com `#`
  vai entre aspas, para não depender disso.
- `;` no começo do valor continua comentário (`chave = ; nota`), como no PHP e no Windows.
- `extension` e `zend_extension` **repetidas são lista**, não erro. É o jeito
  documentado de carregar extensões no `php.ini` (`;extension=curl`,
  `;extension=gd`… descomentadas, uma por linha); recusar a repetição faria quase todo
  `php.ini` de uso real (Windows, XAMPP) não abrir. Para qualquer outra chave a
  repetição continua recusada.
- O nome da seção vai até o **primeiro `]` seguido só de espaços ou comentário**, e
  não até o primeiro `]`: o `.editorconfig` usa globs com colchetes, como `[*.[ch]]`.
- O valor gravado sem aspas também não pode ter `;` em lugar nenhum (nem colado), porque
  o PHP corta o valor no `;`: `a = b;c` é lido pelo Konfig como `b;c`, mas um valor
  novo `b;c` é gravado como `"b;c"`, que os dois leem igual.

**Fora do dialeto** (e como aparecem se o arquivo os tiver):

- **Continuação de valor em várias linhas** (`configparser` do Python: linha
  seguinte recuada): a linha de continuação não tem `=` nem `:`, então o arquivo é
  recusado com erro nessa linha. Se a continuação tiver `=` ou `:`, ela vira uma
  chave à parte (`  b = 2` recuado é a chave `b`).
- **Interpolação** `%(x)s` (Python) e `${x}` (PHP, Python `ExtendedInterpolation`):
  fica como texto, sem expandir (`%(home)s/bin` é exatamente esse texto).
- **Subseções do Git** (`[remote "origin"]`): o nome da seção é o texto inteiro,
  `remote "origin"`, com as aspas; dá para editar as chaves, mas o Konfig não sabe
  que é a subseção `origin` de `remote`. Chaves repetidas do Git (`fetch` várias
  vezes) são recusadas, e o `.gitconfig` não é associado ao Konfig.
- **Chave sem valor** (`skip-networking` do `my.cnf`, `allow_no_value` do Python):
  recusada como linha que não é par.
- **Escapes** em aspas duplas (`\"`, `\n`, `${VAR}` do PHP dentro de aspas): ficam
  como estão no texto (o PHP expande alguns; o Konfig mostra o texto cru).

### YAML

#### Subconjunto aceito

A norma YAML 1.2 completa (âncoras, etiquetas de tipo, vários documentos num arquivo, chaves
complexas) seria um projeto maior que o resto do app. O Konfig lê o subconjunto que aparece em
arquivos de configuração:

- **Um documento por arquivo**, com `---` opcional no começo e `...` opcional no fim (depois do
  `...`, só comentários). Arquivo vazio ou só com comentários é um arquivo sem valores.
- **Mapas em bloco** (`chave: valor`, aninhados pelo recuo) e **listas em bloco** (`- item`),
  inclusive lista de mapas (`- nome: x` com as linhas seguintes recuadas), lista no mesmo recuo
  da chave (`chave:` e na linha de baixo `- a`) e listas e mapas compactos (`- - a`, `- a: 1`).
  O recuo é só com espaços: tabulação no recuo é erro, como diz a norma. Chave repetida no
  mesmo mapa é erro (a norma também proíbe).
- **Valores**: sem aspas (de uma ou várias linhas; as quebras viram espaço e as linhas em branco,
  `\n`); entre aspas simples (`''` é uma aspa); entre aspas duplas, com todos os escapes da
  norma (`\n`, `\t`, `\x41`, `\u00e9`, `\U0001F600`, `\N`, `\_`, `\L`, `\P`, quebra escapada…);
  em bloco, `|` (literal) e `>` (dobrado), com os indicadores de corte `-` e `+` e de recuo `1`–`9`.
- **Coleções em linha** `[a, b]` e `{a: 1, b}`, também em várias linhas e uma dentro da outra,
  com par sozinho em lista (`[a: 1]`) e chave sem valor (`{a, b: 1}` tem `a: null`).
- **Comentários `#`** (com espaço antes): os que estão logo acima de uma chave (sem linha em branco
  no meio) e o do fim da linha viram a ajuda do campo; `a | b | c` vira lista de opções.
- Arquivo em UTF-8, com ou sem BOM; quebras LF ou CRLF (mantidas ao gravar). CR sozinho e
  caracteres de controle são recusados.

No formulário: cada mapa em bloco é uma seção e cada lista de mapas um grupo (como em JSON);
uma lista (em bloco ou em linha) com todos os itens do mesmo tipo simples aparece como
etiquetas; mapas em linha (`{a: 1}`), listas mistas, listas de listas, valores vazios (`chave:`)
e `null` aparecem como texto cru (YAML), igual ao TOML.

#### Tipos: o *core schema* do YAML 1.2

Um valor sem aspas tem o tipo que o *core schema* do YAML 1.2 diz, e só esses:

| texto sem aspas | tipo |
|---|---|
| `true`, `True`, `TRUE`, `false`, `False`, `FALSE` | sim/não |
| `null`, `Null`, `NULL`, `~` e o valor vazio | nulo |
| `12`, `-3`, `+7`, `0x1F`, `0o17` | inteiro (`010` é dez) |
| `1.5`, `.5`, `1.`, `1e3`, `-2.5E-3`, `.inf`, `-.Inf`, `.nan` | decimal |
| todo o resto: `yes`, `no`, `on`, `off`, `y`, `n`, `0b101`, `1_000`, `12:30`, `2024-01-31`… | texto |

Entre aspas ou em bloco, é sempre texto. Por que o 1.2 e não o 1.1: é a versão atual da norma
(2009), a que o próprio YAML recomenda e a que a yaml-test-suite usa; o Konfig não tem como saber
qual programa vai ler o arquivo, e o 1.2 é o que muda menos o que está escrito (`no` continua
`no`). Datas não existem no 1.2: `2024-01-31` é texto.

#### Aspas de proteção (leitores YAML 1.1)

Muitos programas ainda leem YAML pela regra antiga, a 1.1 (PyYAML e, com ele, Ansible e
docker-compose em Python; o `yaml.v2` do Go; o Psych do Ruby): para eles `no`, `off` e `n` são
**falso**, `on` e `yes` são verdadeiro, `010` é **oito** (octal), `1_000` é mil, `12:30` é 750
(sexagesimal), `2024-01-31` é uma data. É o caso clássico da Noruega: `pais: NO` vira `pais: false`.

Por isso, **ao gravar um texto sem aspas**, o Konfig põe aspas duplas quando o texto seria lido
como outro tipo pelo YAML 1.2 **ou** pelo 1.1, mesmo que no 1.2 ele já seja texto:

- sim/não e nulo do 1.1, em qualquer caixa: `y`, `n`, `yes`, `no`, `on`, `off`, `true`, `false`, `null`, `~`, vazio;
- tudo o que começa com dígito (ou `.` e dígito, depois do sinal) e só tem dígitos, `.`, `:`,
  `_`, `e`, `x`, `o`, `b`, sinais e letras de `a` a `f`: `1e3`, `010`, `0x1F`, `0b11`, `1_000`,
  `12:30`, `8080:80`, `1.5`, `1.2.3`;
- `.inf`, `-.inf`, `.nan`, datas (`2024-01-31…`), `<<` e `=`.

A regra é de propósito larga: aspas a mais não mudam o valor para ninguém; aspas a menos mudam o
tipo em algum programa. Ela vale só para o texto **gravado pelo Konfig**: um `pais: no` que já está
no arquivo é lido como texto (YAML 1.2) e não é tocado se o campo não for editado.

#### Fora do subconjunto: abre só no modo Texto

Âncoras e aliases (`&base`, `*base`), mesclagem (`<<:`), etiquetas (`!!str`, `!Ref`, `!!binary`),
vários documentos no arquivo, chaves complexas (`? chave`, `[a, b]: x`), chave vazia ou nula
(`: x`, `~: x`) e diretivas (`%YAML`, `%TAG`) ficam de fora. Um arquivo com qualquer um deles **abre
só no modo Texto**, com o aviso dizendo o que não é aceito e em que linha (por exemplo "linha 3:
âncora (&) está fora do subconjunto que o Konfig edita pelo formulário"). O formulário fica
indisponível; o texto pode ser editado e salvo, e é gravado como está (com o `.bak`), sem a
releitura e conferência que o formulário faz. Se o texto ficar dentro do subconjunto, o formulário
volta a funcionar; erro de sintaxe de verdade continua impedindo aplicar e salvar.

Por que abrir no modo Texto em vez de recusar: são arquivos YAML válidos e comuns (âncoras em
docker-compose e GitHub Actions, `!Ref` no CloudFormation); recusar obrigaria a abrir em outro
editor para mudar uma linha. Por que não no formulário: com um alias, mudar o valor da âncora
mudaria vários lugares ao mesmo tempo, e uma etiqueta muda o tipo do valor — o formulário mostraria
algo diferente do que o programa lê. O leitor nunca ignora esses recursos em silêncio: ao encontrar
um deles, para e avisa. (Um arquivo inválido que também usa um desses recursos pode receber o
mesmo aviso em vez do erro de sintaxe — na yaml-test-suite, 22 dos 94 casos inválidos; nos dois
casos o formulário não abre.)

#### Gravação

- Só o trecho do valor alterado muda. O tipo de aspas se mantém: sem aspas continua sem aspas
  quando cabe; aspas simples continuam simples; aspas duplas continuam duplas; bloco `|`/`>`
  continua bloco, com o mesmo recuo, o mesmo indicador de recuo e o comentário do cabeçalho.
- Precisa de aspas (duplas) o texto vazio ou com espaço nas pontas, com `: ` ou ` #`, terminado em
  `:`, começado por indicador (`- `, `?`, `:`, `,`, `[`, `]`, `{`, `}`, `#`, `&`, `*`, `!`, `|`, `>`,
  `'`, `"`, `%`, `@`, `` ` ``), com quebra de linha, tabulação ou controle — e os das
  [aspas de proteção](#aspas-de-proteção-leitores-yaml-11). Dentro de `[ ]`, também com `,[]{}`.
- Em bloco, o indicador de corte acompanha o texto novo: sem quebra no fim, `|-`; com uma, `|`;
  com mais de uma, `|+`. Num `>`, cada quebra vira uma linha em branco; se alguma linha começar
  com espaço (que o `>` não dobra), o bloco vira `|`. Se a primeira linha começar com espaço e não
  houver indicador de recuo, ou o texto tiver controles, vai entre aspas duplas.
- **Lista em bloco** que muda de tamanho: item a mais é uma linha nova (`- valor`) logo depois do
  último item, com o recuo e o `- ` dele e as aspas do último item do mesmo tipo; item a menos é a
  linha dele que sai (os comentários das outras linhas ficam). Lista que fica vazia vira `[]`.
- **Lista em linha** que muda de tamanho: como no TOML e no JSON (reescrita com o estilo do
  primeiro item; comentários dentro dela se perdem).
- Número continua na mesma forma (`0x`, `0o`, `+`, expoente, casas decimais); `True` continua
  com maiúscula; `.Inf` continua `.Inf`. YAML (core schema) não tem data: um valor de data é recusado.
- Valor vazio (`chave:`) recebe um espaço antes do valor novo (`chave: novo`).

Limitações: chaves não são reescritas (para renomear, use o modo Texto); comentários dentro de
coleções em linha não viram ajuda; um texto sem aspas de várias linhas, ao ser editado, é gravado
numa linha só; uma lista em bloco com itens compactos (`- - a`) que muda de tamanho é reescrita em
linha; a coloração do modo Texto é por linha (um texto entre aspas de várias linhas fica colorido
só na primeira).

### Próximos formatos

A parte própria de cada formato fica em `Formato.swift` (qual leitor, qual escritor
e o que o formato não aceita) e em um par `LeitorX.swift`/`FormatarX.swift`; `Gravar`,
`Edicao`, `Campos` e a interface já são comuns. Para acrescentar um formato:

- **YAML completo** (âncoras, etiquetas, vários documentos): exigiria editar valores que
  aparecem em vários lugares ao mesmo tempo; hoje esses arquivos abrem só no modo Texto.

### Mudanças de nome no código (para quem usa o `ConfCore`)

Os nomes antigos continuam valendo como apelidos:

| antes | agora |
|---|---|
| `DocumentoTOML` | `DocumentoConf` (com `formato`, `valorRaiz` e `nomeFormato`; `raiz` ainda é a `Tabela`) |
| `EdicaoTOML(bytes)` | `Edicao(bytes, formato:)` (`.toml` por padrão) |
| `ErroTOML` | `ErroLeitura` (com `formato`; a mensagem diz "TOML inválido" ou "JSON inválido") |

Também: `Formato` (`.toml`, `.json`, `.json5`, `.env`, `.ini`, `.yaml`; `ehJSON` para os dois JSON)
despacha ler, ler um valor e escrever (`LeitorJSON.lerJSON5` para JSON5),
e `Formato(nomeArquivo:)` escolhe pelo nome;
`Gravar.aplicar(bytes, alteracoes:, formato:)`; `Valor.nulo`; `TipoCampo.cru.nome`
é "texto cru" e `nome(em: formato)` dá "TOML" ou "JSON".
Com o YAML: `ErroLeitura.foraDoSubconjunto` (arquivo válido que só pode ser editado como texto),
`Edicao.somenteTexto` e `trocarTexto` aceitando esse texto, e `Formato.ajustarCru` (o texto cru
digitado é ajustado ao lugar antes de gravar; nos outros formatos, não muda nada).

## Organização

```
Package.swift
Sources/ConfCore/      leitores, modelo e gravação (sem interface)
  Formato.swift        TOML, JSON, .env ou INI: qual leitor e qual escritor usar
  Leitor.swift         TOML 1.0 → estrutura, com intervalo de bytes de cada valor
  LeitorJSON.swift     JSON/JSONC/JSON5 → estrutura, com intervalos e comentários
  Gravar.swift         troca só os trechos alterados, no estilo original (TOML)
  FormatarJSON.swift   escreve valores JSON/JSON5 no estilo do original
  LeitorEnv.swift      .env → estrutura, com intervalos e comentários
  FormatarEnv.swift    escreve valores .env mantendo o tipo de aspas
  LeitorINI.swift      INI → estrutura (seções, listas `chave[]`), com intervalos e comentários
  FormatarINI.swift    escreve valores INI mantendo as aspas; acrescenta/tira linhas de listas
  LeitorYAML.swift     YAML (subconjunto de configuração) → estrutura, com intervalos e comentários
  FormatarYAML.swift   escreve valores YAML no estilo do original; aspas de proteção; listas em bloco
  Campos.swift         estrutura → seções e campos da tela
  Edicao.swift         estado de um arquivo aberto; diferença por linhas
  Modelo.swift         tipos (Valor, DataHora, Entrada, DocumentoConf, …)
Sources/Konfig/       o app (NSDocument + SwiftUI)
Tests/ConfCoreTests/   suítes toml-test, JSONTestSuite e json5-tests (Fixtures/,
                       licença MIT), tsconfig.json de exemplo, arquivos JSONC
                       (Fixtures/jsonc/), .env (Fixtures/env/), INI (Fixtures/ini/:
                       próprios, .editorconfig do EditorConfig e trecho do php.ini,
                       licenças MIT e BSD ao lado), yaml-test-suite (Fixtures/yaml/,
                       licença MIT, ORIGEM.txt com o commit) e testes de gravação
exemplos/config.toml
exemplos/config.json
exemplos/config.jsonc
exemplos/settings.jsonc
exemplos/config.json5
exemplos/.env
exemplos/config.ini    (com CRLF)
exemplos/config.yaml   (no estilo de um docker-compose)
```

### Diagnóstico sem teclado

```sh
KONFIG_AUTOTESTE="/tmp/x/config.toml|/tmp/x/saida" Konfig.app/Contents/MacOS/Konfig
KONFIG_AUTOTESTE="/tmp/x/config.json|/tmp/x/saida-json" Konfig.app/Contents/MacOS/Konfig
KONFIG_AUTOTESTE="/tmp/x/config.jsonc|/tmp/x/saida-jsonc" Konfig.app/Contents/MacOS/Konfig
KONFIG_AUTOTESTE="/tmp/x/settings.jsonc|/tmp/x/saida-settings" Konfig.app/Contents/MacOS/Konfig
KONFIG_AUTOTESTE="/tmp/x/config.json5|/tmp/x/saida-json5" Konfig.app/Contents/MacOS/Konfig
KONFIG_AUTOTESTE="/tmp/x/.env|/tmp/x/saida-env" Konfig.app/Contents/MacOS/Konfig
KONFIG_AUTOTESTE="/tmp/x/config.ini|/tmp/x/saida-ini" Konfig.app/Contents/MacOS/Konfig
KONFIG_AUTOTESTE="/tmp/x/config.yaml|/tmp/x/saida-yaml" Konfig.app/Contents/MacOS/Konfig
```

O arquivo precisa ser uma cópia de `exemplos/config.toml`, `exemplos/config.json`,
`exemplos/config.jsonc`, `exemplos/settings.jsonc`, `exemplos/config.json5`,
`exemplos/.env`, `exemplos/config.ini` ou `exemplos/config.yaml` (o roteiro conta com os campos deles; a cópia do `.env` pode se
chamar `.env`, `.env.local` ou `algo.env`; uma cópia do `config.jsonc` com nome
`algo.json` testa o aviso "JSON com comentários"). Abre a **cópia** (ele é alterado e depois restaurado), altera três
valores pelo mesmo caminho dos controles, salva, desfaz, testa o modo Texto e a
recarga por mudança externa, e grava `relatorio.txt` e fotos da janela na pasta
de saída. No INI, também acrescenta um item na lista `extensoes[]` (confere que é uma
linha nova e nada mais) e desfaz; uma cópia do `config.ini` chamada `.editorconfig`
confere que o ⌘S mantém o nome (não grava `.editorconfig.ini`). No YAML, faz o mesmo com a lista
em bloco `services.web.ports` e confere que um texto com âncora dá aviso de "fora do subconjunto"
(não erro) no modo Texto.

## Vindo do km-conf

Até 11/10/2026 o app se chamava km-conf, com o identificador `br.com.kogut.km-conf`; agora é
`br.com.kogut.konfig`, e os tipos `.jsonc`, `.json5`, `.env` e `.ini` passaram a
`br.com.kogut.konfig.*`. Na primeira abertura, o Konfig copia as preferências guardadas pelo
identificador antigo (posição e tamanho da janela, última pasta do painel de abrir). Não passam,
porque o macOS os guarda por identificador fora das preferências: a lista de **Abrir Recente** e
as associações feitas com **Alterar Tudo…** no Finder (refaça-as escolhendo o Konfig). Um
`km-conf.app` antigo pode ser apagado; enquanto existir, aparece também em "Abrir com".

## Licença

[MIT](LICENSE), © 2026 Kogumelo Informática Ltda. Use, copie e modifique à
vontade, mantendo o aviso de copyright. O código vem sem garantia. Os casos de teste
de terceiros em `Tests/ConfCoreTests/Fixtures/` têm a licença de origem ao lado.
