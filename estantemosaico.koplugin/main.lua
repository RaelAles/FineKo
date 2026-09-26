local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

local Overlay = require("em_overlay")

-- O PluginLoader carrega o módulo uma vez, mas FileManager e ReaderUI instanciam
-- a classe separadamente. Guard global para aplicar o patch só uma vez.
local patches_applied = false

local EstanteMosaico = WidgetContainer:extend{
    name = "estantemosaico",
}

function EstanteMosaico:init()
    -- Menu só na estante (FileManager), não dentro do leitor.
    if not (self.ui and self.ui.document) and self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end

    if not patches_applied then
        patches_applied = true
        -- Overlay do mosaico (faixa com o título + selo de progresso/conclusão).
        -- Depende do plugin nativo "Cover browser" em modo mosaico.
        if not Overlay.apply() then
            logger.warn("Estante mosaico: coverbrowser nativo indisponível; "
                .. "ative o plugin 'Cover browser' em modo mosaico.")
        end
    end
end

function EstanteMosaico:refresh()
    if self.ui and self.ui.file_chooser then
        self.ui.file_chooser:updateItems(1, true)
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

return EstanteMosaico
