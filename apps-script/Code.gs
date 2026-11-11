/**
 * 책상 시계·달력(Kobo) → 구글 캘린더 일정 추가 통로
 *
 * 설치: script.google.com → 새 프로젝트 → 이 코드 전체 붙여넣기
 *   1) 아래 SECRET 값을 아무도 모를 긴 문자열로 바꾸기 (영문·숫자 20자 이상)
 *   2) 프로젝트 설정(톱니바퀴) → 시간대: (GMT+09:00) 서울
 *   3) 배포 → 새 배포 → 유형: 웹 앱
 *        다음 사용자로 실행: 나 / 액세스 권한: 모든 사용자
 *   4) 권한 승인 후 나오는 '웹 앱 URL'(…/exec) 복사
 *   5) 기기에 쓰기 주소(웹앱URL?key=SECRET값) 넣기 — 둘 중 하나:
 *        · PC 없이: 구글 캘린더에 이 주소를 '제목'으로 한 일정을 만들고 기기에서 동기화
 *          (기기가 deskclock_write.txt로 저장하고 그 일정은 숨김. 저장된 뒤 일정은 지워도 됨)
 *        · PC로: 기기의 .adds/koreader/deskclock_write.txt 에 그 주소 한 줄
 *      자세한 순서: 설치·사용 가이드 3~5단계 (README의 링크)
 *
 * 구글 할 일(Tasks) 동기화 (v3.4~):
 *   a) 편집기 왼쪽 '서비스' 옆 + → 'Tasks API' 선택 → 추가 (식별자 Tasks 그대로)
 *   b) 위쪽 함수 선택에서 authorize 를 고르고 [실행] → 권한 승인
 *   c) 배포 → 배포 관리 → 연필(수정) → 버전: 새 버전 → 배포 (주소는 그대로)
 *   기기의 메모가 '내 할 일' 목록과 양방향으로 맞춰집니다. 둘 다 고쳤으면 기기 쪽이 이깁니다.
 *
 * 기기는 이 주소로 일정(제목·날짜·시각)만 보냅니다. 주소와 키를 아는 사람은
 * 일정을 '추가'할 수 있으므로 공유하지 마세요. 노출되면 SECRET을 바꾸고
 * 기기의 쓰기 주소(key= 값)도 같은 방법으로 다시 넣으면 됩니다.
 */
const SECRET = '여기에-긴-비밀-문자열을-넣으세요';
const CALENDAR_ID = 'primary';   // 기본 캘린더. 다른 캘린더면 그 캘린더 ID
const TZ = 'Asia/Seoul';

function out_(text) {
  return ContentService.createTextOutput(text).setMimeType(ContentService.MimeType.TEXT);
}

function calendar_() {
  return CALENDAR_ID === 'primary'
    ? CalendarApp.getDefaultCalendar()
    : CalendarApp.getCalendarById(CALENDAR_ID);
}

/** 편집기에서 한 번 [실행]해 캘린더·할 일 권한을 승인하는 용도 */
function authorize() {
  calendar_().getName();
  Tasks.Tasklists.list({ maxResults: 1 });
}

function tasksReady_() {
  try {
    if (typeof Tasks === 'undefined') return false;
    Tasks.Tasklists.list({ maxResults: 1 });
    return true;
  } catch (err) {
    return false;
  }
}

/** 연결 시험: 기기 메뉴의 [쓰기 연결 시험]이 호출 */
function doGet(e) {
  const p = (e && e.parameter) || {};
  if (p.key !== SECRET) return out_('ERR key');
  if (SECRET.indexOf('여기에') === 0) return out_('ERR secret-not-set');
  return out_('OK tz=' + Session.getScriptTimeZone() + ' tasks=' + (tasksReady_() ? 'ok' : 'off')
    + ' cal=' + calendar_().getName());
}

function doPost(e) {
  const p = (e && e.parameter) || {};
  if (p.key !== SECRET) return out_('ERR key');
  if (SECRET.indexOf('여기에') === 0) return out_('ERR secret-not-set');
  if (p.action === 'add') return addEvent_(p);
  if (p.action === 'tasks') return syncTasks_(p);
  return out_('ERR action');
}

