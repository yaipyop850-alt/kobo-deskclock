# 시험 도구

실기기에 올리기 전에 돌리는 시뮬레이터와 시험 장치입니다. 예시 데이터는 모두 가상입니다(학생A 등).

필요: `luajit`, `python3` + Pillow, Noto Sans CJK 글꼴(`/usr/share/fonts/opentype/noto/NotoSansCJK-*.ttc`), `node`(할 일 시험).

## 화면 시뮬레이터 (`sim/`)

`render.lua`가 실제 `dc_widget.lua`를 KOReader 위젯 흉내 위에서 실행해 그리기 명령을 내보내고,
`render.py`가 PNG로 그립니다. KOReader의 레이아웃 규칙(그룹 크기 캐시, FrameContainer 크기)을 따라 합니다.

```
cd tools/sim
luajit render.lua . <폭> <높이> <clock|calendar|month|memo|sleep|pick> <UTC epoch> out.txt
python3 render.py out.txt out.png <폭> <높이>
```

환경 변수: `MEMO_DATA=1`(메모·보낼 일정 예시), `MANY_TODO=1`(할 일 12개), `POPUP=1`(할 일 팝업, `POPUP_TICK`/`POPUP_PAGE`/`POPUP_OUT`),
`TAP_TEST=1`, `CLOCK_TAP=1`, `HOLD_TEST=1`(터치 시험), `DAYPOP=1`(전체 달력 날짜 팝업, `DAYPOP_OFFSET=n`일 뒤, `DAYPOP_TICK`), `SLEEP_POPUP=1`/`SLEEP_POPUP_RESUME=1`(팝업을 띄운 채 잠들기·깨기), `WAKE_TEST=1`(잠든 동안 자동 동기화 흐름: 예약·깨어남·재예약·배터리 하한·사용자 깨움),
`ALARM_TEST=1`(일정 미리 알림: 할 일 시각 해석, 잠든 동안 알림·동기화 깨우기 순서, 깨어 있을 때 알림, 한 번만 울림, 배터리 하한; 알림 팝업이 뜬 잠든 화면을 출력 파일로 그림 — 2026-11-04 05:00 UTC 기준),
`PLUGIN_DIR`(다른 플러그인 폴더).

회귀 시험: 날짜 여러 개 × 모든 화면 × 1080x1440/1440x1080을 그려 오류와 `overflow`(화면 밖 글자)가 없는지 봅니다.

**시뮬레이터가 못 보는 것**: 전자잉크 화면 갱신 범위, Wi-Fi·네트워크, 실제 글꼴 폭, 처리 속도. 이 부분은 실기기에서 확인합니다.

## 시험 장치 (`tests/`)

| 파일 | 내용 |
| --- | --- |
| `tasks_sync_test.lua` + `tasks_fake_appsscript.js` | 실제 `apps-script/Code.gs`를 가짜 구글 할 일 API에 붙여, 기기↔할 일 양방향 동기화(충돌 시 기기 우선) 시험 |
| `memo_send_test.lua` | 기기에서 만든 일정 보내기(302 리디렉션, 틀린 키, 재전송 중복 방지, 정리) |
| `network_test.lua` | 메뉴 동작의 Wi-Fi/인터넷 대기(연결됨, DNS 지연, Wi-Fi 켜기, 시간 초과) |

```
W=$(mktemp -d); mkdir -p $W/data
luajit tools/tests/tasks_sync_test.lua $W
luajit tools/tests/memo_send_test.lua $W
luajit tools/tests/network_test.lua
```
