--[[--
책상 시계·달력 (Desk clock & calendar) for KOReader.

@module koplugin.deskclock
--]]

local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

-- Our own modules must be required while the plugin loader has the plugin
-- folder on package.path (i.e. at load time, not lazily).
local CalStore = require("dc_store")
local ICS = require("dc_ics")
local DeskWidget = require("dc_widget")
local Update = require("dc_update")
local ConfirmBox = require("ui/widget/confirmbox")

local DeskClock = WidgetContainer:extend{
    name = "deskclock",
    is_doc_only = false,
}

local HELP = [[
■ 화면 조작
· 일정 탭: 전체 제목·시간·장소 팝업(다시 탭하거나 20초 뒤 닫힘)
· 빈 곳 탭: 시계 → 달력+목록 → 전체 달력 → 메모 순서로 전환
· 달력에서 날짜 칸 길게 누르기: 그 날짜에 일정 추가(구글 캘린더로 전송)
· 전체 달력에서 날짜 탭: 그날 일정 전체 팝업. 왼쪽 위 '2026년 11월' 글자 탭: 동기화, 제목 줄의 나머지 빈 곳 탭: 화면 전환
· 전체 달력: 오늘 칸은 굵은 테두리, 지난 날짜와 마지막 주의 다음 달 날짜는 회색. 메뉴 '전체 달력에서 숨길 단어'에 적은 단어가 제목에 들어간 일정은 전체 달력 칸에서만 빠집니다.
· 마지막 동기화가 하루를 넘기면 상태 줄에 검은 '동기화 N일 전' 표시가 나옵니다. 누르면 동기화합니다.
· 길게 누르기(날짜 칸 밖): 나가기
· 아래쪽 [동기화] 버튼 또는 아래로 쓸기: Wi-Fi 켜기 → 동기화 → Wi-Fi 끄기
· [동기화] 옆 '할 일 N' 탭: 할 일 팝업(항목을 누르면 완료·되돌리기)
· 위로 쓸기: 화면 90° 회전(가로↔세로), 다음에 열 때도 유지
· 전원 버튼: 잠들면서 달력을 화면에 남김(잠든 동안 전력 거의 0)
· 달력에서 좌/우로 쓸기: 다음/이전 달
· 달력에서 날짜 탭: 그날부터 일정 보기
· 오른쪽 위 [◀ 오늘로] 탭: 오늘로 돌아가기(5분간 손대지 않아도 자동 복귀)

■ 메모·할 일
· 왼쪽 네모 칸 탭: 완료(회색·취소선, 아래로 이동) / 다시 탭하면 되돌림
· 글 탭: 수정·삭제·일정으로 등록
· [완료 지우기]: 완료 항목을 한꺼번에 삭제
· 구글 '내 할 일'과 동기화(메뉴에서 켜고 끔): 동기화할 때마다 양쪽을 맞추며, 양쪽에서 같은 항목을 고쳤으면 기기 쪽이 남습니다.

■ 잠든 화면
· 달력 + 오늘부터의 일정 + 안 한 할 일
· 메뉴 '잠든 동안 자동 동기화'를 켜면 정해 둔 간격마다 잠시 깨어나 동기화하고 잠든 화면을 새로 그린 뒤 다시 잠듭니다.

■ 일정 미리 알림
· 메뉴 '일정 미리 알림'에서 5·10·15·30분 전을 고릅니다. 여러 개를 함께 고를 수 있습니다(예: 30분 전과 10분 전에 각각 알림). 기본은 끔.
· 시각이 있는 일정이 대상입니다. '제목이 !로 시작하는 일정만'을 고르면 '!회의'처럼 표시한 일정만 알립니다. 종일 일정은 알리지 않습니다.
· 할 일은 첫 줄에 시각을 괄호로 적으면 대상이 됩니다. 예: 밥 먹기 (15:30). 적은 뒤 처음 오는 그 시각에 한 번 알립니다(밤에 적으면 다음 날).
· 알림 시각이 되면 화면이 세 번 반전(깜빡)되고 '곧 시작합니다' 팝업이 남습니다. 소리·진동·조명은 쓰지 않습니다.
· 잠들어 있으면 잠시 깨어나 알린 뒤 팝업을 띄운 채 다시 잠듭니다(Wi-Fi는 켜지 않음). 시계·달력 화면을 띄운 채 잠들었을 때만 동작합니다.
· 휴대폰에서 새로 넣은 일정은 다음 동기화 뒤부터 알림이 잡힙니다.

■ D-day
구글 캘린더 일정 제목 앞에 [D]를 붙이면(예: [D] 2차 지필고사) 가까운 순으로 2개까지 "D-45 2차 지필고사"처럼 표시됩니다. 화면에는 [D]를 뺀 이름이 나옵니다.

■ 캘린더 주소
구글 캘린더(PC) → 설정 → 해당 캘린더 → '캘린더 통합' → 'iCal 형식의 비공개 주소'를 복사합니다.
KOReader 폴더(.adds/koreader)에 deskclock_urls.txt 파일을 만들고 한 줄에 하나씩 붙여 넣으면 됩니다. 이 파일이 있으면 메뉴에서 입력한 주소보다 우선합니다.
· #로 시작하는 줄은 무시
· 주소 앞에 !를 붙이면 공휴일 캘린더로 표시

■ 동기화
Wi-Fi가 이미 연결되어 있을 때만 자동 동기화합니다(메뉴에서 'Wi-Fi 자동 켜고 끄기'를 켜면 잠시 켭니다).
시계 화면이 떠 있는 동안에는 자동 절전이 멈추므로 충전기 연결을 권장합니다.]]

