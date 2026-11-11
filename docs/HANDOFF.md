# 인수인계: 새 세션에서 개발을 다시 시작할 때

마지막 정리: 2026-11-11, 플러그인 v3.9.2 (실기기 Kobo Aura HD에서 사용 중, 문제 없음).

## 1. 새 대화의 첫 메시지 (그대로 붙여 넣기)

```
책상 시계·달력 KOReader 플러그인 개발을 이어서 하려고 해.
GitHub 저장소 yaipyop850-alt/kobo-deskclock 을 연결해서
CLAUDE.md 와 docs/HANDOFF.md 를 먼저 읽고 시작해 줘.
개발 일지: https://claude.ai/artifact/R9V8o7E7jDXJmogaj8sMLn
이번에 하고 싶은 것: (여기에 적기)
```

새 세션의 Claude가 할 일: 저장소 연결 → `CLAUDE.md`(작업 규칙) → 이 파일 → `tools/README.md`(시험 도구) →
개발 일지의 '보류 중인 개선 후보'. 기기에서 진단 정보 화면 사진을 받으면 현재 상태 확인이 빠르다.

## 2. 어디에 무엇이 있나

| 무엇 | 위치 | 비고 |
| --- | --- | --- |
| 플러그인 코드 | `deskclock.koplugin/` | 기기의 `.adds/koreader/plugins/`에 그대로 들어감 |
| 배포 정보 | `release.txt` | 기기 업데이트가 이 파일을 읽음 (버전·파일 목록) |
| Apps Script | `apps-script/Code.gs` | 구글 계정에 손으로 붙여 넣음. 비밀값은 자리표시자 |
| 작업 규칙 | `CLAUDE.md` | 배포 절차, KOReader 함정, 개인정보 규칙, 미주 |
| 시험 도구 | `tools/` (`README.md`) | 화면 시뮬레이터 + 시험 장치 |
| 변경 기록 요약 | `docs/CHANGELOG.md` | 개발 일지의 요약 사본 |
| 개발 일지(원본) | https://claude.ai/artifact/R9V8o7E7jDXJmogaj8sMLn | 버전별 기록·채택 안 한 안·보류 목록·배운 점 |
| 설치·사용 가이드 | https://claude.ai/artifact/CsLeEXGm5WFJZSr5xeLCbM | 처음부터 다시 설치할 때. 항상 최신판 |
| 구판 가이드 | https://claude.ai/artifact/1WnV3DUGs6DAK3dfRzAKdv | 보관만 |
| 작업 회고 | https://claude.ai/artifact/RiVBqCqCgMjSSddETxCc7R | 잘된 점·문제점·작업 방식 |
| 새 프로젝트 템플릿 | https://claude.ai/artifact/D6xsJNchjXPu8vYz1Nkytu | 다른 프로젝트 시작용 |

**저장소에 없는 것 (주인이 PC에 보관)**: `deskclock_urls.txt`(비공개 iCal 주소), `deskclock_write.txt`(Apps Script
웹 앱 주소 + key), Apps Script의 SECRET 값. 공개 저장소에는 절대 올리지 않는다(`.gitignore`로 막혀 있음).
없어지면 설치·사용 가이드 2~4단계로 다시 만든다.

## 3. 개발 환경 (2026-11-11 새로 받아 재현 확인)

- 필요: `luajit` 2.1, `python3` + Pillow, Noto Sans CJK 글꼴, `node`(할 일 시험).
  없으면: `apt-get install -y luajit fonts-noto-cjk nodejs && pip install --break-system-packages pillow`
- 확인 방법: `tools/README.md`의 회귀 시험(모든 화면 × 두 방향 × 여러 날짜)과 `tools/tests/*` 세 개.
  11/11에 깨끗한 폴더에서 저장소를 새로 받아 모두 통과함.
- 기기 쪽 의존: KOReader 내부 API(`UIManager`, `Device.wakeup_mgr`, `rescheduleSuspend`, 위젯 클래스).
  **KOReader를 크게 업데이트하면 깨질 수 있다.** 6개월 뒤 재개할 때 먼저 기기의 KOReader 버전을 확인하고,
  문제가 생기면 KOReader 버전 차이부터 의심한다.

## 4. 현재 상태와 남은 일 (11/11 점검)

**사용자 확인 대기**
- 메뉴 재구성 안(첫 화면: 전체 달력 열기·지금 동기화를 맨 위에, 설정은 하위 메뉴 6개로, 위치를 '도구' 바로 아래로).
  그림으로 보여 드렸고 결정 전. 결정되면 다음 업데이트에 반영.

**다음 업데이트 때 함께 넣을 후보 (작은 것)**
- 업데이트 후 KOReader를 재시작하지 않았으면 상태 줄에 '재시작 필요' 표시 (11/10 동기화 문제의 유력 원인).
- Wi-Fi는 연결됐는데 동기화가 연달아 실패하면 'Wi-Fi 껐다 켜기·재부팅' 안내.
- 진단 정보에 KOReader 버전 표시 (6개월 뒤 재개 대비).
- 제스처용 동작에 '지금 동기화' 추가 (지금은 화면 열기 4종만).
- `apps-script/Code.gs` 머리말 설명이 옛 방식(`>` 줄을 urls 파일에)으로 남아 있음 → 지금 방식으로 고치기.
- 세로 화면 날짜 팝업: 7자 더 넣으려면 글자를 한 단계 줄여야 함(사용자 판단 대기), 할 일·알림 팝업 폭 통일 여부.

**보류 (개발 일지 '보류 중인 개선 후보')**: 날씨·미세먼지(출처·시안까지 검토), 중복 일정 합치기, 화면 순환 선택,
Apps Script 통합 주소, 액자 플러그인, 주식 화면, 다른 기기(킨들·중고 Kobo) 적용.

## 5. 지켜 온 작업 방식 (요약 — 자세한 것은 CLAUDE.md)

- 배포 전에 시뮬레이터 그림으로 먼저 보여 주고 확인받기. 한 가지만 고치지 말고 함께 넣을 개선 점검.
- 큰 기능은 실기기에서 하루 써 본 뒤 다음 기능.
- 배포 때마다 버전·release.txt·개발 일지·가이드 갱신.
- 비밀값은 USB 파일 또는 본인만 보는 통로(캘린더 일정 제목)로만. 채팅·공개 저장소 금지.
- 답은 한국어 존댓말.
