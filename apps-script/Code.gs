/**
 * 책상 시계·달력(Kobo) → 구글 캘린더 일정 추가 통로
 *
 * 설치: script.google.com → 새 프로젝트 → 이 코드 전체 붙여넣기
 *   1) 아래 SECRET 값을 아무도 모를 긴 문자열로 바꾸기 (영문·숫자 20자 이상)
 *   2) 프로젝트 설정(톱니바퀴) → 시간대: (GMT+09:00) 서울
 *   3) 배포 → 새 배포 → 유형: 웹 앱
 *        다음 사용자로 실행: 나 / 액세스 권한: 모든 사용자
 *   4) 권한 승인 후 나오는 '웹 앱 URL'(…/exec) 복사
 *   5) 기기의 deskclock_urls.txt 에 한 줄 추가:
 *        >웹앱URL?key=SECRET값
 *
 * 기기는 이 주소로 일정(제목·날짜·시각)만 보냅니다. 주소와 키를 아는 사람은
 * 일정을 '추가'할 수 있으므로 공유하지 마세요. 노출되면 SECRET을 바꾸고
 * 기기 파일의 key= 값도 바꾸면 됩니다.
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

/** 연결 시험: 기기 메뉴의 [쓰기 연결 시험]이 호출 */
function doGet(e) {
  const p = (e && e.parameter) || {};
  if (p.key !== SECRET) return out_('ERR key');
  if (SECRET.indexOf('여기에') === 0) return out_('ERR secret-not-set');
  return out_('OK tz=' + Session.getScriptTimeZone() + ' cal=' + calendar_().getName());
}

/** 일정 추가: key, action=add, uid, title, date=YYYY-MM-DD, [time=HH:MM], [minutes] */
function doPost(e) {
  const p = (e && e.parameter) || {};
  if (p.key !== SECRET) return out_('ERR key');
  if (SECRET.indexOf('여기에') === 0) return out_('ERR secret-not-set');
  if (p.action !== 'add') return out_('ERR action');

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