function DeskClock:onDispatcherRegisterActions()
    Dispatcher:registerAction("deskclock_clock", {
        category = "none", event = "DeskClockShowClock", title = "책상 시계 열기", general = true,
    })
    Dispatcher:registerAction("deskclock_memo", {
        category = "none", event = "DeskClockShowMemo", title = "메모 열기", general = true,
    })
    Dispatcher:registerAction("deskclock_month", {
        category = "none", event = "DeskClockShowMonth", title = "전체 달력 열기", general = true,
    })
    Dispatcher:registerAction("deskclock_calendar", {
        category = "none", event = "DeskClockShowCalendar", title = "달력 열기", general = true,
    })
end

function DeskClock:init()
    -- If KOReader quit while the clock was open, put the sleep screen settings back.
    if CalStore:getSettings().saved_ss and not DeskClock.widget_open then
        DeskWidget.restoreSleepScreen(CalStore)
    end
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function DeskClock:show(mode)
    if not CalStore.loaded then
        CalStore:load()
        CalStore.loaded = true
    end
    local widget = DeskWidget:new{
        store = CalStore,
        ui = self.ui,
        mode = mode or CalStore:getSettings().mode or "clock",
    }
    DeskClock.widget_open = true
    local orig_close = widget.onCloseWidget
    widget.onCloseWidget = function(w, ...)
        DeskClock.widget_open = false
        return orig_close(w, ...)
    end
    UIManager:show(widget)
    -- Re-open in the orientation used last time (set by swiping up).
    local rotation = CalStore:getSettings().rotation
    if rotation ~= nil then
        widget:applyRotation(rotation)
    end
end

function DeskClock:onDeskClockShowClock()
    self:show("clock")
    return true
end

function DeskClock:onDeskClockShowCalendar()
    self:show("calendar")
    return true
end

function DeskClock:onDeskClockShowMemo()
    self:show("memo")
    return true
end

