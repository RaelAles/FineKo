# FineKo

[English](README.md) | **Português**

Coleção de plugins para o [KOReader](https://koreader.rocks/) que melhora a
organização, os metadados e a descoberta dos seus livros.

O repositório reúne três plugins independentes, todos escritos em Lua e
instalados como pastas `.koplugin`:

| Plugin | Pasta | O que faz |
| --- | --- | --- |
| Atualizar metadados | `atualizarmetadados.koplugin` | Busca metadados e capa por ISBN em várias fontes gratuitas e grava no livro. |
| Destaque aleatório | `destaquealeatorio.koplugin` | Mostra uma citação aleatória dos seus livros ao abrir o KOReader ou voltar da suspensão. |
| Estante mosaico | `estantemosaico.koplugin` | Sobre a estante em mosaico, desenha o título e um selo de progresso em cada capa. |

---

## 1. Atualizar metadados (`atualizarmetadados.koplugin`)

Busca metadados de um livro por ISBN em várias fontes gratuitas, agrega os
resultados campo a campo e permite editar tudo antes de gravar — inclusive
escolher a capa de maior qualidade.

### Como usar

1. Na estante (ou no Histórico, nas Coleções ou na Busca de arquivos), toque e
   segure sobre o livro e escolha **Buscar metadados**.
2. Digite o **ISBN-10 ou ISBN-13** do livro e toque em **Buscar**.
   - Se deixar o campo vazio, o plugin abre a mesma janela com os metadados
     atuais do documento para você só visualizar/editar, sem consultar a
     internet.
3. Aguarde a busca. Abre uma janela com uma linha por campo:
   - **Título**, **Autor(es)**, **Série**, **Número na série**, **Idioma**,
     **Palavras-chave**, **Descrição**.
   - **ISBN** (apenas referência, não editável).
   - **Capa** (número de capas encontradas).
4. Toque em um campo para:
   - escolher entre as alternativas encontradas (o rótulo mostra quantas são), ou
   - editar manualmente quando há só uma opção.
   - Em **Palavras-chave** o seletor sempre abre e mistura os resultados das
     fontes com categorias predefinidas.
5. Toque em **Capa** para abrir o seletor de capas:
   - mostra cada imagem válida com sua fonte e dimensões;
   - **toque** abre a imagem para conferir;
   - **toque longo** define qual capa será aplicada.
   - A capa escolhida automaticamente (sem intervenção) é a de maior pontuação,
     que combina resolução, proporção e prioridade da fonte.
6. Toque no ícone de confirmação (✓) na barra de título para **Aplicar ao
   livro**. O plugin grava os metadados no sidecar do livro, aplica a capa e,
   por fim, renomeia o arquivo para o padrão **"Autor - Título.ext"**.

### O que ele faz por baixo

- Consulta fontes gratuitas e mescla os resultados por prioridade:
  - **Google Books** (feed GData, API v1 e ViewAPI, em cascata);
  - **Open Library** (busca geral e por ISBN);
  - **Inventaire / Wikidata**;
  - **Amazon** (14 domínios, em ordem que prioriza o idioma do livro);
  - capas extras de busca de imagens quando necessário.
- Junta as capas candidatas, remove duplicatas (mesma dimensão e tamanho de
  arquivo) e descarta imagens quebradas ou pequenas demais (mínimo 100×100).
- Grava os campos como `custom_props` e a capa via `flushCustomCover`, fazendo
  o KOReader atualizar a estante na hora.
- Renomeia usando o próprio `FileManager`, o que move o sidecar `.sdr` junto,
  atualiza histórico e coleções e evita colisão de nomes.

### Requisitos

- Conexão com a internet para a etapa de busca (a edição sem ISBN funciona
  offline).

---

## 2. Destaque aleatório (`destaquealeatorio.koplugin`)

Exibe um destaque (citação) aleatório dos seus livros em um popup — ao abrir o
KOReader e/ou ao retornar da suspensão. Também pode ser chamado a qualquer
momento pelo menu.

### Como usar

- O popup aparece automaticamente conforme as opções ativas (veja abaixo).
- Acesse **Menu → Ferramentas → Destaque aleatório** para:
  - **Mostrar ao abrir o KOReader** (ligado por padrão);
  - **Mostrar ao retornar da suspensão** (ligado por padrão);
  - **Ver um destaque agora** — sorteia e mostra uma citação imediatamente.
- Citações curtas aparecem em um popup que fecha ao toque.
- Citações longas (mais de ~180 caracteres) são resumidas, com o botão
  **mais** para abrir o texto completo. O popup mostra a citação e, em itálico,
  a atribuição **"Título - Autor"**.

### O que ele faz por baixo

- Para não travar nem consumir memória, mantém um **índice** enxuto dos
  sidecars `metadata.*.lua`: para cada livro guarda apenas o horário de
  modificação e a quantidade de destaques.
- A varredura roda em segundo plano, em fatias, e é salva em disco. Nas sessões
  seguintes, só os arquivos alterados são relidos.
- O sorteio é ponderado pela quantidade de destaques de cada livro — o que
  equivale a sortear uniformemente entre todos os destaques — e só então abre
  aquele sidecar específico.
- Lê os destaques nos formatos novo (`annotations`) e antigo (`bookmarks` com
  `highlighted` e a tabela `highlight` pré-2014), com a mesma cobertura do
  KOReader.

### Limitações conhecidas

- A pasta legada `history/` do KOReader não é varrida (apenas os locais de
  sidecar atuais: ao lado do livro, pasta central e pasta por hash).

---

## 3. Estante mosaico (`estantemosaico.koplugin`)

Adiciona uma camada visual sobre a estante em mosaico: uma **faixa central
translúcida com o título** do livro e um **selo sutil com o estado de leitura**
(porcentagem lida ou ✓ quando concluído) sobre cada capa.

### Como usar

1. Ative o plugin nativo **Cover browser** e coloque a estante em **modo
   mosaico**. O Estante mosaico funciona como camada sobre ele.
2. Acesse **Menu → Ferramentas → Estante mosaico** para ligar/desligar:
   - **Faixa central com o título** (ligado por padrão);
   - **Selo de progresso/conclusão** (ligado por padrão).

### O que ele faz por baixo

- Em vez de substituir o mosaico nativo, envolve a montagem dos ítens e troca
  a pintura de cada capa por uma versão própria, que desenha somente os
  overlays do plugin.
- O título vem dos metadados do `BookInfoManager`; se ainda não houver
  metadados extraídos, usa o nome do arquivo sem extensão.
- A faixa só é desenhada sobre capas com arte real (não sobre capas de texto
  geradas), para não repetir o título.
- O selo mostra a porcentagem lida; a partir de ~99,9% mostra um ícone de
  concluído.

### Requisitos

- O plugin nativo **Cover browser** precisa estar ativo e em **modo mosaico**.
  Sem ele, o plugin não desenha nada e registra um aviso no log.

---

## Instalação

Os plugins são pastas terminadas em `.koplugin`. Para instalar, basta copiá-las
para dentro da pasta `plugins` da sua instalação do KOReader — a mesma pasta que
já contém plugins nativos como `coverbrowser.koplugin`.

### Opção A — Baixar o pacote de release (mais fácil)

1. Acesse a página de **Releases** do repositório:
   <https://github.com/raelales/FineKo/releases>
2. Baixe o arquivo `.zip` da versão mais recente (gerado a cada tag `v*`).
3. Descompacte o conteúdo. Você verá as três pastas `.koplugin`.
4. Copie as pastas que quiser para a pasta `plugins` do KOReader.
5. Reinicie o KOReader (feche e abra de novo).

### Opção B — Copiar do repositório

1. Baixe ou clone este repositório:
   ```bash
   git clone https://github.com/raelales/FineKo.git
   ```
2. Copie cada pasta `.koplugin` desejada para a pasta `plugins` do KOReader.
3. Reinicie o KOReader.

### Onde fica a pasta `plugins`

Ela fica dentro da pasta de instalação do KOReader. O caminho varia conforme o
aparelho; localize a pasta do KOReader e procure a subpasta `plugins` (a que
contém `coverbrowser.koplugin`). Alguns exemplos comuns:

- **Kobo:** `.adds/koreader/plugins/`
- **Kindle:** `koreader/plugins/`
- **Android:** `koreader/plugins/` na memória interna ou no cartão.
- **Desktop (Linux/Windows/macOS):** `plugins/` ao lado do executável do
  KOReader.

> Dica: para instalar apenas alguns plugins, copie somente as pastas
> correspondentes. Eles funcionam de forma independente.

### Atualizar

Substitua as pastas `.koplugin` antigas pelas novas e reinicie o KOReader. As
configurações ficam guardadas nas configurações do KOReader
(`G_reader_settings`) e não são perdidas.

### Desinstalar

Basta apagar a pasta `.koplugin` correspondente e reiniciar o KOReader.

---

## Idiomas e traduções

Os três plugins são traduzidos para os 21 idiomas cobertos pela fonte
Atkinson Hyperlegible Next: português, inglês, espanhol, alemão, francês,
indonésio, italiano, malaio, holandês, norueguês, sueco, suaíli, africâner,
albanês, catalão, dinamarquês, filipino, finlandês, galego, islandês e
luxemburguês. A interface segue o idioma escolhido no KOReader.

O catálogo de mensagens fica em `i18n/translations.py`. O msgid é o texto em
português exatamente como aparece no código Lua, então para `pt` a tradução é o
próprio msgid. Para alterar ou acrescentar uma tradução:

1. Edite `i18n/translations.py`.
2. Gere os catálogos de novo:
   ```bash
   python3 i18n/build.py
   ```
   Isso requer o utilitário `msgfmt` (pacote gettext) no PATH.
3. O script grava `<plugin>/l10n/<idioma>/fineko.po` e `fineko.mo` nos três
   plugins e confere se as três cópias de `fineko_i18n.lua` seguem idênticas.

---

## Estrutura do repositório

```
FineKo/
├── atualizarmetadados.koplugin/
│   ├── _meta.lua          # nome e descrição do plugin
│   ├── main.lua           # lógica de busca, agregação e gravação
│   ├── fineko_i18n.lua    # carrega o catálogo do idioma ativo do KOReader
│   └── l10n/<idioma>/     # catálogos gettext (fineko.po e fineko.mo)
├── destaquealeatorio.koplugin/
│   ├── _meta.lua
│   ├── main.lua           # índice, sorteio e popup da citação
│   ├── fineko_i18n.lua    # mesmo arquivo dos outros plugins
│   └── l10n/<idioma>/
├── estantemosaico.koplugin/
│   ├── _meta.lua
│   ├── main.lua           # menu e ciclo de vida
│   ├── em_overlay.lua     # desenho da faixa e do selo sobre as capas
│   ├── fineko_i18n.lua    # mesmo arquivo dos outros plugins
│   └── l10n/<idioma>/
├── i18n/
│   ├── translations.py    # catálogo de mensagens e as 21 traduções
│   └── build.py           # gera os arquivos .po e .mo
├── .github/workflows/release.yml  # empacota e publica o release a cada tag
├── README.md              # versão em inglês (padrão)
└── README.pt-BR.md        # este arquivo (português)
```

## Releases e empacotamento

O fluxo em `.github/workflows/release.yml` é disparado ao enviar uma tag
começada por `v`. Ele primeiro verifica se todos os arquivos `.lua` carregam no
luajit, depois empacota o repositório inteiro (exceto `.git`, `.github` e
arquivos `.zip`) em um único arquivo `FineKo-<tag>.zip` e publica em
**Releases** com as notas geradas automaticamente.

Para criar uma nova versão:

```bash
git tag v1.0.0
git push origin v1.0.0
```
