local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
-- Traduções conforme o idioma escolhido no KOReader (ver fineko_i18n.lua).
require("fineko_i18n").load(debug.getinfo(1, "S").source:match("@(.*/)"), "fineko")

local Overlay = require("em_overlay")

-- O PluginLoader carrega o módulo uma vez, mas FileManager e ReaderUI instanciam
-- a classe separadamente. Não guardamos flag local: a idempotência fica a cargo
-- de Overlay._applied, e assim o patch é tentado de novo caso o coverbrowser
-- nativo ainda não esteja disponível no primeiro init.

local EstanteMosaico = WidgetContainer:extend{
    name = "estantemosaico",
}

function EstanteMosaico:init()
    -- Menu só na estante (FileManager), não dentro do leitor.
    if not (self.ui and self.ui.document) and self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end

    -- Overlay do mosaico (faixa com o título + selo de progresso/conclusão).
    -- Depende do plugin nativo "Cover browser" em modo mosaico. Overlay.apply()
    -- é idempotente e retorna false (permitindo nova tentativa) enquanto o
    -- coverbrowser não estiver carregado/disponível.
    if not Overlay.apply() then
        logger.warn("Estante mosaico: coverbrowser nativo indisponível; "
            .. "ative o plugin 'Cover browser' em modo mosaico.")
    end
end

function EstanteMosaico:refresh()
    -- Apenas repinta: paintItem/settingOn leem as opções no momento da pintura,
    -- então não é preciso reconstruir os itens (updateItems) para um simples
    -- liga/desliga.
    local fc = self.ui and self.ui.file_chooser
    if fc then
        UIManager:setDirty(fc, "ui")
    end
end

function EstanteMosaico:addToMainMenu(menu_items)
    menu_items.estante_mosaico = {
        text = _("Estante mosaico"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text = _("Faixa central com o título"),
                checked_func = function()
                    return G_reader_settings:nilOrTrue("estantemosaico_band")
                end,
                callback = function()
                    G_reader_settings:flipNilOrTrue("estantemosaico_band")
                    self:refresh()
                end,
            },
            {
                text = _("Selo de progresso/conclusão"),
                checked_func = function()
                    return G_reader_settings:nilOrTrue("estantemosaico_badge")
                end,
                callback = function()
                    G_reader_settings:flipNilOrTrue("estantemosaico_badge")
                    self:refresh()
                end,
            },
        },
    }
end

-- Teardown defensivo do monkeypatch. O KOReader exige reiniciar ao desativar
-- um plugin, então `Overlay.restore()` não é chamado pelo PluginLoader; aqui
-- ele é acionado quando a instância da ESTANTE é destruída. O guarda por
-- documento evita desfazer o overlay no fechamento do LEITOR (senão a estante
-- voltaria sem overlay ao sair de um livro).
function EstanteMosaico:onCloseWidget()
    if self.ui and not self.ui.document then
        Overlay.restore()
    end
end

return EstanteMosaico