--- Run `fn` once the internet is reachable, always telling the user what happens.
-- Turns Wi-Fi on if needed and off again afterwards (only if we turned it on).
-- (Replaces NetworkMgr:runWhenOnline, which silently drops the action when
-- Wi-Fi is connected but the internet check fails — common right after waking.)
function DeskClock:withOnline(label, fn, keep_wifi)
    local msg = InfoMessage:new{ text = label .. "\n인터넷 연결 확인 중…" }
    UIManager:show(msg)
    UIManager:forceRePaint()
    local turned_on = false
    local function finish(ok, err)
        UIManager:close(msg)
        if ok then
            local okc, cerr = pcall(fn)
            if not okc then
                UIManager:show(InfoMessage:new{ text = label .. " 중 오류:\n" .. tostring(cerr) })
            end
        else
            UIManager:show(InfoMessage:new{ text = label .. " 실패:\n" .. err })
        end
        if turned_on and not keep_wifi then pcall(NetworkMgr.disableWifi, NetworkMgr) end
    end
    local tries = 0
    local function poll()
        tries = tries + 1
        local connected = NetworkMgr:isConnected()
        if connected and NetworkMgr:isOnline() then
            finish(true)
        elseif tries >= 120 then -- 60 s
            finish(false, connected
                and "Wi-Fi는 연결됐지만 인터넷(DNS)에 닿지 않습니다. 공유기 연결을 확인하세요."
                or "Wi-Fi에 연결하지 못했습니다. 저장된 Wi-Fi 네트워크가 있는지 확인하세요.")
        else
            UIManager:scheduleIn(0.5, poll)
        end
    end
    if not NetworkMgr:isConnected() then
        turned_on = true
        local ok, started = pcall(NetworkMgr.enableWifi, NetworkMgr, nil, false)
        if not ok or started == false then
            return finish(false, "Wi-Fi를 켜지 못했습니다.")
        end
    end
    UIManager:scheduleIn(0.2, poll)
end

function DeskClock:testWrite()
    self:withOnline("쓰기 연결 시험", function()
        local msg = InfoMessage:new{ text = "구글 캘린더 쓰기 연결 확인 중…" }
        UIManager:show(msg)
        UIManager:forceRePaint()
        local result = require("dc_memo"):test(CalStore:getPostUrl(), CalStore:absPath(CalStore:writeFilePath()))
        UIManager:close(msg)
        UIManager:show(InfoMessage:new{ text = result })
    end)
end

function DeskClock:onDeskClockShowMonth()
    self:show("month")
    return true
end

function DeskClock:syncFromMenu()
    if #CalStore:getUrls() == 0 then
        UIManager:show(InfoMessage:new{ text = "먼저 캘린더 주소를 설정해 주세요." })
        return
    end
    self:withOnline("캘린더 동기화", function()
        local msg = InfoMessage:new{ text = "캘린더 동기화 중…" }
        UIManager:show(msg)
        UIManager:forceRePaint()
        local ok, err = CalStore:sync()
        CalStore.loaded = true
        UIManager:close(msg)
        local count = #CalStore.occurrences
        UIManager:show(InfoMessage:new{
            text = ok and (string.format("동기화 완료 (앞뒤 기간 일정 %d건)", count) .. (err and ("\n" .. err) or ""))
                or (err or "동기화 실패"),
            timeout = ok and 3 or nil,
        })
    end)
end

