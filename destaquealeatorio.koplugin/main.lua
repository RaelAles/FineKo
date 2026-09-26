local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local DataStorage = require("datastorage")
local Device = require("device")
local DocSettings = require("docsettings")
local FileManagerBookInfo = require("apps/filemanager/filemanagerbookinfo")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LuaSettings = require("luasettings")
local ReadHistory = require("readhistory")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

-- Estado COMPARTILHADO por todas as instâncias do plugin.
-- O PluginLoader carrega este módulo uma única vez (dofile, em pluginloader.lua),
-- e tanto o FileManager quanto o ReaderUI instanciam ESTA mesma classe. Logo,
-- estas variáveis locais funcionam como "estáticos de classe": sobrevivem à
-- troca estante <-> leitor dentro da mesma execução do KOReader.
local startup_shown = false   -- guard: no máximo um popup de inicialização por sessão
local active_viewer = nil     -- evita dois popups simultâneos (ex.: Resume disparado 2x)

-- Acima deste tamanho (em caracteres) a citação é truncada com "…" e ganha "mais".
local PREVIEW_CHARS = 180

-- Atribuição "Título - Autor": itálica e sutilmente menor que o corpo (infofont = 24).
local ATTR_FONT = "NotoSans-Italic.ttf"
local ATTR_FONT_SIZE = 20

-- ÍNDICE de destaques --------------------------------------------------------
-- Para sortear entre TODOS os destaques de TODOS os livros (não só o histórico)
-- sem travar nem estourar memória, mantemos um índice minúsculo: para cada
-- sidecar `metadata.*.lua` encontrado na biblioteca guardamos apenas
-- { mtime, count } — a quantidade de destaques daquele livro. O sorteio escolhe
-- um livro PONDERADO por count (equivale a sortear uniformemente entre todos os
-- destaques) e só então abre AQUELE sidecar. A varredura roda em fatias no
-- background e é persistida; sessões seguintes só reparseiam o que mudou (mtime).
local CACHE_VERSION = 2
local SCAN_DIRS_PER_TICK = 40   -- diretórios visitados por fatia da varredura
local SCAN_INTERVAL = 0.05      -- pausa (s) entre fatias, para a UI respirar

local index = nil          -- { [metadata_path] = { mtime = N, count = N } }
local index_store = nil    -- LuaSettings (persistência do índice)
local entries = nil        -- forma derivada p/ sorteio: { {path=, count=}, ... }
local total_count = 0       -- soma dos counts (nº total de destaques indexados)

local scanned_once = false  -- já varremos nesta sessão?
local scan_active = false   -- varredura em andamento?
local scan_changed = false  -- o índice mudou nesta varredura? (define se salva)
local scan_stack = nil      -- pilha de diretórios a visitar
local scan_seen = nil       -- conjunto de caminhos vistos (p/ podar removidos)

-- Semente do RNG (uma vez, no carregamento do módulo).
math.randomseed(os.time())

local RandomHighlight = WidgetContainer:extend{
    name = "destaquealeatorio",
}

