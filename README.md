# kobo-deskclock

Desk clock & Google Calendar plugin for [KOReader](https://github.com/koreader/koreader), made for an old Kobo Aura HD.

KOReader용 책상 시계·달력 플러그인입니다.

- 시계 / 달력+일정 목록 / 전체 달력 / 메모(할 일) 네 화면 (빈 곳 탭으로 전환)
- 구글 캘린더 iCal 비공개 주소 연동(반복 일정, 공휴일, D-day `[D]`), 기기에서 만든 일정을 구글 캘린더로 전송
- 메모를 할 일로 관리, 구글 '내 할 일'과 양방향 동기화 (`apps-script/Code.gs`)
- 잠들 때 달력·오늘 일정·할 일을 화면에 남김, 잠든 동안 정해진 간격으로 깨어나 동기화
- 일정 미리 알림(화면 반전 + 팝업, 잠든 중에도), '동기화 N일 전' 경고
- 기기 메뉴에서 업데이트 확인·이전 버전으로 되돌리기

## 설치·사용

처음부터 설치하는 방법(Apps Script, PC 없이 쓰기 주소 넣기 포함)은 설치·사용 가이드에 있습니다:
https://claude.ai/artifact/CsLeEXGm5WFJZSr5xeLCbM

요약: `deskclock.koplugin` 폴더를 기기의 `.adds/koreader/plugins/`에 복사 → 캘린더 주소를
`.adds/koreader/deskclock_urls.txt`에 입력(예시: `deskclock_urls.example.txt`) → KOReader 재시작 →
메뉴 › 도구 › 더 보기 › 책상 시계·달력. **비공개 주소·Apps Script 주소·비밀값은 이 저장소에 올리지 마세요.**

## 개발

- 작업 규칙: `CLAUDE.md` · 인수인계(다시 시작할 때): `docs/HANDOFF.md` · 변경 기록 요약: `docs/CHANGELOG.md`
- 시험 도구(화면 시뮬레이터, 시험 장치): `tools/README.md`

## 업데이트 배포 방식

`release.txt`의 `version`과 `files`를 기기가 읽고, `deskclock.koplugin/` 안의 파일을 내려받아
문법 검사 후 교체합니다. 새 버전을 배포할 때는 코드와 `release.txt`를 함께 올립니다.