function DeskClock:editUrls()
    local _, source = CalStore:getUrls()
    local note = source == "file"
        and "※ deskclock_urls.txt 파일이 있어 그 내용이 우선 적용됩니다."
        or "한 줄에 주소 하나. 공휴일 캘린더는 앞에 ! 를 붙이세요."
    local dialog
    dialog = InputDialog:new{
        title = "구글 캘린더 iCal 주소",
        description = note,
        input = CalStore:getSettings().urls_text or "",
        allow_newline = true,
        fullscreen = true,
        buttons = {{
            {
                text = "취소",
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = "저장",
                is_enter_default = true,
                callback = function()
                    CalStore:set("urls_text", dialog:getInputText())
                    CalStore.urls = nil
                    UIManager:close(dialog)
                    CalStore:load()
                    CalStore.loaded = true
                    UIManager:show(InfoMessage:new{ text = "저장했습니다. '지금 동기화'를 실행해 주세요.", timeout = 3 })
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Words whose events are left out of the full-screen month (comma-separated).
function DeskClock:editHideWords()
    local dialog
    dialog = InputDialog:new{
        title = "전체 달력에서 숨길 단어",
        description = "쉼표로 구분합니다. 예: 야자감독, 아침 조회\n제목에 이 단어가 들어간 일정은 전체 달력 칸에서만 빠지고, 날짜 팝업·목록·알림에는 그대로 나옵니다. 비우면 모두 보입니다.",
        input = CalStore:getSettings().month_hide or "",
        buttons = {{
            {
                text = "취소",
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = "저장",
                is_enter_default = true,
                callback = function()
                    CalStore:set("month_hide", dialog:getInputText())
                    UIManager:close(dialog)
                    UIManager:show(InfoMessage:new{ text = "저장했습니다.", timeout = 2 })
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function DeskClock:showDiagnostics()
    local Wake = require("dc_wake")
    if not CalStore.loaded then
        CalStore:load()
        CalStore.loaded = true
    end
    local Device = require("device")
    local Screen = Device.screen
    local s = CalStore:getSettings()
    local urls, source = CalStore:getUrls()
    local off = CalStore:offset()
    local lines = {
        "플러그인 버전: " .. CalStore.VERSION,
        "KOReader: " .. tostring(require("version"):getCurrentRevision()),
        string.format("화면: %d×%d, DPI %s", Screen:getWidth(), Screen:getHeight(), tostring(Screen:getDPI())),
        "기기 시각(KST): " .. os.date("!%Y-%m-%d %H:%M:%S", os.time() + off),
        "",
        string.format("캘린더 주소: %d개 (%s)", #urls,
            source == "file" and "deskclock_urls.txt" or "메뉴 입력"),
    }
    for _, f in ipairs(CalStore.stats.files or {}) do
        local desc
        if f.error then
            desc = "읽기 오류: " .. f.error
        elseif f.size then
            desc = string.format("%.1f KB, 파일 속 일정 %d건 (표시 대상 %d건)",
                f.size / 1024, f.total or 0, f.events or 0)
            if f.calname then desc = desc .. "\n      캘린더 이름: " .. f.calname end
            if f.last_summary then
                local lm = f.last_modified or ""
                local y, mo, d, h, mi = lm:match("^(%d%d%d%d)(%d%d)(%d%d)T(%d%d)(%d%d)")
                -- LAST-MODIFIED is UTC ("...Z"): shift to local time for display.
                local when = y and os.date("!%m/%d %H:%M", ICS.timegm(tonumber(y), tonumber(mo), tonumber(d),
                    tonumber(h), tonumber(mi), 0) + CalStore:offset()) or lm
                desc = desc .. string.format("\n      가장 최근 수정: %s (%s 수정, 일정일 %s)",
                    f.last_summary, when, os.date("!%m/%d", f.last_start or 0))
            end
            if (f.total or 0) == 0 then
                desc = desc .. "\n      ⚠ 일정이 하나도 없음 — 공개 주소라면 캘린더가 공개 상태가 아니거나, 다른 캘린더의 주소일 수 있음"
            end
        else
            desc = "아직 받지 않음"
        end
        table.insert(lines, string.format("  %d번%s: %s", f.index, f.holiday and "(공휴일)" or "", desc))
    end
    table.insert(lines, string.format("표시 기간 일정: %d건", #CalStore.occurrences))
    local M = require("dc_memo")
    do
        local Alarm = require("dc_alarm")
        local leads = Alarm.leadsText(CalStore)
        local line = "일정 미리 알림: " .. (leads and (leads .. ", "
            .. (Alarm.target(CalStore) == "mark" and "!로 시작하는 일정만" or "시각 있는 일정 전체")) or "끔")
        if leads then
            local at, it = Alarm.nextAt(CalStore)
            if at then
                line = line .. string.format("\n  다음 알림: %s (%s)", os.date("!%m/%d %H:%M", at),
                    it.kind == "todo" and "할 일" or "일정")
            end
        end
        table.insert(lines, line)
    end
    do
        local wh = s.wake_hours or 0
        table.insert(lines, "잠든 동안 자동 동기화: " .. (wh > 0 and (wh .. "시간마다") or "끔")
            .. (Wake.supported() and "" or " (이 기기에서 지원 안 됨)"))
        for i, l in ipairs(s.wake_log or {}) do
            if i > 5 then break end
            table.insert(lines, "  " .. l)
        end
    end
    local pu = CalStore:getPostUrl()
    local pdesc = "없음"
    if pu then
        pdesc = (CalStore.post_source == "write" and "deskclock_write.txt" or "deskclock_urls.txt")
            .. (pu:match("[?&]key=[^&]+") and "" or " (key= 없음!)")
    end
    if CalStore.write_event_present then
        pdesc = pdesc .. "\n  ※ 구글 캘린더에 쓰기 주소 일정이 남아 있음 — 지워도 됩니다"
    end
    table.insert(lines, "쓰기 주소: " .. pdesc
        .. string.format(" · 보낼 일정 %d건 · 메모 %d개(할 일 %d)", M:pendingCount(), #M:memos(), M:openCount()))
    if CalStore.stats.parse_seconds then
        table.insert(lines, string.format("처리 시간: 해석 %.1f초, 반복 전개 %.1f초",
            CalStore.stats.parse_seconds, CalStore.stats.expand_seconds or 0))
    end
    table.insert(lines, "마지막 동기화: " .. (s.last_sync and os.date("!%m/%d %H:%M", s.last_sync + off) or "없음"))
    table.insert(lines, "마지막 오류: " .. (s.last_error or "없음"))
    table.insert(lines, "자동 동기화: " .. ((s.sync_hours or 0) > 0 and (s.sync_hours .. "시간마다") or "꺼짐"))
    local connected = NetworkMgr:isConnected()
    table.insert(lines, "Wi-Fi 연결: " .. (connected and "예" or "아니오"))
    if connected and NetworkMgr.isOnline then
        table.insert(lines, "인터넷(DNS) 확인: " .. (NetworkMgr:isOnline() and "정상" or "실패 — 공유기 인터넷 연결 확인"))
    end
    for i, item in ipairs(urls) do
        local kind = item.url:match("/private%-") and "비공개 주소"
            or (item.url:match("/public/") and "공개 주소") or "기타"
        table.insert(lines, string.format("  %d번 주소 종류: %s", i, kind))
    end
    UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
end

function DeskClock:pluginDir()
    if self.path then return self.path end
    local src = debug.getinfo(1, "S").source
    return src:match("^@(.*)/[^/]*$") or "."
end

function DeskClock:checkUpdate()
    self:withOnline("업데이트 확인", function()
        local msg = InfoMessage:new{ text = "업데이트 확인 중…" }
        UIManager:show(msg)
        UIManager:forceRePaint()
        local rel, err = Update.check()
        UIManager:close(msg)
        if not rel then
            UIManager:show(InfoMessage:new{ text = err, timeout = 5 })
            return
        end
        if not Update.isNewer(rel.version, CalStore.VERSION) then
            UIManager:show(InfoMessage:new{
                text = string.format("최신 버전입니다\n기기 v%s · 서버 v%s\n(방금 올라온 버전은 서버 반영에 최대 5분 걸릴 수 있습니다)",
                    CalStore.VERSION, tostring(rel.version)), timeout = 5 })
            return
        end
        UIManager:show(ConfirmBox:new{
            text = string.format("새 버전이 있습니다.\n\n현재 v%s → 새 버전 v%s%s\n\n업데이트할까요?",
                CalStore.VERSION, rel.version, rel.notes and ("\n\n" .. rel.notes) or ""),
            ok_text = "업데이트",
            ok_callback = function()
                local m2 = InfoMessage:new{ text = "내려받는 중…" }
                UIManager:show(m2)
                UIManager:forceRePaint()
                local ok, ierr = Update.install(rel, self:pluginDir())
                UIManager:close(m2)
                if not ok then
                    UIManager:show(InfoMessage:new{ text = "업데이트 실패: " .. tostring(ierr) })
                    return
                end
                UIManager:show(ConfirmBox:new{
                    text = "v" .. rel.version .. " 설치를 마쳤습니다.\nKOReader를 다시 시작하면 적용됩니다.",
                    ok_text = "지금 재시작",
                    cancel_text = "나중에",
                    ok_callback = function() UIManager:restartKOReader() end,
                })
            end,
        })
    end, true) -- keep Wi-Fi on: [업데이트] in the dialog downloads afterwards
end

function DeskClock:rollbackUpdate()
    if not Update.hasBackup() then
        UIManager:show(InfoMessage:new{ text = "되돌릴 이전 버전이 없습니다.", timeout = 3 })
        return
    end
    UIManager:show(ConfirmBox:new{
        text = "마지막 업데이트 전 버전으로 되돌릴까요?",
        ok_text = "되돌리기",
        ok_callback = function()
            local ok, err = Update.rollback(self:pluginDir())
            if not ok then
                UIManager:show(InfoMessage:new{ text = "실패: " .. tostring(err) })
                return
            end
            UIManager:show(ConfirmBox:new{
                text = "되돌렸습니다. KOReader를 다시 시작하면 적용됩니다.",
                ok_text = "지금 재시작", cancel_text = "나중에",
                ok_callback = function() UIManager:restartKOReader() end,
            })
        end,
    })
end

function DeskClock:addToMainMenu(menu_items)
    local function intervalItem(hours, label)
        return {
            text = label,
            radio = true,
            checked_func = function() return (CalStore:getSettings().sync_hours or 0) == hours end,
            callback = function() CalStore:set("sync_hours", hours) end,
        }
    end
    local Wake = require("dc_wake")
    local function wakeItem(hours, label)
        return {
            text = label,
            radio = true,
            enabled_func = function() return hours == 0 or Wake.supported() end,
            checked_func = function() return (CalStore:getSettings().wake_hours or 0) == hours end,
            callback = function() CalStore:set("wake_hours", hours) end,
        }
    end
    local Alarm = require("dc_alarm")
    -- several lead times can be on at once (check boxes); "끄기" clears them
    local function leadItem(min, label)
        if min == 0 then
            return {
                text = label,
                radio = true,
                keep_menu_open = true,
                checked_func = function() return Alarm.leads(CalStore) == nil end,
                callback = function() Alarm.clearLeads(CalStore) end,
            }
        end
        return {
            text = label,
            keep_menu_open = true,
            checked_func = function() return Alarm.hasLead(CalStore, min) end,
            callback = function() Alarm.toggleLead(CalStore, min) end,
        }
    end
    local function targetItem(target, label)
        return {
            text = label,
            radio = true,
            keep_menu_open = true,
            enabled_func = function() return Alarm.leads(CalStore) ~= nil end,
            checked_func = function()
                return (CalStore:getSettings().alarm_target == "mark" and "mark" or "all") == target
            end,
            callback = function() CalStore:set("alarm_target", target) end,
        }
    end
    menu_items.deskclock = {
        text = "책상 시계·달력",
        sorting_hint = "more_tools",
        sub_item_table = {
            { text = "시계 화면 열기", callback = function() self:show("clock") end },
            { text = "달력 화면 열기", callback = function() self:show("calendar") end },
            { text = "전체 달력 화면 열기", callback = function() self:show("month") end },
            { text = "메모 화면 열기", callback = function() self:show("memo") end, separator = true },
            { text = "지금 동기화", keep_menu_open = true, callback = function() self:syncFromMenu() end },
            { text = "캘린더 주소 입력", keep_menu_open = true, callback = function() self:editUrls() end },
            { text = "전체 달력에서 숨길 단어", keep_menu_open = true, callback = function() self:editHideWords() end },
            {
                text = "자동 동기화 간격",
                sub_item_table = {
                    intervalItem(0, "자동 동기화 끄기"),
                    intervalItem(1, "1시간"),
                    intervalItem(3, "3시간"),
                    intervalItem(6, "6시간"),
                    intervalItem(12, "12시간"),
                },
                separator = true,
            },
            {
                text = "자동 동기화 때 Wi-Fi 자동 켜고 끄기",
                help_text = "켜 두면 자동 동기화 시각이 되었을 때 Wi-Fi가 꺼져 있어도 잠시 켜서 동기화한 뒤 다시 끕니다. 끄면 Wi-Fi가 이미 연결된 때만 자동 동기화합니다. (동기화 버튼과 아래로 쓸기는 항상 Wi-Fi를 자동으로 켜고 끕니다.)",
                checked_func = function() return CalStore:getSettings().auto_wifi_sync == true end,
                callback = function()
                    CalStore:set("auto_wifi_sync", not CalStore:getSettings().auto_wifi_sync)
                end,
            },
            {
                text = "잠든 동안 자동 동기화",
                help_text = "잠든 기기를 정해 둔 간격마다 잠시 깨워 Wi-Fi 켜기 → 동기화 → 잠든 화면(달력·오늘 일정·할 일) 새로 그리기 → 다시 잠들기를 합니다. 한 번에 1분 안팎 깨어 있고, 최대 2분 30초가 지나면 무조건 다시 잠듭니다. 배터리가 20% 아래(충전 중 아님)면 멈춥니다. 전원 버튼으로 깨우면 예약이 취소되고, 다시 잠들 때 새로 예약됩니다. '잠들 때 달력 남기기'가 켜져 있어야 동작합니다. 기록은 진단 정보에서 볼 수 있습니다.",
                sub_item_table = {
                    wakeItem(0, "끄기"),
                    wakeItem(1, "1시간마다"),
                    wakeItem(3, "3시간마다"),
                    wakeItem(6, "6시간마다"),
                    wakeItem(8, "8시간마다"),
                    wakeItem(12, "12시간마다"),
                },
            },
            {
                text = "일정 미리 알림",
                help_text = "시각이 있는 일정과 '(15:30)'처럼 시각을 적은 할 일을 정한 시간 전에 알립니다. 시점은 여러 개를 함께 고를 수 있습니다. 화면이 세 번 반전되고 '곧 시작합니다' 팝업이 남습니다. 잠들어 있으면 잠시 깨어나(Wi-Fi 없이 30초 안팎) 알린 뒤 팝업을 띄운 채 다시 잠듭니다. 배터리 10% 아래(충전 중 아님)면 깨우지 않습니다. 잠든 동안 알림은 Kobo에서만 동작합니다.",
                sub_item_table = {
                    leadItem(0, "끄기"),
                    leadItem(5, "5분 전"),
                    leadItem(10, "10분 전"),
                    leadItem(15, "15분 전"),
                    (function() local t = leadItem(30, "30분 전"); t.separator = true; return t end)(),
                    targetItem("all", "대상: 시각 있는 일정 전체 + 시각 적은 할 일"),
                    targetItem("mark", "대상: 제목이 !로 시작하는 일정만 + 시각 적은 할 일"),
                },
            },
            {
                text = "잠들 때 달력 남기기",
                help_text = "기기가 잠들 때 KOReader 잠금 화면 대신 달력을 남겨 둡니다. 전자잉크라 잠든 동안 전원을 거의 쓰지 않습니다.",
                checked_func = function() return CalStore:getSettings().sleep_view ~= false end,
                callback = function()
                    CalStore:set("sleep_view", CalStore:getSettings().sleep_view == false)
                end,
            },
            {
                text = "달력 화면에서는 자동 절전 허용",
                help_text = "켜 두면 달력 화면에서 KOReader 자동 절전 시간이 지나면 기기가 잠들고 달력이 남습니다. 시계 화면은 항상 깨어 있습니다. 충전 중에는 잠들지 않습니다.",
                checked_func = function() return CalStore:getSettings().calendar_autosleep ~= false end,
                callback = function()
                    CalStore:set("calendar_autosleep", CalStore:getSettings().calendar_autosleep == false)
                end,
                separator = true,
            },
            {
                text = "구글 캘린더 쓰기 연결 시험",
                keep_menu_open = true,
                callback = function() self:testWrite() end,
            },
            {
                text = "메모를 구글 할 일과 동기화",
                help_text = "켜 두면 동기화할 때마다 메모 화면의 항목이 구글 '내 할 일' 목록과 양방향으로 맞춰집니다. 같은 항목을 양쪽에서 고쳤으면 기기 쪽 내용이 남습니다. Apps Script에 Tasks 서비스를 추가해야 합니다(설치·사용 가이드 3단계).",
                checked_func = function() return CalStore:getSettings().tasks_sync ~= false end,
                callback = function()
                    CalStore:set("tasks_sync", CalStore:getSettings().tasks_sync == false)
                end,
                separator = true,
            },
            {
                text = "업데이트 확인",
                keep_menu_open = true,
                callback = function() self:checkUpdate() end,
            },
            {
                text = "이전 버전으로 되돌리기",
                keep_menu_open = true,
                callback = function() self:rollbackUpdate() end,
                separator = true,
            },
            {
                text = "진단 정보",
                keep_menu_open = true,
                callback = function() self:showDiagnostics() end,
            },
            {
                text = "사용법",
                keep_menu_open = true,
                callback = function() UIManager:show(InfoMessage:new{ text = HELP }) end,
            },
        },
    }
end

return DeskClock
