-- Overlay do mosaico: pinta uma faixa central translúcida com o título sobre a
-- arte da capa e um selo de progresso/conclusão no canto superior direito.
--
-- Estratégia "camada sobre o nativo": em vez de forkar o mosaicmenu inteiro,
-- nós embrulhamos MosaicMenu._updateItemsBuildUI (a MESMA tabela de módulo que o
-- coverbrowser nativo usa via require) e, depois que ele monta a página,
-- trocamos o paintTo de cada MosaicMenuItem por um nosso. O nosso paintTo pinta
-- só a capa (InputContainer.paintTo) e desenha por cima APENAS os nossos
-- overlays — assim suprimimos os indicadores nativos (barra inferior, dogear,
-- estrela) sem ter que brigar com eles.

local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local logger = require("logger")
local Screen = require("device").screen

local Overlay = {}

-- bookinfomanager é um módulo LOCAL do plugin coverbrowser: só é resolvível em
-- tempo de execução (depois que o PluginLoader adiciona os caminhos de todos os
-- plugins ao package.path). Por isso o require é preguiçoso e cacheado.
local BookInfoManager
local function getBIM()
    if not BookInfoManager then
        BookInfoManager = require("bookinfomanager")
    end
    return BookInfoManager
end

-- Translucidez das caixas (alpha 0..255 sobre branco). Valores altos = mais
-- opaco/legível; mantemos "sutil" mas com contraste suficiente para o texto.
local BAND_ALPHA = 0xC8
local BADGE_ALPHA = 0xDC

-- Acima deste percentual o livro é tratado como concluído (mostra ✓ em vez de
-- "100%"), mesmo que o status não tenha sido marcado como "complete".
local DONE_THRESHOLD = 0.999

-- Cache do ícone de "concluído", reconstruído só quando o tamanho do selo muda.
local check_icon, check_icon_size

local function settingOn(key) -- nossas opções, default ligado
    return G_reader_settings:nilOrTrue("estantemosaico_" .. key)
end

-- Título a exibir na faixa: preferimos o título dos metadados; se ainda não
-- estiver no cache do BookInfoManager, caímos no nome do arquivo (sem extensão).
-- Só memorizamos quando o bookinfo já é conhecido, para não "congelar" o
-- fallback antes da extração em background terminar.
local function getTitle(item)
    if item._em_title then return item._em_title end
    local bookinfo = getBIM():getBookInfo(item.filepath)
    local title = bookinfo and bookinfo.title
    if not title or title == "" then
        title = (item.text or ""):gsub("%.%w+$", "")
    end
    if bookinfo then item._em_title = title end
    return title
end

-- TextBoxWidget da faixa, cacheado por (título, largura) no próprio item.
local function getBandText(item, inner_w)
    local title = getTitle(item)
    if item._em_band and item._em_band_title == title and item._em_band_w == inner_w then
        return item._em_band
    end
    if item._em_band then item._em_band:free() end
    item._em_band = TextBoxWidget:new{
        text = title,
        face = Font:getFace("cfont", 17),
        width = inner_w,
        alignment = "center",
        height = Screen:scaleBySize(42), -- no máximo ~2 linhas
        height_adjust = true,
        height_overflow_show_ellipsis = true,
    }
    item._em_band_title = title
    item._em_band_w = inner_w
    return item._em_band
end

-- TextWidget do selo de porcentagem, cacheado por valor no próprio item (evita
-- recriar/re-renderizar o texto a cada repintura).
local function getBadgeText(item, pct)
    if item._em_badge and item._em_badge_pct == pct then
        return item._em_badge
    end
    if item._em_badge then item._em_badge:free() end
    item._em_badge = TextWidget:new{
        text = pct .. "%",
        face = Font:getFace("cfont", 13),
        bold = true,
    }
    item._em_badge_pct = pct
    return item._em_badge
end

local function getCheckIcon(size)
    if check_icon and check_icon_size == size then return check_icon end
    if check_icon then check_icon:free() end
    check_icon = IconWidget:new{
        icon = "check",
        width = size,
        height = size,
        alpha = true,
    }
    check_icon_size = size
    return check_icon
end

-- Faixa branca translúcida via lightenRect: clareia em direção ao branco com
-- alpha = by. É acelerado em C (BB_blend_rect) quando o device suporta, com
-- fallback automático para o blend pixel-a-pixel — mesmo visual, mais rápido.
local function fillTranslucent(bb, x, y, w, h, alpha)
    bb:lightenRect(x, y, w, h, alpha / 0xFF)
end

-- Faixa central com o título, sobre a área "td" (dimen da capa).
local function paintBand(item, bb, td)
    local pad = Size.padding.small
    local text = getBandText(item, td.w - 2 * pad)
    local band_h = text:getSize().h + 2 * pad
    local band_y = td.y + math.floor((td.h - band_h) / 2)
    fillTranslucent(bb, td.x, band_y, td.w, band_h, BAND_ALPHA)
    -- linhas finas em cima e embaixo, para "assentar" a faixa sobre a arte
    bb:paintRect(td.x, band_y, td.w, Size.line.thin, Blitbuffer.COLOR_DARK_GRAY)
    bb:paintRect(td.x, band_y + band_h - Size.line.thin, td.w, Size.line.thin, Blitbuffer.COLOR_DARK_GRAY)
    text:paintTo(bb, td.x + pad, band_y + pad)
end

