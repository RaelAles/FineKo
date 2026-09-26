--[[--
Carrega as traduções do plugin conforme o idioma escolhido no KOReader.

Os textos passados a `_(...)` foram compilados para
`<plugin>/l10n/<idioma>/fineko.mo`. O KOReader define o idioma ativo em
`gettext.current_lang` (via `changeLang`, em `reader.lua`); aqui normalizamos
esse código para um dos 21 idiomas do projeto e mesclamos o catálogo do plugin
no domínio global do gettext.

Uso, no topo de `main.lua` e `_meta.lua`:

    local dir = debug.getinfo(1, "S").source:match("@(.*/)")
    require("fineko_i18n").load(dir, "fineko")

O catálogo é o mesmo nos três plugins, então a ordem de carga não importa.
]]

local GetText = require("gettext")
local logger = require("logger")

local M = {}

local SUPPORTED = {
    af = true, ca = true, da = true, de = true, en = true, es = true,
    fil = true, fi = true, fr = true, gl = true, id = true, is = true,
    it = true, lb = true, ms = true, nl = true, no = true, pt = true,
    sq = true, sv = true, sw = true,
}

local loaded = {}

-- "pt_BR" -> "pt", "nb_NO" -> "no", "C"/"en_GB" -> "en".
local function normalize(lang)
    if type(lang) ~= "string" or lang == "" or lang == "C" then
        return "en"
    end
    lang = lang:gsub("%..*$", "") -- remove sufixo de codificação (ex.: .utf8)
    local base = lang:match("^([%a]+)")
    if not base then return "en" end
    base = base:lower()
    if base == "nb" or base == "nn" then base = "no" end
    if base == "iw" then base = "he" end
    return base
end

-- Idioma escolhido pelo usuário. A fonte primária é a configuração do
-- KOReader (`G_reader_settings`, a mesma lida por `reader.lua`), para valer
-- também em idiomas que o KOReader ainda não traduz; se ela não existir, cai
-- no idioma ativo do gettext.
local function currentLanguage()
    if rawget(_G, "G_reader_settings") then
        local ok, lang = pcall(function()
            return G_reader_settings:readSetting("language")
        end)
        if ok and type(lang) == "string" and lang ~= "" then
            return lang
        end
    end
    return GetText.current_lang
end

-- `dir` é o diretório do plugin (com barra final), `domain` é o nome do .mo.
-- Carrega o idioma escolhido e, se faltar, cai no inglês; se nem isso existir,
-- mantém o texto de origem (português).
function M.load(dir, domain)
    domain = domain or "fineko"
    if loaded[domain] or type(dir) ~= "string" then return end
    dir = dir:gsub("/+$", "")
    local lang = normalize(currentLanguage())
    if SUPPORTED[lang]
        and GetText.loadMO(dir .. "/l10n/" .. lang .. "/" .. domain .. ".mo") then
        loaded[domain] = true
        return
    end
    if lang ~= "en"
        and GetText.loadMO(dir .. "/l10n/en/" .. domain .. ".mo") then
        loaded[domain] = true
        return
    end
    -- Não marca como carregado: outro plugin pode trazer o catálogo.
    logger.dbg("FineKo: traduções ausentes em", dir .. "/l10n")
end

return M
