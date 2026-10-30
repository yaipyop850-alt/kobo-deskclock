# kobo-deskclock

Desk clock & Google Calendar plugin for [KOReader](https://github.com/koreader/koreader), made for an old Kobo Aura HD.

KOReader용 책상 시계·달력 플러그인입니다.

- 시계 / 달력+일정 목록 / 전체 달력 세 화면 (빈 곳 탭으로 전환)
- 구글 캘린더 iCal 비공개 주소 연동, 반복 일정 처리
- D-day (일정 제목 앞에 `[D]`)
- 잠들 때 달력을 화면에 남김
- 기기 메뉴에서 업데이트 확인·이전 버전으로 되돌리기

## 설치

1. `deskclock.koplugin` 폴더를 기기의 `.adds/koreader/plugins/`에 복사
2. `deskclock_urls.example.txt`를 `.adds/koreader/deskclock_urls.txt`로 복사하고 캘린더 주소를 입력
   (**비공개 주소는 이 저장소에 올리지 마세요**)
3. KOReader 재시작 → 메뉴 › 도구 › 책상 시계·달력

## 업데이트 배포 방식

`release.txt`의 `version`과 `files`를 기기가 읽고, `deskclock.koplugin/` 안의 파일을 내려받아
문법 검사 후 교체합니다. 새 버전을 배포할 때는 코드와 `release.txt`를 함께 올립니다.