/* ---------------------------------------------------------------- 구글 할 일
 * 요청 data: 줄마다  U<TAB>메모id<TAB>할일id(없으면 빈칸)<TAB>0|1<TAB>제목<TAB>메모
 *                   D<TAB>할일id
 * 응답: OK tasks / M<TAB>메모id<TAB>할일id / T<TAB>할일id<TAB>0|1<TAB>제목<TAB>메모
 * 기기 쪽 변경을 먼저 그대로 적용(기기 우선)한 뒤 전체 목록을 돌려줍니다.
 */
const TASKLIST = '@default';   // '내 할 일' 목록

function esc_(s) {
  return String(s || '').replace(/\\/g, '\\\\').replace(/\t/g, '\\t').replace(/\r/g, '').replace(/\n/g, '\\n');
}

function unesc_(s) {
  return String(s || '').replace(/\\(.)/g, function (m, c) {
    return c === 'n' ? '\n' : c === 't' ? '\t' : c;
  });
}

function syncTasks_(p) {
  if (!tasksReady_()) return out_('ERR tasks-off');
  const lock = LockService.getScriptLock();
  lock.waitLock(20000);
  try {
    const out = ['OK tasks'];
    String(p.data || '').split('\n').forEach(function (line) {
      if (!line) return;
      const f = line.split('\t').map(unesc_);
      if (f[0] === 'U') {
        const done = f[3] === '1';
        const body = { title: f[4] || '(제목 없음)', notes: f[5] || '', status: done ? 'completed' : 'needsAction' };
        if (!done) body.completed = null;
        let id = f[2] || '';
        if (id) {
          // 휴대폰에서 지운 할 일이면 새로 만든다 (기기 우선)
          let cur = null;
          try { cur = Tasks.Tasks.get(TASKLIST, id); } catch (err) { cur = null; }
          if (!cur || cur.deleted) {
            id = '';
          } else {
            Tasks.Tasks.patch(body, TASKLIST, id);
          }
        }
        if (!id) id = Tasks.Tasks.insert(body, TASKLIST).id;
        out.push(['M', esc_(f[1]), esc_(id)].join('\t'));
      } else if (f[0] === 'D' && f[1]) {
        try { Tasks.Tasks.remove(TASKLIST, f[1]); } catch (err) { /* 이미 없음 */ }
      }
    });
    let token = null;
    do {
      const opts = { showCompleted: true, showHidden: true, maxResults: 100 };
      if (token) opts.pageToken = token;
      const r = Tasks.Tasks.list(TASKLIST, opts);
      (r.items || []).forEach(function (t) {
        if (!t.title) return;
        out.push(['T', esc_(t.id), t.status === 'completed' ? '1' : '0', esc_(t.title), esc_(t.notes || '')].join('\t'));
      });
      token = r.nextPageToken;
    } while (token);
    return out_(out.join('\n'));
  } finally {
    lock.releaseLock();
  }
}

/** 일정 추가: key, action=add, uid, title, date=YYYY-MM-DD, [time=HH:MM], [minutes] */
function addEvent_(p) {

  const title = String(p.title || '').trim().slice(0, 200);
  if (!title) return out_('ERR title');
  if (!/^\d{4}-\d{2}-\d{2}$/.test(p.date || '')) return out_('ERR date');
  const timed = /^\d{2}:\d{2}$/.test(p.time || '');

  const lock = LockService.getScriptLock();
  lock.waitLock(20000);
  try {
    const cal = calendar_();
    const day = Utilities.parseDate(p.date + ' 12:00', TZ, 'yyyy-MM-dd HH:mm');

    // 같은 요청을 다시 보내도(통신 끊김 후 재전송) 한 번만 만들어지도록
    if (p.uid) {
      const same = cal.getEventsForDay(day).filter(function (ev) {
        return ev.getTag('deskclock_uid') === p.uid;
      });
      if (same.length > 0) return out_('OK dup ' + same[0].getId());
    }

    let ev;
    if (timed) {
      const start = Utilities.parseDate(p.date + ' ' + p.time, TZ, 'yyyy-MM-dd HH:mm');
      const minutes = Math.max(5, Math.min(24 * 60, Number(p.minutes) || 60));
      ev = cal.createEvent(title, start, new Date(start.getTime() + minutes * 60000));
    } else {
      // 프로젝트 시간대가 서울이어야 날짜가 밀리지 않습니다 (설치 2단계)
      ev = cal.createAllDayEvent(title, day);
    }
    if (p.uid) ev.setTag('deskclock_uid', p.uid);
    return out_('OK ' + ev.getId());
  } finally {
    lock.releaseLock();
  }
}