-- Selo no canto superior direito: ✓ para concluído, "NN%" para em leitura.
local function paintBadge(item, bb, td)
    local pad = Size.padding.tiny
    local margin = Size.padding.small
    local pct = item.percent_finished
    local done = item.status == "complete" or (pct and pct >= DONE_THRESHOLD)
    if done then
        local size = math.floor(td.w / 6)
        local bx = td.x + td.w - size - margin
        local by = td.y + margin
        fillTranslucent(bb, bx, by, size, size, BADGE_ALPHA)
        getCheckIcon(size):paintTo(bb, bx, by)
    elseif pct and pct > 0 then
        -- nunca exibe "0%": progresso real é mostrado como pelo menos 1%
        local n = math.max(1, math.floor(pct * 100 + 0.5))
        local txt = getBadgeText(item, n)
        local ts = txt:getSize()
        local box_w = ts.w + 2 * pad
        local box_h = ts.h + 2 * pad
        local bx = td.x + td.w - box_w - margin
        local by = td.y + margin
        fillTranslucent(bb, bx, by, box_w, box_h, BADGE_ALPHA)
        bb:paintBorder(bx, by, box_w, box_h, Size.line.thin, Blitbuffer.COLOR_DARK_GRAY)
        txt:paintTo(bb, bx + pad, by + pad)
    end
end

-- Atalho de teclado (paridade com o nativo, para dispositivos com teclas): o
-- nativo pinta o dígito de atalho no canto superior esquerdo após a capa.
local function paintShortcut(item, bb, x, y)
    local icon = item.shortcut_icon
    if not icon then return end
    local ix = 0
    if BD.mirroredUILayout() and icon.dimen then
        ix = item.dimen.w - icon.dimen.w
    end
    icon:paintTo(bb, x + ix, y)
end

-- Desenha só os NOSSOS adornos (atalho + faixa + selo). Isolado para poder ser
-- envolvido em pcall: um erro aqui degrada para "sem overlay", sem arriscar o
-- loop de pintura do navegador.
local function drawOverlays(item, bb, x, y)
    paintShortcut(item, bb, x, y)
    if item.is_directory then return end
    local target = item[1] and item[1][1] and item[1][1][1]
    if not target or not target.dimen then return end
    local td = target.dimen
    -- A faixa só faz sentido sobre arte de capa real; em capas de texto
    -- (FakeCover) o título já aparece, então não duplicamos.
    if settingOn("band") and item._has_cover_image then
        paintBand(item, bb, td)
    end
    if settingOn("badge") then
        paintBadge(item, bb, td)
    end
end

-- Novo paintTo de cada MosaicMenuItem (chamado como item:paintTo(bb,x,y)).
function Overlay.paintItem(item, bb, x, y)
    -- Só a capa (sem os overlays nativos)
    InputContainer.paintTo(item, bb, x, y)
    local ok, err = pcall(drawOverlays, item, bb, x, y)
    if not ok and not Overlay._warned then
        Overlay._warned = true -- loga uma única vez, para não inundar o log
        logger.warn("Estante mosaico: erro ao desenhar overlay:", err)
    end
end

-- Libera os widgets-satélite (faixa/selo) que guardamos no item mas que não
-- fazem parte da árvore de widgets — senão só seriam recuperados pelo GC.
-- Chamado quando o coverbrowser libera o item (troca de página / fechamento).
local function freeItem(item, orig_free, ...)
    if item._em_band then item._em_band:free(); item._em_band = nil end
    if item._em_badge then item._em_badge:free(); item._em_badge = nil end
    return orig_free(item, ...)
end

-- Embrulha MosaicMenu._updateItemsBuildUI na tabela de módulo compartilhada.
-- Idempotente. Re-aponta FileChooser para a versão embrulhada, de modo que o
-- resultado independe da ordem de carregamento dos plugins.
function Overlay.apply()
    if Overlay._applied then return true end
    local ok, MosaicMenu = pcall(require, "mosaicmenu")
    if not ok or type(MosaicMenu) ~= "table" or not MosaicMenu._updateItemsBuildUI then
        return false -- coverbrowser nativo indisponível
    end
    local orig_build = MosaicMenu._updateItemsBuildUI
    MosaicMenu._updateItemsBuildUI = function(self, ...)
        local select_number = orig_build(self, ...)
        -- self.layout é um array de linhas, cada uma um array de MosaicMenuItem
        for _, row in ipairs(self.layout) do
            for _, it in ipairs(row) do
                if type(it) == "table" and it.entry and not it._em_hooked then
                    it._em_hooked = true
                    it.paintTo = Overlay.paintItem
                    -- garante a liberação dos satélites no descarte do item
                    local orig_free = it.free
                    it.free = function(self2, ...)
                        return freeItem(self2, orig_free, ...)
                    end
                end
            end
        end
        return select_number
    end
    -- Re-aponta o FileChooser (filemanager) APENAS se ele já estiver usando o
    -- build de mosaico nativo (i.e., modo mosaico ativo). Assim não quebramos os
    -- modos lista/clássico, e cobrimos a ordem em que o coverbrowser inicia
    -- antes de nós. Se ele iniciar depois, ele mesmo aponta para o nosso wrapper
    -- (pois patcheamos a tabela de módulo). Se o usuário trocar para mosaico
    -- depois, idem.
    local FileChooser = require("ui/widget/filechooser")
    if FileChooser._updateItemsBuildUI == orig_build then
        FileChooser._updateItemsBuildUI = MosaicMenu._updateItemsBuildUI
    end
    Overlay._applied = true
    return true
end

return Overlay
