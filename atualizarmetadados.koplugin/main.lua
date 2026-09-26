--[[--
Google Books — agregador de metadados por ISBN para KOReader.

Inspirado no motor de download de metadados do Calibre: consulta várias fontes
gratuitas em paralelo (Google Books, Open Library, Inventaire/Wikidata e Amazon
BR/COM), agrega os resultados campo a campo por prioridade de fonte, reúne todas
as capas candidatas e escolhe a de maior qualidade.

O resultado é exibido numa janela dedicada (KeyValuePage) onde cada campo pode
ser tocado individualmente para edição antes de gravar no livro.
]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager       = require("ui/uimanager")
local InfoMessage     = require("ui/widget/infomessage")
local InputDialog     = require("ui/widget/inputdialog")
local ButtonDialog    = require("ui/widget/buttondialog")
local TextViewer      = require("ui/widget/textviewer")
local ImageViewer     = require("ui/widget/imageviewer")
local KeyValuePage    = require("ui/widget/keyvaluepage")
local TitleBar        = require("ui/widget/titlebar")
local NetworkMgr      = require("ui/network/manager")
local DocSettings     = require("docsettings")
local DataStorage     = require("datastorage")
local lfs             = require("libs/libkoreader-lfs")
local Event           = require("ui/event")
local FileManager     = require("apps/filemanager/filemanager")
local FileManagerHistory    = require("apps/filemanager/filemanagerhistory")
local FileManagerCollection = require("apps/filemanager/filemanagercollection")
local FileManagerFileSearcher = require("apps/filemanager/filemanagerfilesearcher")
local FileManagerBookInfo = require("apps/filemanager/filemanagerbookinfo")
local RenderImage     = require("ui/renderimage")
local util            = require("util")
local http            = require("socket.http")
local ltn12           = require("ltn12")
local socketutil      = require("socketutil")
local json            = require("json")
local logger          = require("logger")
local GetText         = require("gettext")
local _               = GetText
-- Traduções conforme o idioma escolhido no KOReader (ver fineko_i18n.lua).
require("fineko_i18n").load(debug.getinfo(1, "S").source:match("@(.*/)"), "fineko")
local T               = require("ffi/util").template

-- Mapeia QIDs de idioma do Wikidata (usados pelo Inventaire) para códigos ISO.
local LANG_QIDS = {
    ["wd:Q1860"]="en", ["wd:Q5146"]="pt", ["wd:Q150"]="fr",
    ["wd:Q188"]="de",  ["wd:Q1321"]="es", ["wd:Q652"]="it",
    ["wd:Q7737"]="ru", ["wd:Q9067"]="ja", ["wd:Q9610"]="bn",
    ["wd:Q9240"]="id",
}

local UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
-- Accept-Encoding: identity é OBRIGATÓRIO: o LuaSocket não descomprime gzip e
-- a Amazon comprime por padrão — sem isso, o HTML chega como bytes comprimidos
-- e nenhum padrão de extração casa (a Amazon "nunca encontrava nada").
local HEADERS_BROWSER = {
    ["User-Agent"] = UA,
    ["Accept-Language"] = "pt-BR,pt;q=0.9,en;q=0.8",
    ["Accept-Encoding"] = "identity",
}

-- Prioridade de cada fonte ao mesclar campos e ao desempatar capas de mesma
-- resolução. Espelha a confiança que o Calibre dá a cada provedor.
local SOURCE_BONUS = {
    amazon_br = 3.0, amazon_com = 2.5,
    google = 2.0, openlibrary = 1.5, openlibrary_isbn = 1.4,
    inventaire = 1.0, bing_images = 0.6,
}

-- Os 14 domínios da Amazon raspados em cascata (mesma lista do Calibre).
-- O idioma é o da vitrine — usado para ordenar a cascata (domínios no idioma
-- alvo primeiro) e para a coerência de idioma no merge.
local AMAZON_DOMAINS = {
    { id = "amazon_br",  domain = "amazon.com.br", lang = "pt" },
    { id = "amazon_com", domain = "amazon.com",    lang = "en" },
    { id = "amazon_uk",  domain = "amazon.co.uk",  lang = "en" },
    { id = "amazon_de",  domain = "amazon.de",     lang = "de" },
    { id = "amazon_fr",  domain = "amazon.fr",     lang = "fr" },
    { id = "amazon_es",  domain = "amazon.es",     lang = "es" },
    { id = "amazon_it",  domain = "amazon.it",     lang = "it" },
    { id = "amazon_jp",  domain = "amazon.co.jp",  lang = "ja" },
    { id = "amazon_in",  domain = "amazon.in",     lang = "en" },
    { id = "amazon_nl",  domain = "amazon.nl",     lang = "nl" },
    { id = "amazon_ca",  domain = "amazon.ca",     lang = "en" },
    { id = "amazon_au",  domain = "amazon.com.au", lang = "en" },
    { id = "amazon_se",  domain = "amazon.se",     lang = "sv" },
    { id = "amazon_cn",  domain = "amazon.cn",     lang = "zh" },
}
for _i, d in ipairs(AMAZON_DOMAINS) do
    if not SOURCE_BONUS[d.id] then SOURCE_BONUS[d.id] = 2.2 end
end

-- Limite de domínios Amazon por busca. A lista completa (14 domínios, com
-- /dp + /s + eventual Wayback cada) tornava a busca longa demais; 4 cobre o
-- idioma alvo (primeiro na ordem) e os maiores mercados.
local MAX_AMAZON_DOMAINS = 4

-- Ordena a cascata: domínios no idioma alvo primeiro, demais na ordem da lista.
local function orderedAmazonDomains(target_lang)
    local ordered = {}
    for _i, d in ipairs(AMAZON_DOMAINS) do
        if target_lang and d.lang == target_lang then table.insert(ordered, d) end
    end
    for _i, d in ipairs(AMAZON_DOMAINS) do
        if not (target_lang and d.lang == target_lang) then table.insert(ordered, d) end
    end
    return ordered
end

-- Critério de parada da busca em cascata: campos essenciais (título, autor,
-- descrição, idioma) preenchidos por alguma fonte e ao menos uma capa
-- candidata. Série e palavras-chave ficam de fora — são raros/têm
-- predefinições e impediriam a parada antecipada na maioria dos livros.
local function essentialsComplete(results)
    local have_title, have_authors, have_desc, have_lang, have_cover =
        false, false, false, false, false
    for _i, r in ipairs(results) do
        if r.data.title       and r.data.title ~= ""       then have_title = true end
        if r.data.authors     and r.data.authors ~= ""     then have_authors = true end
        if r.data.description and r.data.description ~= "" then have_desc = true end
        if r.data.language    and r.data.language ~= ""    then have_lang = true end
        if r.data.cover_candidates and #r.data.cover_candidates > 0 then have_cover = true end
    end
    return have_title and have_authors and have_desc and have_lang and have_cover
end


-- Campos canônicos do KOReader (doc_props). ATENÇÃO: as chaves precisam ser
-- exatamente estas — `series_index` e `keywords`, não `series_number`/`tags` —
-- senão a tela nativa "Informações do livro" não exibe o que gravamos.
local FIELDS = {
    { key = "title",        label = _("Título") },
    { key = "authors",      label = _("Autor(es)") },
    { key = "series",       label = _("Série") },
    { key = "series_index", label = _("Número na série") },
    { key = "language",     label = _("Idioma") },
    { key = "keywords",     label = _("Palavras-chave") },
    { key = "description",  label = _("Descrição") },
}

-- Categorias predefinidas oferecidas SEMPRE no seletor de palavras-chave,
-- além dos resultados das fontes — padroniza a classificação da biblioteca.
local KEYWORD_PRESETS = {
    "Autoajuda, Desenvolvimento Pessoal, Motivação",
    "Biografia, Autobiografia, Memórias",
    "Negócios, Finanças, Economia",
    "Ficção, Romance, Literatura",
    "História, Geopolítica, Política",
    "Filosofia, Sociologia, Ciências Humanas",
    "Religião, Espiritualidade, Fé",
    "Psicologia, Saúde Mental, Comportamento",
    "Ciências, Tecnologia, Computação",
    "Fantasia, Ficção Científica, Sci-Fi",
    "Policial, Suspense, Terror",
}

local AtualizarMetadados = WidgetContainer:extend{
    name = "atualizarmetadados",
}

--==========================================================================--
-- Utilitários de rede
--==========================================================================--

-- GET simples: devolve (corpo, status HTTP). Corpo só em HTTP 200; o status
-- permite ao chamador distinguir "não existe" (404) de bloqueio/falha de rede.
local function httpGet(url, headers)
    local sink = {}
    local req = {
        url = url,
        sink = ltn12.sink.table(sink),
        headers = headers or { ["Accept-Encoding"] = "identity" },
        redirect = true,
    }
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local ok, code = pcall(function()
        return require("socket").skip(1, http.request(req))
    end)
    socketutil:reset_timeout()
    if ok and code == 200 then
        local body = table.concat(sink)
        -- Servidor ignorou o identity e mandou gzip (magic 1F 8B): sem
        -- descompressor portátil aqui, falhar limpo é melhor que parsear lixo.
        if body:sub(1, 2) == "\31\139" then return nil, code end
        return body, code
    end
    return nil, ok and code or nil
end

-- Diretório temporário GRAVÁVEL em toda plataforma. "/tmp" não serve: no
-- Android (ex.: Onyx Boox) ele não existe nem é acessível ao app, e o download
-- da capa falhava silenciosamente (io.open → nil) resultando em "nenhuma capa
-- válida", embora os metadados — baixados em memória — funcionassem. O cache
-- do KOReader é criado na inicialização e existe em desktop, Kindle, Kobo,
-- PocketBook e Android. Usa-se uma SUBPASTA dedicada para poder limpar todo o
-- conteúdo com segurança (sem tocar em outros arquivos de cache do KOReader).
local TMP_DIR = DataStorage:getDataDir() .. "/cache/atualizarmetadados"
lfs.mkdir(TMP_DIR) -- idempotente; o pai "cache" já existe desde a init

-- Remove TODAS as capas temporárias da subpasta dedicada. Chamada antes de
-- baixar (descarta resíduo de uma janela fechada sem aplicar) e depois de
-- aplicar (a escolhida já foi COPIADA para o sidecar por flushCustomCover, as
-- demais não são mais necessárias) — assim nada de capa fica acumulado.
local function clearCoverCache()
    pcall(function()
        for entry in lfs.dir(TMP_DIR) do
            if entry ~= "." and entry ~= ".." then
                os.remove(TMP_DIR .. "/" .. entry)
            end
        end
    end)
end

-- Teto de segurança para capas vindas de scraping (Bing/Amazon): evita encher
-- o cache com um arquivo gigante ou um fluxo sem fim.
local MAX_COVER_BYTES = 20 * 1024 * 1024

-- Baixa uma URL diretamente para um arquivo. Devolve true em caso de HTTP 200
-- com corpo não vazio; em qualquer outro caso remove o arquivo parcial.
local function httpDownloadFile(url, path)
    local f = io.open(path, "wb")
    if not f then return false end
    socketutil:set_timeout(15, 60)
    local received = 0
    local file_sink = ltn12.sink.file(f)
    local ok, code = pcall(function()
        return require("socket").skip(1, http.request({
            url = url,
            sink = function(chunk, err)
                if chunk and received + #chunk > MAX_COVER_BYTES then
                    return nil, "capa maior que o limite"
                end
                received = received + (chunk and #chunk or 0)
                return file_sink(chunk, err)
            end,
            headers = HEADERS_BROWSER,
            redirect = true,
        }))
    end)
    socketutil:reset_timeout()
    -- ltn12.sink.file fecha o arquivo ao receber nil no fim do stream, mas
    -- numa falha antes do corpo o arquivo ficaria aberto até o GC.
    if io.type(f) == "file" then f:close() end
    if ok and code == 200 and received > 0 then
        return true
    end
    os.remove(path)
    return false
end

--==========================================================================--
-- Normalização
--==========================================================================--

local function trim(s)
    if type(s) ~= "string" then return s end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Percent-encoding correto (acentos UTF-8 viram %C3%A7 etc.; espaço vira +).
local function urlEncode(s)
    s = tostring(s or "")
    s = s:gsub("[^%w%-%.%_%~ ]", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    return (s:gsub(" ", "+"))
end

-- Limpa um campo de descrição (pode vir com HTML de qualquer fonte).
local function cleanDescription(s)
    if type(s) ~= "string" or s == "" then return nil end
    s = util.htmlToPlainTextIfHtml(s)
    s = trim(s)
    return s ~= "" and s or nil
end

-- Forma canônica de um valor para dedup/comparação (minúsculo, espaços
-- colapsados) — usada no merge e no seletor de palavras-chave.
local function normValue(v)
    return (tostring(v):lower():gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

--==========================================================================--
-- Idioma: detecção por ISBN, normalização e checagem de coerência
--==========================================================================--

-- Códigos MARC (3 letras, usados pela Open Library) → ISO 639-1 (2 letras).
local MARC_TO_ISO = {
    por="pt", eng="en", spa="es", fre="fr", fra="fr", ger="de", deu="de",
    ita="it", dut="nl", nld="nl", rus="ru", jpn="ja", chi="zh", zho="zh",
    kor="ko", swe="sv", pol="pl", cat="ca", glg="gl",
}

-- Normaliza qualquer rótulo de idioma para ISO 639-1 minúsculo
-- ("pt-BR"→"pt", "por"→"pt"). Devolve nil se não reconhecer.
local function normalizeLang(code)
    if type(code) ~= "string" or code == "" then return nil end
    code = code:lower():gsub("[^%a].*$", "") -- "pt-br"→"pt", "por (brazil)"→"por"
    if #code == 2 then return code end
    return MARC_TO_ISO[code]
end

-- Prefixos do ISBN-13 → idioma esperado da EDIÇÃO. Sinal forte, gratuito e
-- offline: o grupo de registro do ISBN indica o país/idioma de publicação.
local ISBN_LANG_PREFIXES = {
    {"9780","en"},{"9781","en"},{"9798","en"},
    {"9782","fr"},{"97910","fr"},
    {"9783","de"},
    {"9784","ja"},
    {"9785","ru"},
    {"9787","zh"},
    {"97865","pt"},{"97885","pt"},{"978972","pt"},{"978989","pt"}, -- Brasil + Portugal
    {"97884","es"},{"978950","es"},{"978987","es"},{"978607","es"},
    {"978968","es"},{"978970","es"},{"978958","es"},{"978956","es"},
    {"97888","it"},{"97912","it"},
    {"97889","ko"},{"97911","ko"},
    {"97890","nl"},{"97894","nl"},
    {"97891","sv"},
}
table.sort(ISBN_LANG_PREFIXES, function(a, b) return #a[1] > #b[1] end) -- maior prefixo primeiro

local function detectLanguageFromISBN(isbn)
    isbn = (isbn or ""):gsub("[^%dXx]", "")
    if #isbn == 10 then isbn = "978" .. isbn end
    if #isbn ~= 13 then return nil end
    for _i, p in ipairs(ISBN_LANG_PREFIXES) do
        if isbn:sub(1, #p[1]) == p[1] then return p[2] end
    end
    return nil
end

-- Converte ISBN-13 (prefixo 978) para ISBN-10. Na Amazon, o ASIN de um livro
-- físico é o próprio ISBN-10, o que permite acessar a página do produto
-- diretamente via /dp/{isbn10}, sem passar pela busca (mais protegida).
local function isbn13to10(isbn)
    isbn = (isbn or ""):gsub("[^%dXx]", "")
    if #isbn == 10 then return isbn end
    if #isbn ~= 13 or isbn:sub(1, 3) ~= "978" then return nil end
    local core = isbn:sub(4, 12)
    local sum = 0
    for i = 1, 9 do
        sum = sum + tonumber(core:sub(i, i)) * (11 - i)
    end
    local check = (11 - sum % 11) % 11
    return core .. (check == 10 and "X" or tostring(check))
end

-- Remove acentos para comparação tolerante de títulos.
local function stripAccents(s)
    s = (s or ""):lower()
    local map = {
        ["á"]="a",["à"]="a",["ã"]="a",["â"]="a",["ä"]="a",["é"]="e",["è"]="e",["ê"]="e",
        ["í"]="i",["ì"]="i",["î"]="i",["ó"]="o",["ò"]="o",["ô"]="o",["õ"]="o",["ö"]="o",
        ["ú"]="u",["ù"]="u",["û"]="u",["ü"]="u",["ç"]="c",["ñ"]="n",
    }
    for from, to in pairs(map) do s = s:gsub(from, to) end
    return s
end

-- True se `a` está "contido" em `b` (sobreposição de tokens ≥ 34%). Usada para
-- descartar resultados fuzzy da Amazon que casaram com o livro errado.
local function titlesSimilar(a, b)
    if not a or not b or a == "" or b == "" then return true end -- sem base → não bloqueia
    local function tokens(s)
        local t, n = {}, 0
        for w in stripAccents(s):gmatch("%w+") do
            if #w >= 3 and not t[w] then t[w] = true; n = n + 1 end
        end
        return t, n
    end
    local ta, na = tokens(a)
    local tb = tokens(b)
    if na == 0 then return true end
    local inter = 0
    for w in pairs(ta) do if tb[w] then inter = inter + 1 end end
    return (inter / na) >= 0.34
end

--==========================================================================--
-- Ciclo de vida do plugin
--==========================================================================--

function AtualizarMetadados:init()
    if self.ui.document then
        return
    end
    self:setupFileDialogButtons()
end

function AtualizarMetadados:setupFileDialogButtons()
    local self_ref = self
    -- O menu de contexto de arquivo existe em 4 telas (estante, Histórico,
    -- Coleções e Busca de arquivos), cada uma com registro de botões e diálogo
    -- PRÓPRIOS — registrar só no FileManager deixaria o botão fora das demais.
    -- Padrão do plugin coverbrowser: registra em cada widget e fecha o menu da
    -- tela que abriu via widget.getMenuInstance().file_dialog.
    local widgets = {
        FileManager, FileManagerHistory, FileManagerCollection, FileManagerFileSearcher,
    }
    for _i, widget in ipairs(widgets) do
        FileManager.addFileDialogButtons(widget, "atualizarmetadados_1", function(file, is_file, book_props)
            if not is_file then return end
            return {{
                text = _("Buscar metadados"),
                callback = function()
                    local ok, menu = pcall(widget.getMenuInstance)
                    if ok and menu and menu.file_dialog then
                        UIManager:close(menu.file_dialog)
                        menu.file_dialog = nil
                    end
                    self_ref:showISBNDialog(file)
                end,
            }}
        end)
    end
end

--==========================================================================--
-- Entrada do ISBN
--==========================================================================--

function AtualizarMetadados:showISBNDialog(file)
    local dialog
    dialog = InputDialog:new{
        title = _("Buscar metadados — ISBN"),
        description = _("Digite o ISBN-10 ou ISBN-13 do livro.\nDeixe vazio para ver/editar os metadados atuais do documento."),
        input = "",
        buttons = {{
            { text = _("Cancelar"), id = "close",
              callback = function() UIManager:close(dialog) end },
            { text = _("Buscar"), is_enter_default = true,
              callback = function()
                  local isbn = dialog:getInputText():gsub("[%s%-]", ""):upper()
                  UIManager:close(dialog)
                  if isbn ~= "" then
                      -- ISBN-10: 9 dígitos + dígito/X; ISBN-13: 13 dígitos.
                      -- Sem validar, caracteres como &, / e ? quebrariam as
                      -- query strings dos endpoints (requisições malformadas).
                      local valid = (#isbn == 10 and isbn:match("^%d%d%d%d%d%d%d%d%d[%dX]$"))
                          or (#isbn == 13 and isbn:match("^%d+$"))
                      if not valid then
                          UIManager:show(InfoMessage:new{
                              text = _("ISBN inválido. Informe 10 ou 13 dígitos (apenas números)."),
                              icon = "notice-warning",
                          })
                          return
                      end
                      self:fetchMetadata(file, isbn)
                  else
                      -- Sem ISBN: pula a busca e abre os metadados atuais.
                      self:showLocalMetadata(file)
                  end
              end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Extrai o primeiro ISBN (formato 978/979…) de `identifiers`, que pode vir
-- como string ou lista dependendo do documento/provedor.
local function extractISBN(identifiers)
    if identifiers == nil then return nil end
    local ids
    if type(identifiers) == "table" then
        ids = table.concat(identifiers, " ")
    else
        ids = tostring(identifiers)
    end
    return ids:match("97[89][%d%-]+%d")
end

-- Metadados atuais do documento: doc_props (gravados na primeira abertura ou
-- extraídos do próprio arquivo) com os custom_props aplicados por cima — o
-- mesmo que a tela nativa "Informações do livro" exibe.
function AtualizarMetadados:getLocalProps(file)
    local original
    if self.ui and self.ui.bookinfo then
        local ok, p = pcall(self.ui.bookinfo.getDocProps, self.ui.bookinfo, file)
        if ok and type(p) == "table" then original = p end
    end
    -- `extendProps` só copia as chaves de BookInfo.props (title, authors, …);
    -- `identifiers` fica de fora, então preservamos explicitamente para
    -- conseguir extrair o ISBN local.
    local identifiers = original and original.identifiers
    if identifiers == nil then
        -- Alguns caminhos de getDocProps (ex.: coverbrowser) não devolvem
        -- identifiers; o doc_props gravado no sidecar é a fonte garantida.
        local ok_ds, ds = pcall(DocSettings.open, file)
        if ok_ds and ds then
            local saved = ds:readSetting("doc_props")
            if type(saved) == "table" then identifiers = saved.identifiers end
        end
    end
    local ok, props = pcall(FileManagerBookInfo.extendProps, original, file)
    props = (ok and type(props) == "table") and props or original or {}
    if identifiers ~= nil then props.identifiers = identifiers end
    return props
end

-- Monta a estrutura "merged" da janela de resultado a partir dos metadados
-- locais: cada campo preenchido vira a única opção (fonte "documento"), e o
-- ISBN é aproveitado dos identificadores do documento quando existir.
function AtualizarMetadados:buildLocalMerged(props)
    local merged = { cover_candidates = {}, _field_options = {} }
    for _i, f in ipairs(FIELDS) do
        local v = props[f.key]
        if v ~= nil and v ~= "" then
            merged[f.key] = v
            merged._field_options[f.key] = { { value = v, sources = { "documento" } } }
        end
    end
    local isbn = extractISBN(props.identifiers)
    if isbn then merged.isbn = isbn end
    return merged
end

-- Sem ISBN: pula a busca online e abre a MESMA janela de edição com os
-- metadados atuais do documento — editar e aplicar seguem o fluxo normal.
function AtualizarMetadados:showLocalMetadata(file)
    self:showResultWindow(file, self:buildLocalMerged(self:getLocalProps(file)))
end

--==========================================================================--
-- Fontes de metadados
--==========================================================================--

-- URLs de capa do Google para um ID de volume, na ordem de preferência:
-- "publisher/content" com zoom alto costuma trazer a melhor resolução;
-- "content" comum é o fallback.
local function addGoogleCovers(list, volume_id)
    table.insert(list, "https://books.google.com/books/publisher/content?id="
        .. volume_id .. "&printsec=frontcover&img=1&zoom=3&source=gbs_api")
    table.insert(list, "https://books.google.com/books/content?id="
        .. volume_id .. "&printsec=frontcover&img=1&zoom=3")
end

-- Google: cascata interna começando pelo feed GData — o método mais confiável
-- em DISPONIBILIDADE (sem a cota da API v1, que vive em HTTP 429). A API v1 é
-- consultada em seguida APENAS para complementar campos que faltaram (na
-- prática o nº na série, que só ela fornece); viewapi é o último recurso.
function AtualizarMetadados:searchGoogleBooks(isbn)
    local metadata = self:searchGoogleBooksGData(isbn)

    -- Algum campo ainda vazio? A v1 complementa (campo a campo, sem
    -- sobrescrever o que o GData já trouxe).
    local missing = metadata == nil
    if metadata then
        for _i, f in ipairs(FIELDS) do
            if metadata[f.key] == nil or metadata[f.key] == "" then
                missing = true
                break
            end
        end
    end

    if missing then
        local v1 = self:searchGoogleBooksV1(isbn)
        if v1 and not metadata then
            metadata = v1
        elseif v1 then
            for _i, f in ipairs(FIELDS) do
                if (metadata[f.key] == nil or metadata[f.key] == "") and v1[f.key] ~= nil then
                    metadata[f.key] = v1[f.key]
                end
            end
            local seen = {}
            for _j, u in ipairs(metadata.cover_candidates or {}) do seen[u] = true end
            for _j, u in ipairs(v1.cover_candidates or {}) do
                if not seen[u] then table.insert(metadata.cover_candidates, u) end
            end
        end
    end

    return metadata or self:searchGoogleBooksViewAPI(isbn)
end

function AtualizarMetadados:searchGoogleBooksV1(isbn)
    local body = httpGet("https://www.googleapis.com/books/v1/volumes?q=isbn:" .. isbn .. "&country=BR")
    if not body then return nil end

    local data_ok, data = pcall(json.decode, body)
    if not data_ok or not data or not data.items or #data.items == 0 then
        return nil
    end

    local item = data.items[1]
    local info = item.volumeInfo or {}
    local metadata = {}

    metadata.title = info.title
    if info.subtitle and info.subtitle ~= "" then
        metadata.title = (metadata.title or "") .. ": " .. info.subtitle
    end
    if info.authors then metadata.authors = table.concat(info.authors, ", ") end
    metadata.language = normalizeLang(info.language)
    metadata.description = cleanDescription(info.description)
    if info.categories then metadata.keywords = table.concat(info.categories, ", ") end

    if info.seriesInfo and info.seriesInfo.volumeSeries and info.seriesInfo.volumeSeries[1] then
        metadata.series_index = info.seriesInfo.volumeSeries[1].orderNumber
    end

    -- Capa: URLs por ID de volume primeiro; a thumbnail padrão entra como
    -- última candidata (fallback).
    metadata.cover_candidates = {}
    if item.id then
        addGoogleCovers(metadata.cover_candidates, item.id)
    end
    if info.imageLinks then
        local thumb = info.imageLinks.thumbnail or info.imageLinks.smallThumbnail
        if thumb then
            thumb = thumb:gsub("^http:", "https:"):gsub("&edge=curl", "")
            table.insert(metadata.cover_candidates, thumb)
        end
    end

    return metadata
end

-- Método principal do Google: o feed GData clássico — a MESMA fonte que o
-- plugin google do Calibre usa — devolve metadados completos em XML
-- Atom/Dublin Core e não sofre da cota da API v1.
function AtualizarMetadados:searchGoogleBooksGData(isbn)
    local body = httpGet("https://books.google.com/books/feeds/volumes?q=isbn:" .. isbn)
    if not body then return nil end
    local metadata = self:parseGDataFeed(body)

    -- O feed de BUSCA corta a descrição num snippet terminado em "...";
    -- o feed do VOLUME individual (a rota que o Calibre usa) traz o texto
    -- completo. Só vale a segunda requisição quando veio truncada (ou vazia).
    if metadata and metadata._volume_id then
        local d = metadata.description
        if not d or d:find("%.%.%.%s*$") or d:find("…%s*$") then
            local vbody = httpGet("https://books.google.com/books/feeds/volumes/"
                .. metadata._volume_id)
            if vbody then
                local vmeta = self:parseGDataFeed(vbody)
                if vmeta and vmeta.description
                        and (not d or #vmeta.description > #d) then
                    metadata.description = vmeta.description
                end
            end
        end
    end

    return metadata
end

function AtualizarMetadados:parseGDataFeed(body)
    -- No feed de busca a tag é <entry> pura; no feed de volume individual a
    -- raiz é <entry xmlns=...> — o padrão precisa aceitar atributos.
    local entry = body:match("<entry[^>]*>(.-)</entry>")
    if not entry then return nil end

    local function unescape(s)
        if not s then return nil end
        s = s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"')
             :gsub("&#39;", "'"):gsub("&apos;", "'"):gsub("&amp;", "&")
        return s
    end

    local metadata = { cover_candidates = {} }

    -- O feed traz <dc:title> repetido: o 1º é o título, o 2º o subtítulo.
    local titles = {}
    for t in entry:gmatch("<dc:title[^>]*>(.-)</dc:title>") do
        table.insert(titles, unescape(t))
    end
    metadata.title = titles[1]
    if titles[2] and titles[2] ~= "" then
        metadata.title = metadata.title .. ": " .. titles[2]
    end

    local creators = {}
    for c in entry:gmatch("<dc:creator>(.-)</dc:creator>") do
        table.insert(creators, unescape(c))
    end
    if #creators > 0 then metadata.authors = table.concat(creators, ", ") end

    metadata.description = cleanDescription(unescape(entry:match("<dc:description>(.-)</dc:description>")))
    metadata.language = normalizeLang(entry:match("<dc:language>(.-)</dc:language>"))

    local subjects = {}
    for s in entry:gmatch("<dc:subject>(.-)</dc:subject>") do
        table.insert(subjects, unescape(s))
    end
    if #subjects > 0 then metadata.keywords = table.concat(subjects, ", ") end

    -- O identificador sem prefixo "ISBN:" é o ID do volume → URLs de capa e
    -- feed do volume individual (descrição completa).
    local volume_id
    for ident in entry:gmatch("<dc:identifier>(.-)</dc:identifier>") do
        if not ident:find("^ISBN") then volume_id = ident; break end
    end
    if volume_id then
        metadata._volume_id = volume_id
        addGoogleCovers(metadata.cover_candidates, volume_id)
    end

    return (metadata.title and metadata.title ~= "") and metadata or nil
end

-- Último fallback do Google: jscmd=viewapi devolve um JSONP pequeno com o ID
-- do volume, com o qual montamos as URLs de capa (sem título/autor).
function AtualizarMetadados:searchGoogleBooksViewAPI(isbn)
    local body = httpGet("https://books.google.com/books?jscmd=viewapi&bibkeys=ISBN:"
        .. isbn .. "&callback=x")
    if not body then return nil end

    -- IDs de volume são alfanuméricos com - e _; o JSON escapa & como &,
    -- então o padrão para naturalmente no fim do ID.
    local volume_id = body:match('"info_url"%s*:%s*"[^"]-id=([%w%-_]+)')
        or body:match("id=([%w%-_]+)")
    if not volume_id then return nil end

    local metadata = { cover_candidates = {} }
    addGoogleCovers(metadata.cover_candidates, volume_id)
    return metadata
end

function AtualizarMetadados:searchOpenLibrary(isbn)
    local metadata = { cover_candidates = {} }
    local work_key

    -- (1) Edição EXATA por ISBN — fonte autoritativa do título e idioma da
    -- edição específica (não é busca fuzzy: casa o ISBN exato).
    local ebody = httpGet("https://openlibrary.org/isbn/" .. isbn .. ".json", HEADERS_BROWSER)
    if ebody then
        local eok, ed = pcall(json.decode, ebody)
        if eok and ed and ed.title then
            metadata.title = ed.title
            if ed.subtitle and ed.subtitle ~= "" then
                metadata.title = metadata.title .. ": " .. ed.subtitle
            end
            if ed.languages and ed.languages[1] and ed.languages[1].key then
                metadata.language = normalizeLang(ed.languages[1].key:match("([^/]+)$"))
            end
            if ed.covers and ed.covers[1] and ed.covers[1] > 0 then
                table.insert(metadata.cover_candidates,
                    "https://covers.openlibrary.org/b/id/" .. ed.covers[1] .. "-L.jpg")
            end
            if ed.series and ed.series[1] then metadata.series = ed.series[1] end
            if ed.works and ed.works[1] and ed.works[1].key then work_key = ed.works[1].key end
            -- Autores: a edição traz só chaves; resolve até 3 nomes.
            if ed.authors then
                local names = {}
                for i, a in ipairs(ed.authors) do
                    if i > 3 then break end
                    local akey = a.key or (a.author and a.author.key)
                    if akey then
                        local abody = httpGet("https://openlibrary.org" .. akey .. ".json", HEADERS_BROWSER)
                        if abody then
                            local aok, adata = pcall(json.decode, abody)
                            if aok and adata and adata.name then table.insert(names, adata.name) end
                        end
                    end
                end
                if #names > 0 then metadata.authors = table.concat(names, ", ") end
            end
        end
    end

    -- (2) Busca por ISBN — complementa autores/assuntos/capa e localiza a obra.
    local sbody = httpGet("https://openlibrary.org/search.json?isbn=" .. isbn
        .. "&fields=key,title,author_name,language,cover_i,subject", HEADERS_BROWSER)
    if sbody then
        local sok, sdata = pcall(json.decode, sbody)
        if sok and sdata and sdata.docs and sdata.docs[1] then
            local doc = sdata.docs[1]
            metadata.title = metadata.title or doc.title
            if not metadata.authors and doc.author_name then
                metadata.authors = table.concat(doc.author_name, ", ")
            end
            if not metadata.language and doc.language and doc.language[1] then
                metadata.language = normalizeLang(doc.language[1])
            end
            if #metadata.cover_candidates == 0 and doc.cover_i then
                table.insert(metadata.cover_candidates,
                    "https://covers.openlibrary.org/b/id/" .. doc.cover_i .. "-L.jpg")
            end
            if doc.subject and #doc.subject > 0 then
                local subjects = {}
                for i = 1, math.min(8, #doc.subject) do table.insert(subjects, doc.subject[i]) end
                metadata.keywords = table.concat(subjects, ", ")
            end
            work_key = work_key or doc.key
        end
    end

    -- (3) Descrição via página da obra.
    if work_key then
        local wbody = httpGet("https://openlibrary.org" .. work_key .. ".json", HEADERS_BROWSER)
        if wbody then
            local wok, wdata = pcall(json.decode, wbody)
            if wok and wdata and wdata.description then
                local d = wdata.description
                if type(d) == "table" then d = d.value end
                metadata.description = cleanDescription(d)
            end
        end
    end

    return (metadata.title and #metadata.title > 0) and metadata or nil
end

function AtualizarMetadados:searchInventaire(isbn, target_lang)
    -- Sem idioma detectado no ISBN, usa o idioma ativo da UI só para escolher
    -- descrições/rótulos mais prováveis; chaves nulas caem no fallback abaixo.
    target_lang = target_lang or normalizeLang(GetText.current_lang)
    local url = "https://inventaire.io/api/entities/by-uris?uris=isbn:" .. isbn
    local body = httpGet(url)
    if not body then return nil end

    local data_ok, data = pcall(json.decode, body)
    if not data_ok or not data or not data.entities then return nil end

    local edition
    for _e, entity in pairs(data.entities) do edition = entity; break end
    if not edition or not edition.claims then return nil end

    local metadata = { cover_candidates = {} }

    if edition.claims["wdt:P1476"] then
        metadata.title = edition.claims["wdt:P1476"][1]
    end
    if edition.claims["wdt:P407"] and edition.claims["wdt:P407"][1] then
        metadata.language = LANG_QIDS[edition.claims["wdt:P407"][1]]
    end
    if edition.image and edition.image.url then
        table.insert(metadata.cover_candidates, "https://inventaire.io" .. edition.image.url)
    end

    -- Obra associada → descrição e autores.
    local work_uri = edition.claims["wdt:P629"] and edition.claims["wdt:P629"][1]
    if work_uri then
        body = httpGet("https://inventaire.io/api/entities/by-uris?uris=" .. work_uri)
        if body then
            data_ok, data = pcall(json.decode, body)
            if data_ok and data and data.entities then
                local work
                for _e, entity in pairs(data.entities) do work = entity; break end
                if work then
                    if work.descriptions then
                        metadata.description = cleanDescription(
                            work.descriptions[target_lang] or work.descriptions["pt"]
                            or work.descriptions["en"])
                    end

                    -- Palavras-chave: gênero (P136) e tema principal (P921) da
                    -- obra — QIDs Wikidata resolvidos em rótulos no idioma alvo.
                    local kw_uris = {}
                    for _p, prop in ipairs({ "wdt:P136", "wdt:P921" }) do
                        if work.claims and work.claims[prop] then
                            for j, quri in ipairs(work.claims[prop]) do
                                if j > 2 then break end
                                table.insert(kw_uris, quri)
                            end
                        end
                    end
                    if #kw_uris > 0 then
                        local kb = httpGet("https://inventaire.io/api/entities/by-uris?uris="
                            .. table.concat(kw_uris, "|"))
                        if kb then
                            local kok, kdata = pcall(json.decode, kb)
                            if kok and kdata and kdata.entities then
                                local kws = {}
                                for _e, entity in pairs(kdata.entities) do
                                    if entity.labels then
                                        local n = entity.labels[target_lang]
                                            or entity.labels["pt"] or entity.labels["en"]
                                        if n then table.insert(kws, n) end
                                    end
                                end
                                if #kws > 0 then metadata.keywords = table.concat(kws, ", ") end
                            end
                        end
                    end
                    if work.claims and work.claims["wdt:P50"] then
                        local uris = {}
                        for i, author_uri in ipairs(work.claims["wdt:P50"]) do
                            if i > 3 then break end
                            table.insert(uris, author_uri)
                        end
                        if #uris > 0 then
                            body = httpGet("https://inventaire.io/api/entities/by-uris?uris=" .. table.concat(uris, "|"))
                            if body then
                                data_ok, data = pcall(json.decode, body)
                                if data_ok and data and data.entities then
                                    local names = {}
                                    for _e, entity in pairs(data.entities) do
                                        if entity.labels then
                                            local n = entity.labels[target_lang]
                                                or entity.labels["en"] or entity.labels["pt"]
                                            if n then table.insert(names, n) end
                                        end
                                    end
                                    if #names > 0 then metadata.authors = table.concat(names, ", ") end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return (metadata.title and #metadata.title > 0) and metadata or nil
end

-- Raspagem da Amazon (parametrizada por domínio). Estratégia em camadas:
--  1) acesso direto a /dp/{ISBN-10} — para livros físicos o ASIN é o próprio
--     ISBN-10, dispensando a página de busca (mais vigiada contra robôs);
--  2) fallback: busca moderna /s?k={isbn} e extração do primeiro ASIN válido.
-- Páginas de captcha/verificação são tratadas como indisponíveis (nil).
function AtualizarMetadados:searchAmazon(domain, lang, isbn, trusted_title)
    if not isbn or isbn == "" then return nil end

    -- Cache do Wayback Machine: o fallback "por cache" que restou do Calibre —
    -- as páginas de busca do Google/Bing são JS-only desde 2025 (nota no
    -- próprio search_engines.py do Calibre), então o cache confiável é este.
    local function waybackFallback(url)
        local avail = httpGet("https://archive.org/wayback/available?url="
            .. urlEncode(url:gsub("^https?://", "")))
        if not avail then return nil end
        local ok, data = pcall(json.decode, avail)
        local snap = ok and data and data.archived_snapshots
            and data.archived_snapshots.closest
        if not (snap and snap.available and snap.url) then return nil end
        -- O modificador id_ devolve o HTML original, sem o toolbar do Wayback.
        local snap_url = snap.url:gsub("^http://", "https://")
        snap_url = snap_url:gsub("(/web/%d+)/", "%1id_/")
        return httpGet(snap_url, HEADERS_BROWSER)
    end

    local function getProductPage(asin)
        local url = "https://www." .. domain .. "/dp/" .. asin
        local body, code = httpGet(url, HEADERS_BROWSER)
        if code == 404 then
            -- O domínio simplesmente não tem este ASIN: seguir adiante rápido,
            -- sem gastar requisições com o cache (essencial no modo exaustivo).
            return nil
        end
        local blocked = body and (body:find("api%-services%-support@amazon%.com", 1, false)
            or body:find('action="/errors/validateCaptcha"', 1, true))
        if not body or blocked then
            -- Bloqueio anti-robô ou falha de rede: tenta a cópia em cache.
            body = waybackFallback(url)
        end
        if body and body:find('id="productTitle"', 1, true) then
            return body
        end
        return nil -- não é página de produto (404 soft, captcha sem cache…)
    end

    local body
    local isbn10 = isbn13to10(isbn)
    if isbn10 then
        body = getProductPage(isbn10)
    end

    if not body then
        local sbody = httpGet("https://www." .. domain .. "/s?k=" .. isbn, HEADERS_BROWSER)
        if sbody then
            for cand in sbody:gmatch('data%-asin="([A-Z0-9]+)"') do
                if #cand == 10 then -- ASINs têm exatamente 10 caracteres
                    body = getProductPage(cand)
                    break
                end
            end
        end
    end

    if not body then return nil end

    local metadata = { cover_candidates = {}, language = lang }

    metadata.title = trim(body:match('<span id="productTitle"[^>]*>%s*(.-)%s*</span>') or "")
    if metadata.title == "" then metadata.title = nil end

    -- Trava anti-mismatch: a busca da Amazon por ISBN é fuzzy e às vezes casa o
    -- livro errado. Se já temos um título confiável (vindo das FONTES exatas,
    -- não do nome do arquivo) e o produto diverge demais, descarta TUDO desta
    -- fonte — inclusive a capa, que seria de outro livro.
    if trusted_title and trusted_title ~= "" and not titlesSimilar(metadata.title, trusted_title) then
        return nil
    end

    local authors = {}
    for author_name in body:gmatch('<span class="author[^"]*".-<a[^>]*>(.-)%s*</a>') do
        table.insert(authors, trim(author_name))
    end
    if #authors > 0 then metadata.authors = table.concat(authors, ", ") end

    -- A descrição vem fragmentada em vários <span> irmãos (negrito/itálico no
    -- meio do texto): capturar só o primeiro span TRUNCA a frase. Captura o
    -- bloco expansível inteiro e deixa o cleanDescription remover as tags.
    -- A busca pelo expander é restrita ao bloco da descrição (até o próximo
    -- feature_div): com ".-" solto, em páginas cuja descrição não usa expander,
    -- o match atravessaria a página e capturaria o expander das avaliações.
    local desc_start = body:find('<div id="bookDescription_feature_div"', 1, true)
    if desc_start then
        local desc_end = body:find('<div id="[%w_]-_feature_div"', desc_start + 40)
        local desc_block = body:sub(desc_start, (desc_end or desc_start + 20000) - 1)
        local raw = desc_block:match('class="a%-expander%-content[^"]*"[^>]*>(.-)</div>')
        if not raw then
            -- Sem expander, usa o bloco inteiro: o botão "Leia mais" mora num
            -- a-expander-header separado após o conteúdo — cortado antes da
            -- limpeza para não vazar como texto.
            raw = desc_block:gsub('<div class="a%-expander%-header.*$', '')
            raw = raw:gsub('<script.-</script>', ''):gsub('<style.-</style>', '')
        end
        metadata.description = cleanDescription(raw)
    end

    -- data-a-dynamic-image = JSON HTML-escapado no formato {"url":[larg,alt],…}.
    -- Decodifica as entidades, pega a URL de maior área declarada e — truque
    -- importante — a versão SEM o modificador de tamanho (._SY342_. etc.) é a
    -- imagem original em resolução máxima (ex.: 226×342 → 1690×2560).
    local cover_json = body:match("data%-a%-dynamic%-image='([^']+)'")
                    or body:match('data%-a%-dynamic%-image="([^"]+)"')
    if cover_json then
        cover_json = cover_json:gsub("&quot;", '"'):gsub("\\/", "/")
        local best_url, best_area = nil, 0
        for u, w, h in cover_json:gmatch('"(https?://[^"]+)"%s*:%s*%[%s*(%d+)%s*,%s*(%d+)') do
            local area = (tonumber(w) or 0) * (tonumber(h) or 0)
            if area > best_area then best_area, best_url = area, u end
        end
        if best_url then
            local original = best_url:gsub("%._[^/.]-_%.", ".")
            if original ~= best_url then
                table.insert(metadata.cover_candidates, original)
            end
            table.insert(metadata.cover_candidates, best_url)
        end
    end

    -- Palavras-chave: o breadcrumb de categorias da página ("Livros ›
    -- Administração › Motivacional"), já no idioma da vitrine. Os níveis
    -- genéricos da loja (raiz "Livros"/"Books"/…, seções "Kindle") não
    -- descrevem o livro e são filtrados pelo conteúdo — remover só o primeiro
    -- nível não basta: eBooks têm DOIS níveis de loja ("Loja Kindle › eBooks
    -- Kindle › …").
    local GENERIC_CRUMBS = {
        ["Livros"]=true, ["Books"]=true, ["Libros"]=true, ["Livres"]=true,
        ["Bücher"]=true, ["Libri"]=true, ["Boeken"]=true, ["Böcker"]=true,
        ["本"]=true, ["洋書"]=true, ["图书"]=true,
    }
    local bc = body:match('id="wayfinding%-breadcrumbs_feature_div"(.-)</ul>')
    if bc then
        local crumbs = {}
        for c in bc:gmatch('<a[^>]*a%-color%-tertiary[^>]*>%s*([^<]-)%s*</a>') do
            c = trim((c:gsub("%s+", " ")))
            if c ~= "" and not c:find("Kindle") and not GENERIC_CRUMBS[c] then
                table.insert(crumbs, c)
            end
        end
        if #crumbs > 0 then metadata.keywords = table.concat(crumbs, ", ") end
    end

    return metadata.title and metadata or nil
end

-- Capas por busca de imagens. O papel do plugin google_images do Calibre —
-- mas via Bing: o Google só serve a busca de imagens com JavaScript desde
-- set/2025 (nota no próprio código do Calibre), enquanto o Bing ainda embute
-- as URLs originais (murl) no HTML estático.
function AtualizarMetadados:searchBingImages(isbn, title, author)
    local q
    if title and title ~= "" then
        local first_author = (author and author:match("^([^,\n]+)")) or ""
        q = urlEncode(trim(title .. " " .. first_author))
    else
        q = urlEncode(isbn)
    end
    local body = httpGet("https://www.bing.com/images/search?q=" .. q
        .. "&qft=+filterui:imagesize-large", HEADERS_BROWSER)
    if not body then return nil end
    return self:parseBingImages(body)
end

function AtualizarMetadados:parseBingImages(body)
    body = body:gsub("&quot;", '"')
    local metadata = { cover_candidates = {} }
    for u in body:gmatch('"murl":"(https?://[^"]+)"') do
        if u:match("%.[jJ][pP][eE]?[gG]$") or u:match("%.[pP][nN][gG]$") then
            table.insert(metadata.cover_candidates, u)
            if #metadata.cover_candidates >= 3 then break end
        end
    end
    return #metadata.cover_candidates > 0 and metadata or nil
end

-- Capa direta por ISBN na Open Library (independe de busca casar). Boa rede de
-- segurança quando nenhuma outra fonte traz capa.
function AtualizarMetadados:extraCovers(isbn)
    -- default=false faz a OL responder 404 (em vez de um JPEG cinza "sem capa")
    -- quando não existe capa real — assim o download falha e a candidata é
    -- descartada na origem, antes mesmo da validação por RenderImage.
    return {
        { url = "https://covers.openlibrary.org/b/isbn/" .. isbn .. "-L.jpg?default=false",
          source = "openlibrary_isbn" },
    }
end

--==========================================================================--
-- Orquestração da busca
--==========================================================================--

-- Busca assíncrona: cada fonte roda em um tick separado do UIManager, para a
-- UI processar toques (inclusive o cancelamento) entre as requisições de rede.
-- Antes tudo rodava síncrono e uma rede ruim podia congelar a leitura por
-- minutos, sem chance de cancelar.
function AtualizarMetadados:fetchMetadata(file, isbn)
    if NetworkMgr:willRerunWhenOnline(function() self:fetchMetadata(file, isbn) end) then
        return
    end

    -- Cancela uma busca anterior ainda em andamento (evita duas janelas).
    local prev = self._fetch_state
    if prev and not prev.done then
        prev.cancelled = true
        self:_closeFetchLoading(prev)
    end

    -- Idioma esperado da edição, deduzido do próprio ISBN (offline, confiável):
    -- guia a preferência de fontes e a coerência linguística da agregação.
    local target_lang = detectLanguageFromISBN(isbn)
    local state = {
        file = file,
        isbn = isbn,
        target_lang = target_lang,
        all_results = {},
        amazon_results = {},
        -- Domínios do idioma alvo primeiro; a lista é percorrida até
        -- MAX_AMAZON_DOMAINS (ou até a própria Amazon preencher o essencial).
        amazon_domains = orderedAmazonDomains(target_lang),
        amazon_pos = 0,
        step = 1, -- 1=Google, 2=Amazon, 3=Open Library, 4=Inventaire, 5=Bing, 6=fim
        cancelled = false,
        done = false,
    }
    self._fetch_state = state

    state.loading = InfoMessage:new{
        text = _("Buscando metadados…"),
        dismissable = true, -- toque cancela entre uma fonte e a seguinte
        dismiss_callback = function() state.cancelled = true end,
    }
    UIManager:show(state.loading)
    UIManager:forceRePaint()
    UIManager:nextTick(function() self:_fetchStep(state) end)
end

function AtualizarMetadados:_closeFetchLoading(state)
    if not state.loading then return end
    -- Zera o callback para o fechamento programático não marcar como cancelado.
    state.loading.dismiss_callback = nil
    if UIManager:isWidgetShown(state.loading) then
        UIManager:close(state.loading)
    end
end

-- Título confiável (trava anti-mismatch da Amazon) e autor (consulta do Bing)
-- dentre o que já foi coletado — preferindo uma fonte no idioma alvo.
function AtualizarMetadados:_currentHints(state)
    local trusted, author
    for _i, r in ipairs(state.all_results) do
        if (not state.target_lang or r.data.language == state.target_lang) and r.data.title then
            trusted = trusted or r.data.title
            author  = author or r.data.authors
        end
    end
    for _i, r in ipairs(state.all_results) do -- fallback: qualquer fonte
        trusted = trusted or r.data.title
        author  = author or r.data.authors
    end
    return trusted, author
end

-- Executa UM passo da busca e agenda o próximo. Retorna ao loop do UIManager
-- entre passos, dando chance de a UI tratar o toque de cancelamento.
function AtualizarMetadados:_fetchStep(state)
    if state.done then return end
    if state.cancelled then
        state.done = true
        if self._fetch_state == state then self._fetch_state = nil end
        self:_closeFetchLoading(state)
        return
    end

    local function try(source_name, fn)
        local ok, m = pcall(fn)
        if ok and m then
            local entry = { data = m, source = source_name }
            table.insert(state.all_results, entry)
            return entry
        end
        if not ok then
            -- Loga sem a URL/ISBN completo (privacidade), só o suficiente
            -- para diagnosticar por que uma fonte falhou.
            logger.warn("Atualizar metadados: fonte", source_name,
                "falhou:", tostring(m))
        end
    end

    if state.step == 1 then
        -- 1. Google — cascata interna: feed GData → API v1 → viewapi.
        try("google", function() return self:searchGoogleBooks(state.isbn) end)
        state.step = 2
    elseif state.step == 2 then
        -- 2. Amazon — no máximo MAX_AMAZON_DOMAINS domínios, parando quando a
        -- própria Amazon já preencheu os campos essenciais.
        local d = state.amazon_domains[state.amazon_pos + 1]
        if d and state.amazon_pos < MAX_AMAZON_DOMAINS
                and not essentialsComplete(state.amazon_results) then
            state.amazon_pos = state.amazon_pos + 1
            local trusted_title = self:_currentHints(state)
            local entry = try(d.id, function()
                return self:searchAmazon(d.domain, d.lang, state.isbn, trusted_title)
            end)
            if entry then table.insert(state.amazon_results, entry) end
        else
            state.step = 3
        end
    elseif state.step == 3 then
        -- 3. Open Library — sempre.
        try("openlibrary", function() return self:searchOpenLibrary(state.isbn) end)
        state.step = 4
    elseif state.step == 4 then
        -- 4. Inventaire — sempre.
        try("inventaire", function() return self:searchInventaire(state.isbn, state.target_lang) end)
        state.step = 5
    elseif state.step == 5 then
        -- 5. Busca de imagens (Bing), apenas se nenhuma fonte trouxe capa
        -- (fonte só de capa, qualidade variável: é o último recurso).
        local has_cover = false
        for _i, r in ipairs(state.all_results) do
            if r.data.cover_candidates and #r.data.cover_candidates > 0 then
                has_cover = true
                break
            end
        end
        if not has_cover then
            local trusted_title, hint_author = self:_currentHints(state)
            try("bing_images", function()
                return self:searchBingImages(state.isbn, trusted_title, hint_author)
            end)
        end
        state.step = 6
    else
        state.done = true
        if self._fetch_state == state then self._fetch_state = nil end
        self:_closeFetchLoading(state)

        if #state.all_results == 0 then
            UIManager:show(InfoMessage:new{
                text = _("Nenhum livro encontrado para este ISBN.\nVerifique a conexão e tente novamente."),
                icon = "notice-info",
            })
            return
        end

        local merged = self:mergeResults(state.all_results, state.isbn, state.target_lang)
        self:showResultWindow(state.file, merged)
        return
    end

    UIManager:nextTick(function() self:_fetchStep(state) end)
end

-- Agrega os resultados com COERÊNCIA DE IDIOMA: para cada campo escolhe a fonte
-- de maior pontuação efetiva (prioridade + forte bônus se o conteúdo está no
-- idioma alvo, forte penalidade se está em outro), e reúne TODAS as capas.
function AtualizarMetadados:mergeResults(results, isbn, target_lang)
    table.sort(results, function(a, b)
        return (SOURCE_BONUS[a.source] or 0) > (SOURCE_BONUS[b.source] or 0)
    end)

    -- Idioma alvo: prefixo do ISBN (mais confiável); senão, o idioma relatado
    -- pela fonte exata de maior prioridade (ignora vitrines da Amazon).
    target_lang = target_lang or detectLanguageFromISBN(isbn)
    if not target_lang then
        for _i, r in ipairs(results) do
            if not r.source:find("^amazon_") and r.data.language then
                target_lang = r.data.language
                break
            end
        end
    end

    -- Campos cujo VALOR depende do idioma (título traduzido, sinopse, assuntos).
    -- Autores e número de série são neutros e seguem só a prioridade da fonte.
    local LANG_SENSITIVE = { title=true, series=true, keywords=true, description=true }
    local function effScore(r, field)
        local s = SOURCE_BONUS[r.source] or 0
        if target_lang and LANG_SENSITIVE[field] then
            -- Para a Amazon, r.data.language já é o idioma da vitrine do
            -- domínio (definido em searchAmazon); para as demais fontes, o
            -- relatado por elas.
            local rl = r.data.language
            if rl == target_lang then s = s + 10      -- mesmo idioma: prevalece
            elseif rl then s = s - 10 end             -- idioma diferente: evita
        end
        return s
    end

    local merged = { isbn = isbn }
    local field_options = {}

    -- Para cada campo, reúne TODAS as alternativas encontradas (deduplicadas
    -- por valor normalizado; fontes com o mesmo valor são agrupadas) e ordena
    -- por pontuação efetiva. A melhor vira o valor inicial; as demais ficam em
    -- merged._field_options para o usuário trocar na janela de resultado.
    for _i, f in ipairs(FIELDS) do
        local opts, seen = {}, {}
        for _j, r in ipairs(results) do
            local v = r.data[f.key]
            if v ~= nil and v ~= "" then
                local norm = normValue(v)
                local s = effScore(r, f.key)
                local dup = seen[norm]
                if dup then
                    table.insert(dup.sources, r.source)
                    -- Mesmo valor oferecido por outra fonte: vale o melhor escore.
                    if s > dup.score then dup.score = s end
                else
                    local opt = { value = v, sources = { r.source },
                                  score = s, idx = #opts + 1 }
                    seen[norm] = opt
                    table.insert(opts, opt)
                end
            end
        end
        table.sort(opts, function(a, b)
            if a.score ~= b.score then return a.score > b.score end
            return a.idx < b.idx -- empate: mantém a ordem de prioridade base
        end)
        if #opts > 0 then
            merged[f.key] = opts[1].value
            field_options[f.key] = opts
        end
    end
    merged._field_options = field_options

    -- O idioma detectado/alvo é mais confiável que o relatado por uma fonte só.
    if target_lang then merged.language = target_lang end

    -- Capas: uma entrada por fonte que tiver, na ordem de prioridade, mais as
    -- capas dedicadas por ISBN. pickBestCover() escolhe a de maior qualidade.
    local covers = {}
    for _j, r in ipairs(results) do
        for _k, url in ipairs(r.data.cover_candidates or {}) do
            if url and url ~= "" then
                table.insert(covers, { url = url, source = r.source })
            end
        end
    end
    for _k, c in ipairs(self:extraCovers(isbn)) do
        table.insert(covers, c)
    end
    merged.cover_candidates = covers

    return merged
end

--==========================================================================--
-- Janela de resultado (campos editáveis por toque)
--==========================================================================--

-- KeyValuePage cria a barra de título com ícones a 0,6 do tamanho e NÃO expõe
-- esse parâmetro. Para que os ícones de confirmar (check) e cancelar (close)
-- fiquem do mesmo tamanho dos do menu "Coleções" (que usa o estilo FM, com
-- ratio 1), elevamos temporariamente os defaults da classe TitleBar durante o
-- init — o init constrói um único TitleBar e "assa" o tamanho ali
-- (titlebar.lua: left_icon_size = ICON_SIZE * left_icon_size_ratio), então
-- restaurar logo após não afeta a barra já montada.
local MetadataPage = KeyValuePage:extend{}
function MetadataPage:init()
    local saved_l, saved_r = TitleBar.left_icon_size_ratio, TitleBar.right_icon_size_ratio
    TitleBar.left_icon_size_ratio = 1
    TitleBar.right_icon_size_ratio = 1
    local ok, err = pcall(KeyValuePage.init, self)
    TitleBar.left_icon_size_ratio = saved_l
    TitleBar.right_icon_size_ratio = saved_r
    if not ok then error(err) end
end

function AtualizarMetadados:showResultWindow(file, merged)
    local self_ref = self
    local kv_pairs = {}

    -- Uma linha por campo, com o número de resultados encontrados no rótulo:
    -- tocar → escolher entre as alternativas (ou editar, se houver só uma).
    for _i, f in ipairs(FIELDS) do
        local val = merged[f.key]
        local opts = merged._field_options and merged._field_options[f.key]
        local n_opts = opts and #opts or 0
        local label = f.label
        if n_opts > 0 then
            label = label .. " (" .. n_opts .. ")"
        end
        local display
        if val == nil or val == "" then
            display = _("(vazio — tocar para adicionar)")
        else
            display = tostring(val):gsub("%s+", " ")
            if #display > 140 then display = display:sub(1, 140) .. "…" end
        end
        table.insert(kv_pairs, {
            label .. ":", display,
            callback = function() self_ref:editField(file, merged, f) end,
        })
    end

    -- ISBN (referência, somente leitura).
    table.insert(kv_pairs, { _("ISBN:"), merged.isbn or _("N/D"), separator = true })

    -- Capa: tocar → seletor com todas as candidatas (ver e escolher qual usar).
    local n_covers = merged.cover_candidates and #merged.cover_candidates or 0
    local cover_label = "\u{F03E} " .. _("Capa")
    local cover_value
    if merged._covers_valid then -- já baixadas/validadas: mostra a selecionada
        local valid = merged._covers_valid
        cover_label = cover_label .. " (" .. #valid .. ")"
        if #valid > 0 then
            local c = valid[merged._cover_choice or 1] or valid[1]
            cover_value = c.w .. "\u{00D7}" .. c.h
                .. " — " .. _("tocar para ver/trocar")
        else
            cover_value = _("nenhuma válida")
        end
    elseif n_covers > 0 then
        cover_label = cover_label .. " (" .. n_covers .. ")"
        cover_value = T(_("%1 candidata(s) — tocar para ver e escolher"), n_covers)
    else
        cover_value = _("nenhuma encontrada")
    end
    table.insert(kv_pairs, {
        cover_label .. ":", cover_value,
        callback = function()
            if n_covers > 0 then self_ref:showCoverPicker(file, merged) end
        end,
        separator = true,
    })

    -- "Aplicar ao livro" vira um botão de verdade: o ícone de confirmação na
    -- barra de título (toque aplica; toque longo explica). O KeyValuePage não
    -- tem rodapé de botões, mas expõe esse ícone de ação — padrão do KOReader.
    self._result_window = MetadataPage:new{
        title = _("Metadados encontrados"),
        title_bar_align = "center",
        value_overflow_align = "right",
        kv_pairs = kv_pairs,
        close_callback = function()
            self_ref._result_window = nil
        end,
        title_bar_left_icon = "check",
        title_bar_left_icon_tap_callback = function()
            self_ref:applyMetadata(file, merged)
        end,
        title_bar_left_icon_hold_callback = function()
            UIManager:show(InfoMessage:new{
                text = _("Aplicar ao livro: grava os metadados e a capa selecionados."),
            })
        end,
    }
    UIManager:show(self._result_window)
end

-- Tocar num campo: se há várias alternativas, abre o seletor (igual à capa,
-- que lista as candidatas); se há uma só (ou nenhuma), vai direto à edição.
-- Palavras-chave SEMPRE abrem o seletor: além dos resultados das fontes, as
-- categorias predefinidas ficam disponíveis para escolha manual.
function AtualizarMetadados:editField(file, merged, field)
    local opts = merged._field_options and merged._field_options[field.key]
    if field.key == "keywords" then
        self:showFieldPicker(file, merged, field, self:buildKeywordOptions(opts))
    elseif opts and #opts > 1 then
        self:showFieldPicker(file, merged, field, opts)
    else
        self:editFieldManual(file, merged, field)
    end
end

-- Combina os resultados das fontes com as categorias predefinidas (sem
-- duplicar valores iguais); as fontes vêm primeiro, presets em seguida.
function AtualizarMetadados:buildKeywordOptions(opts)
    local combined, seen = {}, {}
    for _i, o in ipairs(opts or {}) do
        if not seen[normValue(o.value)] then
            seen[normValue(o.value)] = true
            table.insert(combined, o)
        end
    end
    for _i, preset in ipairs(KEYWORD_PRESETS) do
        if not seen[normValue(preset)] then
            seen[normValue(preset)] = true
            table.insert(combined, { value = preset, sources = { "predefinida" } })
        end
    end
    return combined
end

-- Seletor de alternativas para um campo: um botão por valor encontrado, com a
--(s) fonte(s) entre colchetes. Toque aplica; toque longo mostra o valor
-- completo (útil para descrições); o último botão permite editar manualmente.
function AtualizarMetadados:showFieldPicker(file, merged, field, opts)
    local self_ref = self
    local dialog
    local current = tostring(merged[field.key] or "")

    local function apply(opt)
        merged[field.key] = opt.value
        UIManager:close(dialog)
        if self_ref._result_window then
            UIManager:close(self_ref._result_window)
        end
        self_ref:showResultWindow(file, merged)
    end

    local buttons = {}
    for _i, opt in ipairs(opts) do
        local one_line = tostring(opt.value):gsub("%s+", " ")
        if #one_line > 60 then one_line = one_line:sub(1, 60) .. "…" end
        local mark = (tostring(opt.value) == current) and "\u{2713} " or ""
        table.insert(buttons, {{
            text = mark .. one_line,
            align = "left",
            callback = function() apply(opt) end,
            hold_callback = function()
                UIManager:show(TextViewer:new{
                    title = field.label,
                    text = tostring(opt.value),
                })
            end,
        }})
    end
    table.insert(buttons, {{
        text = "\u{270E} " .. _("Editar manualmente…"),
        callback = function()
            UIManager:close(dialog)
            self_ref:editFieldManual(file, merged, field)
        end,
    }})

    local title
    if field.key == "keywords" then
        title = field.label .. " — " .. _("escolha uma opção; toque longo mostra o texto completo")
    else
        title = field.label .. " — " .. T(_("%1 resultado(s); toque longo mostra o texto completo"), #opts)
    end

    dialog = ButtonDialog:new{
        title = title,
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function AtualizarMetadados:editFieldManual(file, merged, field)
    local self_ref = self
    local dialog
    dialog = InputDialog:new{
        title = _("Editar") .. ": " .. field.label,
        input = tostring(merged[field.key] or ""),
        input_type = field.key == "series_index" and "number" or nil,
        allow_newline = field.key == "authors" or field.key == "keywords"
                        or field.key == "description",
        buttons = {{
            { text = _("Cancelar"), id = "close",
              callback = function() UIManager:close(dialog) end },
            { text = _("Salvar"), is_enter_default = true,
              callback = function()
                  local v = trim(dialog:getInputText())
                  merged[field.key] = v ~= "" and v or nil
                  UIManager:close(dialog)
                  if self_ref._result_window then
                      UIManager:close(self_ref._result_window)
                  end
                  self_ref:showResultWindow(file, merged)
              end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--==========================================================================--
-- Capa: download, escolha da melhor e visualização segura
--==========================================================================--

-- Detecta o formato real da imagem pelos magic bytes e devolve a extensão
-- correspondente (jpg/png/gif/webp — as que têm provider no KOReader), ou nil.
local function imageExtension(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local head = f:read(12) or ""
    f:close()
    if head:sub(1, 2) == "\255\216" then return "jpg" end
    if head:sub(1, 4) == "\137PNG" then return "png" end
    if head:sub(1, 4) == "GIF8" then return "gif" end
    if head:sub(1, 4) == "RIFF" and head:sub(9, 12) == "WEBP" then return "webp" end
    return nil
end

-- Baixa todas as capas candidatas (uma única vez; memoizado em
-- merged._covers_valid), valida cada uma renderizando com RenderImage (devolve
-- nil em vez de crashar em formato inválido), descarta placeholders minúsculos
-- e devolve a lista ordenada da melhor para a pior qualidade.
-- Escore: área (w*h) como motor principal; proporção fora do retrato típico de
-- capa (w/h ~0,5–0,85) leva fator redutor; prioridade da fonte desempata.
function AtualizarMetadados:getValidCovers(merged)
    if merged._covers_valid then return merged._covers_valid end

    clearCoverCache() -- começa limpo: descarta resíduo de uma janela anterior

    local function fileSize(path)
        local f = io.open(path, "rb")
        if not f then return 0 end
        local size = f:seek("end") or 0
        f:close()
        return size
    end

    local valid, seen = {}, {}
    for i, cand in ipairs(merged.cover_candidates or {}) do
        local tmp = TMP_DIR .. "/gb_cover_" .. i
        if httpDownloadFile(cand.url, tmp) then
            -- Renderiza para validar o formato e medir as dimensões reais.
            local bb = RenderImage:renderImageFile(tmp, false)
            if bb then
                local w, h = bb:getWidth(), bb:getHeight()
                if w >= 100 and h >= 100 then
                    local priority = SOURCE_BONUS[cand.source] or 0
                    -- URLs diferentes podem resolver para a MESMA imagem (ex.:
                    -- capa da edição OL e capa por ISBN): mesmas dimensões e
                    -- mesmo tamanho de arquivo ⇒ duplicata, agrupa as fontes.
                    local key = w .. "\0" .. h .. "\0" .. fileSize(tmp)
                    local dup = seen[key]
                    if dup then
                        dup.source = dup.source .. ", " .. cand.source
                        if priority > dup.priority then
                            dup.priority = priority
                            dup.score = dup.w * dup.h * dup.ratio_factor * (1 + 0.15 * priority)
                        end
                        os.remove(tmp)
                    else
                        -- A extensão do arquivo PRECISA refletir o formato real:
                        -- flushCustomCover grava o sidecar como cover.{ext} e o
                        -- KOReader escolhe o renderizador pela extensão — uma
                        -- extensão sem provider (ex. .img) resulta em capa
                        -- "aplicada" mas nunca exibida (livro sem capa).
                        local final_path
                        local ext = imageExtension(tmp)
                        if ext then
                            final_path = tmp .. "." .. ext
                            os.remove(final_path)
                            if not os.rename(tmp, final_path) then
                                final_path = nil
                                os.remove(tmp)
                            end
                        else
                            -- Formato exótico que o RenderImage decodificou:
                            -- regrava como PNG, legível por qualquer provider.
                            final_path = tmp .. ".png"
                            if not pcall(bb.writePNG, bb, final_path) then
                                final_path = nil
                            end
                            os.remove(tmp)
                        end
                        if final_path then
                            local ratio = w / h
                            local ratio_factor = (ratio >= 0.5 and ratio <= 0.85) and 1.0 or 0.6
                            local item = {
                                path = final_path, source = cand.source, w = w, h = h,
                                priority = priority, ratio_factor = ratio_factor,
                                score = w * h * ratio_factor * (1 + 0.15 * priority),
                                idx = #valid + 1,
                            }
                            seen[key] = item
                            table.insert(valid, item)
                        end
                    end
                else
                    os.remove(tmp) -- placeholder 1×1 etc.
                end
                bb:free()
            else
                os.remove(tmp)
            end
        end
    end

    table.sort(valid, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return a.idx < b.idx -- empate: mantém a ordem de prioridade das fontes
    end)

    merged._covers_valid = valid
    return valid
end

-- Capa efetiva: a escolhida pelo usuário no seletor (merged._cover_choice),
-- ou a primeira da lista ordenada (maior qualidade).
function AtualizarMetadados:pickBestCover(merged)
    local valid = self:getValidCovers(merged)
    if #valid == 0 then return nil end
    local chosen = merged._cover_choice and valid[merged._cover_choice]
    return (chosen or valid[1]).path
end

-- Seletor de capas: lista cada capa válida com fonte e dimensões. Toque abre a
-- visualização (o seletor permanece aberto por baixo, permitindo alternar entre
-- elas); toque longo define qual capa será aplicada ao livro.
function AtualizarMetadados:showCoverPicker(file, merged)
    local first_load = merged._covers_valid == nil
    local loading = InfoMessage:new{ text = _("Baixando capas…"), dismissable = false }
    UIManager:show(loading)
    UIManager:forceRePaint()

    local valid = self:getValidCovers(merged)
    UIManager:close(loading)

    if #valid == 0 then
        UIManager:show(InfoMessage:new{ text = _("Nenhuma capa válida encontrada.") })
        return
    end

    -- No primeiro download, reabre a janela de resultado por baixo: a linha
    -- "Capa" passa a mostrar o nº de imagens únicas válidas, em vez do nº de
    -- URLs candidatas (que pode incluir duplicatas e links quebrados).
    if first_load and self._result_window then
        UIManager:close(self._result_window)
        self:showResultWindow(file, merged)
    end

    local self_ref = self
    local dialog
    local chosen = merged._cover_choice or 1

    local buttons = {}
    for i, c in ipairs(valid) do
        local mark = (i == chosen) and "\u{2713} " or ""
        table.insert(buttons, {{
            text = mark .. c.w .. "\u{00D7}" .. c.h .. " px",
            align = "left",
            callback = function()
                self_ref:viewCoverFile(c)
            end,
            hold_callback = function()
                merged._cover_choice = i
                UIManager:close(dialog)
                if self_ref._result_window then
                    UIManager:close(self_ref._result_window)
                end
                self_ref:showResultWindow(file, merged)
            end,
        }})
    end

    local n_cand = merged.cover_candidates and #merged.cover_candidates or 0
    local title
    if #valid < n_cand then
        title = T(_("%1 imagem(ns) única(s) de %2 candidata(s) — fontes com a mesma capa foram agrupadas.\nToque para visualizar; toque longo para escolher."), #valid, n_cand)
    else
        title = T(_("%1 capa(s) — toque para visualizar; toque longo para escolher"), #valid)
    end

    dialog = ButtonDialog:new{
        title = title,
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

-- Exibe UMA capa (arquivo local já baixado/validado) com renderização segura:
-- BlitBuffer pcall-safe via RenderImage e image=bb no ImageViewer — NUNCA
-- file=, que dispara error() fatal no ImageWidget em formato inválido.
function AtualizarMetadados:viewCoverFile(cover)
    local bb = RenderImage:renderImageFile(cover.path, false)
    if not bb then
        UIManager:show(InfoMessage:new{
            text = _("Não foi possível exibir a capa (formato não suportado)."),
        })
        return
    end

    UIManager:show(ImageViewer:new{
        image = bb,
        image_disposable = true,
        title_text = cover.w .. "\u{00D7}" .. cover.h .. " px",
        with_title_bar = true,
        fullscreen = true,
    })
end

--==========================================================================--
-- Gravação no livro
--==========================================================================--

function AtualizarMetadados:applyMetadata(file, merged)
    local flush_failed = false
    local ok, err = pcall(function()
        local existing = DocSettings:findCustomMetadataFile(file)
        local cds = DocSettings.openSettingsFile(existing)

        if not existing then
            local ds = DocSettings:open(file)
            cds:saveSetting("doc_props", ds:readSetting("doc_props") or {})
        end

        local props = cds:readSetting("custom_props", {})
        for _i, f in ipairs(FIELDS) do
            local v = merged[f.key]
            if v ~= nil and v ~= "" then props[f.key] = v end
        end
        cds:saveSetting("custom_props", props)
        -- flushCustomMetadata devolve true só quando conseguiu gravar o
        -- sidecar (disco cheio/somente leitura => nil): sem checar, o plugin
        -- anunciava sucesso mesmo sem ter salvo nada.
        if cds:flushCustomMetadata(file) ~= true then
            flush_failed = true
            error("flush_failed")
        end

        UIManager:broadcastEvent(Event:new("InvalidateMetadataCache", file))
        UIManager:broadcastEvent(Event:new("BookMetadataChanged"))
    end)

    if not ok then
        local text
        if flush_failed then
            logger.warn("Atualizar metadados: flushCustomMetadata falhou para", file)
            text = _("Não foi possível salvar os metadados.")
        else
            text = _("Erro ao salvar metadados: ") .. tostring(err)
        end
        UIManager:show(InfoMessage:new{
            text = text,
            icon = "notice-warning",
        })
        return -- mantém a janela aberta para o usuário tentar de novo
    end

    -- Sucesso: fecha a janela de metadados e volta à lista de livros.
    if self._result_window then
        UIManager:close(self._result_window)
        self._result_window = nil
    end

    if merged.cover_candidates and #merged.cover_candidates > 0 then
        self:applyBestCover(file, merged)
    else
        UIManager:show(InfoMessage:new{ text = _("Metadados atualizados com sucesso.") })
    end

    -- Por último, com tudo já gravado no sidecar original: renomeia o arquivo
    -- para o padrão "Autor - Título.ext" (renameFile move o sidecar junto).
    self:renameToStandard(file, merged)
end

-- Gera o nome padronizado "Autor - Título.ext" a partir dos metadados
-- aplicados (primeiro autor apenas; subtítulo após ":" vira " -"). Sanitiza
-- caracteres proibidos em FAT/exFAT/ext4 e limita o comprimento sem quebrar
-- caracteres UTF-8 acentuados no corte. Devolve nil se não houver título.
function AtualizarMetadados:buildStandardFilename(file, merged)
    local title = merged.title
    if not title or title == "" then return nil end

    local author = merged.authors
    if author and author ~= "" then
        author = trim(author:match("^([^,\n]+)") or author)
    end

    local base = (author and author ~= "") and (author .. " - " .. title) or title
    base = base:gsub("%s*:%s*", " - ")
    -- Não usar %c aqui: ele é dependente da locale e pode capturar bytes UTF-8
    -- altos. Removemos explicitamente os controles C0/DEL e os proibidos.
    base = base:gsub('[/\\%*%?"<>|]', " ")
    base = base:gsub("[%z\1-\31\127]", " ")
    base = base:gsub("%s+", " ")
    base = trim(base)
    if #base > 120 then
        -- Trunca em bytes e descarta um caractere UTF-8 possivelmente partido.
        base = base:sub(1, 120):gsub("[\128-\191]+$", ""):gsub("[\194-\244]$", "")
        base = trim(base)
    end
    -- Ponto/espaço no fim são reservados em FAT/exFAT (o Windows os remove
    -- silenciosamente): limpá-los evita nomes que "mudam" ao copiar.
    base = base:gsub("[%.%s]+$", "")
    if base == "" then return nil end

    local ext = file:match("%.(%w+)$")
    return ext and (base .. "." .. ext) or base
end

-- Renomeia via FileManager:renameFile, que move junto o sidecar .sdr
-- (progresso, anotações, capa/metadados custom), atualiza histórico de
-- leitura e coleções, trata colisão de nomes e recarrega a estante.
function AtualizarMetadados:renameToStandard(file, merged)
    local new_name = self:buildStandardFilename(file, merged)
    if not new_name then return end
    local fm = FileManager.instance
    if fm and fm.renameFile then
        pcall(fm.renameFile, fm, file, new_name, true)
    end
end

-- Aplica a capa escolhida no seletor (ou, sem escolha manual, a de maior
-- qualidade segundo o escore).
function AtualizarMetadados:applyBestCover(file, merged)
    local loading = InfoMessage:new{ text = _("Aplicando capa…"), dismissable = false }
    UIManager:show(loading)
    UIManager:forceRePaint()

    local path = self:pickBestCover(merged)
    local success = false
    if path then
        local ok, flushed = pcall(function()
            -- Remove capa custom anterior: pode ter outra extensão (ex. um
            -- cover.img de versão antiga do plugin) e o KOReader pegaria
            -- qualquer cover.* do sidecar de forma indeterminada.
            local old = DocSettings:findCustomCoverFile(file)
            if old then os.remove(old) end
            return DocSettings:flushCustomCover(file, path)
        end)
        success = ok and flushed == true -- flushCustomCover devolve true se copiou
        if success then
            UIManager:broadcastEvent(Event:new("InvalidateMetadataCache", file))
            UIManager:broadcastEvent(Event:new("BookMetadataChanged"))
        end
    end

    -- A capa escolhida já foi COPIADA para o sidecar; apaga todas as
    -- temporárias (usada e não-usadas) para não acumular no cache.
    clearCoverCache()

    UIManager:close(loading)
    UIManager:show(InfoMessage:new{
        text = success and _("Metadados e capa atualizados com sucesso.")
                        or _("Metadados salvos.\nNão foi possível aplicar a capa."),
    })
end

-- Funções puras expostas para inspeção/testes; não fazem parte da API pública.
AtualizarMetadados._detectLanguageFromISBN = function(_, isbn) return detectLanguageFromISBN(isbn) end
AtualizarMetadados._normalizeLang          = function(_, c) return normalizeLang(c) end
AtualizarMetadados._titlesSimilar          = function(_, a, b) return titlesSimilar(a, b) end
AtualizarMetadados._isbn13to10             = function(_, isbn) return isbn13to10(isbn) end
AtualizarMetadados._imageExtension         = function(_, path) return imageExtension(path) end
AtualizarMetadados._orderedAmazonDomains   = function(_, lang) return orderedAmazonDomains(lang) end
AtualizarMetadados._essentialsComplete     = function(_, results) return essentialsComplete(results) end
AtualizarMetadados._urlEncode              = function(_, s) return urlEncode(s) end

return AtualizarMetadados