-- Extrai a lista de destaques { text, note } de UMA tabela de
-- sidecar, com a MESMA cobertura do KOReader (ReaderAnnotation:onReadSettings):
--   * formato NOVO `annotations` (array): um destaque tem `drawer` (o marcador de
--     página simples não tem) e `text` não vazio. Se a chave existe, ela MANDA
--     (mesmo vazia) — igual à precedência nativa.
--   * formato LEGADO `bookmarks`/`highlight` (versões antigas, migradas só ao
--     ABRIR o livro): um destaque é um bookmark com `highlighted == true`; o texto
--     destacado = `bm.notes`, a nota = `bm.text` (mapeamento de `buildAnnotation`).
--   * caso pré-2014: destaques só na tabela `highlight` (page-keyed), sem virar
--     bookmarks — usados apenas se não houver nenhum destaque nos bookmarks.
local function extractHighlights(annotations, bookmarks, highlights)
    local items = {}
    if type(annotations) == "table" then  -- presença da chave => formato novo manda
        for _, a in ipairs(annotations) do
            if a.drawer and type(a.text) == "string" and a.text ~= "" then
                items[#items + 1] = { text = a.text, note = a.note }
            end
        end
        return items
    end
    if type(bookmarks) == "table" then
        for _, bm in ipairs(bookmarks) do
            if bm.highlighted and type(bm.notes) == "string" and bm.notes ~= "" then
                local note = bm.text
                if note == "" or note == bm.notes then note = nil end  -- "" ou auto-texto
                items[#items + 1] = { text = bm.notes, note = note }
            end
        end
    end
    if #items == 0 and type(highlights) == "table" then  -- pré-2014: só tabela 'highlight'
        for _, page_hls in pairs(highlights) do
            if type(page_hls) == "table" then
                for _, hl in ipairs(page_hls) do
                    if type(hl.text) == "string" and hl.text ~= "" then
                        items[#items + 1] = { text = hl.text }
                    end
                end
            end
        end
    end
    return items
end

-- Reconstrói o caminho do livro a partir do caminho do sidecar.
-- Ex.: /foo/Livro.sdr/metadata.epub.lua  ->  /foo/Livro.epub
-- (o diretório .sdr NÃO inclui a extensão; ela vem do nome metadata.<ext>.lua).
local function docPathFromMetadata(meta_path)
    local dir, ext = meta_path:match("^(.*)/metadata%.(.+)%.lua$")
    if not dir then return nil end
    local base = dir:match("^(.*)%.sdr$")
    if not base then return nil end
    return base .. "." .. ext
end

-- Contagem BARATA de destaques de um sidecar: dofile direto + extração, sem montar
-- props nem abrir o documento. Usada durante a varredura. Robusta a arquivos
-- corrompidos/vazios (retorna 0).
local function countItems(meta_path)
    local ok, t = pcall(dofile, meta_path)
    if not ok or type(t) ~= "table" then return 0 end
    return #extractHighlights(t.annotations, t.bookmarks, t.highlight)
end

-- Carga COMPLETA dos destaques de UM livro (usada na hora de exibir): combina
-- doc_props (originais) com os custom_props editados pelo usuário (custom vence,
-- igual à tela nativa "Informações do livro"). Pode LANÇAR se o sidecar estiver
-- corrompido; o chamador isola com pcall.
local function loadItems(doc_path)
    local ds = DocSettings:open(doc_path)
    local items = extractHighlights(ds:readSetting("annotations"),
                                    ds:readSetting("bookmarks"),
                                    ds:readSetting("highlight"))
    if #items == 0 then return items end
    local props = FileManagerBookInfo.extendProps(ds:readSetting("doc_props"), doc_path)
    local title = props.display_title
    local authors = props.authors
    for _, it in ipairs(items) do
        it.title = title
        it.authors = authors
    end
    return items
end

-- Locais varridos = os locais de sidecar `.sdr` que o KOReader usa (DocSettings):
--   * "doc"  : ao lado do livro       -> raiz = home_dir (+ home_dirs)
--   * "dir"  : pasta central          -> DataStorage:getDocSettingsDir()
--   * "hash" : pasta central por hash -> DataStorage:getDocSettingsHashDir()
-- Só inclui as que existem; descarta raízes aninhadas em outra (não varrer 2x).
-- LIMITAÇÃO CONHECIDA: a pasta legada `history/` (DataStorage:getHistoryDir()) NÃO
-- é varrida — lá os arquivos são planos (`[#caminho#] Nome.ext.lua`), fora de
-- `.sdr` e fora do padrão `metadata.<ext>.lua`, então nem a descoberta nem
-- docPathFromMetadata os reconhecem. É um local depreciado (o KOReader migrou dele
-- há anos) que só sobrevive como último candidato em `DocSettings:open`.
local function scanRoots()
    local raw, seen = {}, {}
    local function add(dir)
        if dir and dir ~= "" and not seen[dir]
                and lfs.attributes(dir, "mode") == "directory" then
            seen[dir] = true
            raw[#raw + 1] = dir
        end
    end
    add(G_reader_settings:readSetting("home_dir"))
    local home_dirs = G_reader_settings:readSetting("home_dirs")
    if type(home_dirs) == "table" then
        for _, d in ipairs(home_dirs) do add(d) end
    end
    add(DataStorage:getDocSettingsDir())
    add(DataStorage:getDocSettingsHashDir())
    if #raw == 0 then add(filemanagerutil.getDefaultDir()) end
    local roots = {}
    for _, r in ipairs(raw) do
        local nested = false
        for _, other in ipairs(raw) do
            if other ~= r and r:sub(1, #other + 1) == other .. "/" then
                nested = true
                break
            end
        end
        if not nested then roots[#roots + 1] = r end
    end
    return roots
end

local function indexCachePath()
    return DataStorage:getSettingsDir() .. "/destaquealeatorio_index.lua"
end

-- (Re)constrói a forma derivada usada no sorteio ponderado. A ordenação por
-- caminho torna a amostragem determinística/reproduzível (não muda a
-- distribuição: o sorteio ponderado é correto em qualquer ordem).
local function rebuildEntries()
    entries = {}
    total_count = 0
    for path, e in pairs(index) do
        if e.count and e.count > 0 then
            entries[#entries + 1] = { path = path, count = e.count }
            total_count = total_count + e.count
        end
    end
    table.sort(entries, function(a, b) return a.path < b.path end)
end

-- Carrega o índice do disco (uma vez). Versão incompatível => começa do zero.
local function loadIndex()
    if index then return end
    index_store = LuaSettings:open(indexCachePath())
    if index_store:readSetting("version") == CACHE_VERSION then
        index = index_store:readSetting("entries") or {}
    else
        index = {}
    end
    rebuildEntries()
end

local function saveIndex()
    if not index_store then return end
    index_store:saveSetting("version", CACHE_VERSION)
    index_store:saveSetting("entries", index)
    index_store:flush()
end

-- Indexa UM sidecar: reusa o cache se o mtime não mudou; senão, recalcula count.
local function indexMetaFile(meta_path)
    scan_seen[meta_path] = true
    local mtime = lfs.attributes(meta_path, "modification")
    local cached = index[meta_path]
    if cached and cached.mtime == mtime then return end
    index[meta_path] = { mtime = mtime, count = countItems(meta_path) }
    scan_changed = true
end

-- Uma FATIA da varredura: visita até SCAN_DIRS_PER_TICK diretórios da pilha.
-- Retorna true se ainda há diretórios a visitar.
local function scanStep()
    local processed = 0
    while #scan_stack > 0 and processed < SCAN_DIRS_PER_TICK do
        local dir = table.remove(scan_stack)
        processed = processed + 1
        local ok, iter, dir_obj = pcall(lfs.dir, dir)
        if ok then
            for name in iter, dir_obj do
                if name ~= "." and name ~= ".." then
                    local path = dir .. "/" .. name
                    local mode = lfs.attributes(path, "mode")
                    if mode == "directory" then
                        scan_stack[#scan_stack + 1] = path
                    elseif mode == "file" and name:match("^metadata%..+%.lua$") then
                        indexMetaFile(path)
                    end
                end
            end
        end
    end
    return #scan_stack > 0
end

local function finishScan()
    -- poda entradas de livros que sumiram da biblioteca
    for path in pairs(index) do
        if not scan_seen[path] then
            index[path] = nil
            scan_changed = true
        end
    end
    rebuildEntries()
    if scan_changed then saveIndex() end
    scan_stack, scan_seen = nil, nil
    scan_active = false
    scanned_once = true
    logger.dbg("Destaque aleatório: índice com", #entries, "livros,", total_count, "destaques")
end

local function scanTick()
    if scanStep() then
        UIManager:scheduleIn(SCAN_INTERVAL, scanTick)
    else
        finishScan()
    end
end

-- Inicia a varredura incremental (no máximo uma por sessão, salvo `force`).
local function startScan(force)
    if scan_active then return end
    if scanned_once and not force then return end
    local roots = scanRoots()
    if #roots == 0 then return end
    loadIndex()
    scan_active = true
    scan_changed = false
    scan_seen = {}
    scan_stack = {}
    for _, r in ipairs(roots) do scan_stack[#scan_stack + 1] = r end
    UIManager:scheduleIn(SCAN_INTERVAL, scanTick)
end

-- Sorteia um destaque a partir do índice (ponderado por count => equiprovável
-- por destaque). Tolera entradas obsoletas (livro removido/alterado) tentando
-- algumas vezes. Abre apenas o sidecar do livro escolhido.
local function pickFromIndex()
    if total_count <= 0 then return nil end
    for _ = 1, 5 do
        local r = math.random(total_count)
        local chosen
        for _, e in ipairs(entries) do
            r = r - e.count
            if r <= 0 then chosen = e.path break end
        end
        if not chosen then return nil end
        local doc_path = docPathFromMetadata(chosen)
        if doc_path then
            local ok, items = pcall(loadItems, doc_path)
            if ok and #items > 0 then
                return items[math.random(#items)]
            end
        end
    end
    return nil
end

-- Arranque a frio (índice ainda vazio): sorteio preguiçoso pelo histórico, para
-- o primeiro popup já aparecer enquanto a varredura completa roda no background.
local function pickFromHistory()
    local hist = ReadHistory.hist
    local n = #hist
    if n == 0 then return nil end
    -- percorre o histórico em ordem aleatória e para no 1º livro com destaques
    local order = {}
    for i = 1, n do order[i] = i end
    for i = n, 2, -1 do
        local j = math.random(i)
        order[i], order[j] = order[j], order[i]
    end
    for _, i in ipairs(order) do
        local file = hist[i].file
        if file and lfs.attributes(file, "mode") == "file" then
            local ok, items = pcall(loadItems, file)
            if ok and #items > 0 then
                return items[math.random(#items)]
            end
        end
    end
    return nil
end

local function pickRandomItem()
    loadIndex()
    return pickFromIndex() or pickFromHistory()
end

-- Atribuição exibida abaixo da citação, no padrão "Título - Autor" ("" se faltarem ambos).
local function attributionText(item)
    local parts = {}
    if item.title and item.title ~= "" then parts[#parts + 1] = item.title end
    if item.authors and item.authors ~= "" then parts[#parts + 1] = item.authors end
    return table.concat(parts, " - ")
end

-- Texto completo, usado na visão expandida ("mais"): citação + nota + autor.
-- Ao final, SÓ o autor (sem capítulo/página). O TextViewer usa fonte e alinhamento
-- únicos para o bloco todo, então itálico/alinhamento à direita só na linha do
-- autor não são possíveis ali — fica em texto normal, precedido de travessão.
local function formatFull(item)
    local lines = { "“" .. item.text .. "”" }
    if type(item.note) == "string" and item.note ~= "" then
        lines[#lines + 1] = ""
        lines[#lines + 1] = T(_("Nota: %1"), item.note)
    end
    if item.authors and item.authors ~= "" then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "— " .. item.authors
    end
    return table.concat(lines, "\n")
end

-- Mostra o popup e o registra como "ativo". O teste de duplicado (em
-- showRandomHighlight) consulta o estado REAL do UIManager (isWidgetShown) sobre
-- esta referência — assim não dependemos de o fechamento passar pelo nosso
-- código (que era frágil: o evento CloseWidget pode ser consumido por um filho).
local function track(widget)
    active_viewer = widget
    UIManager:show(widget)
end

-- Popup pequeno (caso curto): citação no corpo + "Título - Autor" em itálico
-- menor, tudo centralizado, sem botões — fecha a qualquer toque/tecla.
local QuoteWidget = InputContainer:extend{
    quote = nil,        -- citação já entre aspas
    attribution = nil,  -- "Título - Autor" (pode ser "")
}

function QuoteWidget:init()
    self.ges_events = {}
    self.key_events = {}
    local frame_w = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.8)
    local inner_w = frame_w - 2 * Size.padding.large

    local group = VerticalGroup:new{ align = "center" }
    table.insert(group, TextBoxWidget:new{
        text = self.quote,
        face = Font:getFace("infofont"),
        width = inner_w,
        alignment = "center",
    })
    if self.attribution and self.attribution ~= "" then
        table.insert(group, VerticalSpan:new{ width = Size.span.vertical_large })
        table.insert(group, TextBoxWidget:new{
            text = self.attribution,
            face = Font:getFace(ATTR_FONT, ATTR_FONT_SIZE),
            width = inner_w,
            alignment = "center",
        })
    end

    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        radius = Size.radius.window,
        padding = Size.padding.large,
        group,
    }
    self[1] = CenterContainer:new{
        dimen = Screen:getSize(),
        self.frame,
    }

    if Device:isTouchDevice() then
        self.ges_events.TapClose = {
            GestureRange:new{
                ges = "tap",
                range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() },
            },
        }
    end
    if Device:hasKeys() then
        self.key_events.AnyKeyPressed = { { Device.input.group.Any } }
    end
end

function QuoteWidget:onShow()
    -- força o refresh do e-ink na região do popup; sem isto, em alguns refreshes
    -- o popup curto não era pintado e "nada acontecia" ao pedir um destaque
    UIManager:setDirty(self, function()
        return "ui", self.frame.dimen
    end)
    return true
end

function QuoteWidget:onTapClose()
    UIManager:close(self)
    return true
end
QuoteWidget.onAnyKeyPressed = QuoteWidget.onTapClose

-- Visão expandida (tela cheia) com o destaque inteiro, nota e autor.
local function showFull(item)
    local viewer
    viewer = TextViewer:new{
        title = item.title or _("Destaque"),
        title_multilines = true,
        text = formatFull(item),
        text_type = "bookmark",
        buttons_table = {
            {
                {
                    text = _("Fechar"),
                    callback = function() UIManager:close(viewer) end,
                },
            },
        },
    }
    track(viewer)
end

-- Sorteia e exibe um destaque. `manual` = chamado pelo menu (força revarredura e
-- avisa se nada for encontrado).
local function showRandomHighlight(manual)
    -- evita empilhar popups (ex.: Resume disparado 2x), mas pelo estado REAL do
    -- UIManager: se o popup anterior já foi fechado, seguimos em frente
    if active_viewer and UIManager:isWidgetShown(active_viewer) then return end

    if manual then startScan(true) end  -- atualiza o índice no background (não bloqueia)

    local item = pickRandomItem()
    if not item then
        if manual then
            UIManager:show(InfoMessage:new{
                text = _("Nenhum destaque encontrado nos seus livros."),
            })
        end
        return
    end

    local attr = attributionText(item)
    local chars = util.splitToChars(item.text)

    if #chars > PREVIEW_CHARS then
        -- citação longa: pré-visualização truncada (…) + botão "mais"
        local preview = table.concat(chars, "", 1, PREVIEW_CHARS)
        local sp = preview:find("%s%S*$")  -- corta no último espaço p/ não partir palavra
        if sp and sp > PREVIEW_CHARS / 2 then
            preview = preview:sub(1, sp - 1)
        end
        local dialog
        dialog = ButtonDialog:new{
            title = "“" .. preview .. "…”",  -- citação no corpo (info_face, centralizada)
            title_align = "center",
            buttons = {
                {
                    {
                        text = _("mais"),
                        callback = function()
                            UIManager:close(dialog)
                            showFull(item)
                        end,
                    },
                },
            },
        }
        if attr ~= "" then  -- "Título - Autor" em itálico menor, abaixo da citação
            dialog:addWidget(TextBoxWidget:new{
                text = attr,
                face = Font:getFace(ATTR_FONT, ATTR_FONT_SIZE),
                width = dialog:getAddedWidgetAvailableWidth(),
                alignment = "center",
            })
        end
        track(dialog)
    else
        -- citação curta: popup pequeno, sem botões, fecha ao toque
        track(QuoteWidget:new{
            quote = "“" .. item.text .. "”",
            attribution = attr,
        })
    end
end

function RandomHighlight:init()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    -- constrói/atualiza o índice no background assim que o plugin carrega, para
    -- que o popup (e o "Ver um destaque agora") tenham os dados prontos
    startScan(false)
    if not startup_shown and G_reader_settings:nilOrTrue("destaquealeatorio_on_startup") then
        startup_shown = true
        -- adia para a UI assentar (estante ou leitor já desenhados) e para não
        -- pagar o custo no caminho crítico de inicialização
        UIManager:scheduleIn(1, function()
            showRandomHighlight(false)
        end)
    end
end

function RandomHighlight:onResume()
    if G_reader_settings:nilOrTrue("destaquealeatorio_on_resume") then
        -- adia ~1,5s para a tela de suspensão fechar antes de o popup surgir
        UIManager:scheduleIn(1.5, function()
            showRandomHighlight(false)
        end)
    end
end

function RandomHighlight:addToMainMenu(menu_items)
    menu_items.destaque_aleatorio = {
        text = _("Destaque aleatório"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text = _("Mostrar ao abrir o KOReader"),
                checked_func = function()
                    return G_reader_settings:nilOrTrue("destaquealeatorio_on_startup")
                end,
                callback = function()
                    G_reader_settings:flipNilOrTrue("destaquealeatorio_on_startup")
                end,
            },
            {
                text = _("Mostrar ao retornar da suspensão"),
                checked_func = function()
                    return G_reader_settings:nilOrTrue("destaquealeatorio_on_resume")
                end,
                callback = function()
                    G_reader_settings:flipNilOrTrue("destaquealeatorio_on_resume")
                end,
            },
            {
                text = _("Ver um destaque agora"),
                keep_menu_open = true,
                separator = true,
                callback = function()
                    showRandomHighlight(true)
                end,
            },
        },
    }
end

return RandomHighlight
