# kocw-archive-plan - 실행 가이드 & 작업 계획

> **이 문서는 두 부분으로 구성됩니다.**
> 1. **Part 1 — 실행 가이드 (Execution Guide)**: 실행자가 바로 따라 할 수 있는 실용 지침 (Quick Start, 단계별 실행, 트러블슈팅, 데이터 사전).
> 2. **Part 2 — 작업 계획 (Work Plan)**: 전체 11개 todo, 의존성, 검증 전략, 커밋 전략, 성공 기준.
>
> 처음 실행하는 사람은 **Part 1**부터, 코드 리뷰어나 PM은 **Part 2**를 보세요.

---

# Part 1 — 실행 가이드 (Execution Guide)

## 1. Quick Start (5단계 요약)

```bash
# 0. 의존성 설치 (최초 1회)
bundle install

# 1. DB 초기화 (스키마 생성 — 기존 db/kocw_archive.db 삭제 후 재생성)
ruby db/migrate.rb

# 2. 강의 목록 수집 (195개 대학 + 25개 기관, 약 17,500건)
ruby bin/fetch_courses.rb

# 3. 공지사항 + 뉴스레터 수집
ruby bin/fetch_notices.rb

# 4. 강의 상세 + 차시 + 관련 자료 수집 (강의 1건당 추가 요청)
ruby bin/fetch_course_details.rb

# 5. 썸네일/자산 URL 검증 + 통계 수집 + CSV 내보내기
ruby bin/verify_assets.rb
ruby bin/fetch_statistics.rb
ruby bin/export_csv.rb
```

전체 소요 시간: **약 4~8시간** (네트워크 상태 및 KOCW 응답 속도에 따라 변동).

## 2. Prerequisites (사전 요구사항)

| 항목 | 버전/설치 | 비고 |
| --- | --- | --- |
| **Ruby** | 3.4.9 (`.ruby-version` 고정) | rbenv / asdf / mise 어느 것이든 가능 |
| **Bundler** | 4.x (gem과 함께 설치) | `gem install bundler` |
| **SQLite3 CLI** | 3.x 이상 | DB 검증/조회용. macOS는 `brew install sqlite3`, Ubuntu는 `apt install sqlite3` |
| **Git** | 2.x 이상 | 산출물 버전 관리 |
| **네트워크** | KOCW 도메인(`www.kocw.net`, `kocwstats.netlify.app`)에 HTTPS 접근 가능 | 사내 방화벽 사용 시 화이트리스트 등록 |
| **디스크 여유 공간** | 최소 500MB | SQLite DB + CSV 산출물 + 임시 로그 포함 |

설치 확인:
```bash
ruby -v            # ruby 3.4.9 ...
bundle -v          # Bundler version 4.x ...
sqlite3 --version  # 3.x ...
```

## 3. Step-by-Step Execution (단계별 상세 실행)

각 단계는 순차 실행이 원칙이지만, 의존성만 만족하면 병렬 실행도 가능합니다. 자세한 병렬화 전략은 Part 2의 "Execution strategy" 절을 참조하세요.

### Step 1 — DB 초기화 (`ruby db/migrate.rb`)

```bash
cd /Users/dallos/prj/etc/kocw
ruby db/migrate.rb
```

- **무엇을 하나**: 기존 `db/kocw_archive.db`를 삭제하고 7개 테이블(`courses`, `episodes`, `notices`, `newsletters`, `links`, `statistics`, `assets`)을 새로 생성합니다. 인덱스도 함께 생성됩니다.
- **예상 시간**: 1초 미만
- **성공 출력 예시**:
  ```
  [OK] Migrated: /Users/dallos/prj/etc/kocw/db/kocw_archive.db
       Tables (7): assets, courses, episodes, links, newsletters, notices, statistics
  ```
- **검증**:
  ```bash
  sqlite3 db/kocw_archive.db ".schema" | head -40
  sqlite3 db/kocw_archive.db "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;"
  ```

### Step 2 — 강의 목록 수집 (`ruby bin/fetch_courses.rb`)

```bash
ruby bin/fetch_courses.rb
```

- **무엇을 하나**: KOCW JSON 엔드포인트 5종을 호출하여 강의 목록(전공/교양/평생/대학전체/기관전체)을 순회합니다. 결과는 `courses` 테이블에 저장.
- **사용 엔드포인트**: `/home/search/majorCourses/lev.do`, `/home/special/themeCourses/lev.do`, `/home/enrolment/enrolmentLev.do`, `/home/search/univCoursesAll.do`, `/home/search/orgCoursesAll.do`
- **예상 시간**: 30~60분 (페이지당 약 0.5~1초 sleep 포함)
- **예상 행 수**: **15,000~17,500행**
- **검증**:
  ```bash
  sqlite3 db/kocw_archive.db "SELECT COUNT(*) FROM courses;"
  sqlite3 db/kocw_archive.db "SELECT COUNT(DISTINCT university) FROM courses WHERE university IS NOT NULL;"
  ```

### Step 3 — 공지사항 수집 (`ruby bin/fetch_notices.rb`)

```bash
ruby bin/fetch_notices.rb
```

- **무엇을 하나**: `/home/notice/noticeList.do?nt=1`(공지)과 `?nt=2`(뉴스레터) 전체 페이지를 순회. 상세 페이지를 추가로 호출하여 본문 HTML까지 저장.
- **예상 시간**: 10~20분
- **예상 행 수**: `notices` ≥ **494행**, `newsletters` ≥ **50행**
- **검증**:
  ```bash
  sqlite3 db/kocw_archive.db "SELECT COUNT(*) FROM notices;"
  sqlite3 db/kocw_archive.db "SELECT COUNT(*) FROM newsletters;"
  ```

### Step 4 — 강의 상세 + 차시 수집 (`ruby bin/fetch_course_details.rb`)

```bash
ruby bin/fetch_course_details.rb
```

- **무엇을 하나**: `courses` 테이블의 각 강의에 대해 `/home/cview.do?cid=...`를 호출하여 강의 상세 설명, 차시 목록(AJAX로 추가 요청), 관련 자료 링크를 추출. `episodes`, `links` 테이블에 저장.
- **전제 조건**: Step 2 완료 (강의 목록이 있어야 대상이 생김)
- **예상 시간**: **가장 오래 걸림 — 2~6시간** (강의 1건당 2~3회 요청 × 17,000건)
- **예상 행 수**: `episodes` ≥ **수만 행**, `links` ≥ **수백~수천 행**
- **검증**:
  ```bash
  sqlite3 db/kocw_archive.db "SELECT COUNT(*) FROM episodes;"
  sqlite3 db/kocw_archive.db "SELECT COUNT(*) FROM links;"
  sqlite3 db/kocw_archive.db "SELECT COUNT(*) FROM courses WHERE id IN (SELECT DISTINCT course_id FROM episodes);"
  ```

### Step 5 — 자산 검증 (`ruby bin/verify_assets.rb`)

```bash
ruby bin/verify_assets.rb
```

- **무엇을 하나**: 강의/공지/뉴스레터에서 참조된 모든 썸네일·이미지 URL에 대해 HEAD 요청을 보내 HTTP 200 여부를 확인. 결과를 `assets` 테이블의 `status` 컬럼에 기록(`ok` / `failed` / `broken` / `timeout`).
- **실제 파일은 다운로드하지 않습니다** (URL 검증만). 바이너리 다운로드는 Part 2의 "Must NOT have" 정책에 따라 금지.
- **예상 시간**: 30~90분 (URL 수에 비례)
- **예상 행 수**: `assets` ≥ **수천~수만 행**
- **검증**:
  ```bash
  sqlite3 db/kocw_archive.db "SELECT status, COUNT(*) FROM assets GROUP BY status;"
  ```

### Step 6 — 통계 수집 (`ruby bin/fetch_statistics.rb`)

```bash
ruby bin/fetch_statistics.rb
```

- **무엇을 하나**:
  - (a) KOCW 메인 사이트의 `/home/kocwStatisticsExcel.do`를 호출하여 월별 Excel 통계 다운로드 → 파싱 → `statistics` 테이블 저장
  - (b) `https://kocwstats.netlify.app/`의 HTML에서 하드코딩된 JS 상수(`MONTHLY_DATA`, `ANNUAL_DATA`, `DB_MONTHLY`, `DB_ANNUAL`)를 정규식으로 추출 → DB 저장
- **예상 시간**: 5~15분
- **예상 행 수**: `statistics` ≥ **수백~수천 행**
- **검증**:
  ```bash
  sqlite3 db/kocw_archive.db "SELECT COUNT(*) FROM statistics;"
  sqlite3 db/kocw_archive.db "SELECT source, COUNT(*) FROM statistics GROUP BY source;"
  ```

### Step 7 — CSV 내보내기 (`ruby bin/export_csv.rb`)

```bash
ruby bin/export_csv.rb
```

- **무엇을 하나**: 7개 테이블을 각각 별도 CSV로 변환하여 `data/csv/` 디렉토리에 저장. 인코딩은 UTF-8, 헤더 행 포함.
- **예상 시간**: 1분 미만
- **산출 파일** (`data/csv/`):
  - `courses.csv` (~17,500행, 수 MB)
  - `episodes.csv` (수만 행)
  - `notices.csv` (~500행)
  - `newsletters.csv` (~50~200행)
  - `links.csv`
  - `statistics.csv`
  - `assets.csv`
- **검증**:
  ```bash
  ls -lh data/csv/
  head -1 data/csv/courses.csv   # 헤더 행 확인
  wc -l data/csv/*.csv
  ```

## 4. Expected Output (예상 산출물)

| 위치 | 형태 | 크기(대략) | 설명 |
| --- | --- | --- | --- |
| `db/kocw_archive.db` | SQLite | 50~150MB | 모든 아카이브 데이터 (7개 테이블) |
| `data/csv/*.csv` | CSV 7개 | 50~100MB 합계 | 외부 도구(엑셀, pandas 등)에서 바로 사용 가능 |
| `tmp/` | 로그/캐시 | 가변 | 재실행 시 삭제 가능 |
| `.omo/evidence/...` | 에이전트 검증 로그 | KB 단위 | 자동 검증 증거 (Part 2 F1~F4 참조) |

## 5. Troubleshooting (문제 해결)

### 5.1 "No courses found" / 빈 결과
- **원인 후보**: (1) 네트워크 차단, (2) KOCW 점검/장애, (3) 요청 파라미터 변경, (4) User-Agent 차단
- **해결**:
  1. 브라우저로 `https://www.kocw.net/home/search/majorCourses/lev.do` 직접 접속해 응답 확인
  2. `bin/fetch_courses.rb` 안의 User-Agent 헤더를 일반 브라우저 값으로 변경
  3. 사내 프록시 사용 시 환경변수 `HTTPS_PROXY` 설정
  4. KOCW 공지(`/home/notice/noticeList.do`)에 점검 공지가 있는지 확인

### 5.2 "DB locked" / `database is locked` 오류
- **원인**: 다른 프로세스가 DB를 점유 중 (예: `sqlite3` CLI 세션이 열려있거나 다른 스크립트 동시 실행)
- **해결**:
  1. 다른 `sqlite3` CLI 세션을 모두 종료
  2. 백그라운드 실행 중인 다른 `bin/*.rb` 프로세스 종료 (`pgrep -f 'ruby bin'`)
  3. 그래도 안 되면 `lsof db/kocw_archive.db`로 점유 프로세스 확인 후 종료
  4. 최후 수단: `rm db/kocw_archive.db && ruby db/migrate.rb` 후 재수집

### 5.3 "Permission denied" 오류
- **원인 후보**: (1) `db/` 또는 `data/` 디렉토리 쓰기 권한 없음, (2) macOS Gatekeeper 차단
- **해결**:
  ```bash
  ls -la db/ data/                    # 권한 확인
  chmod -R u+w db/ data/ tmp/         # 사용자 쓰기 권한 부여
  chmod +x bin/*.rb                   # 실행 권한 부여 (필요 시)
  ```

### 5.4 "SSL certificate verify failed" (특히 macOS)
- **해결**: Ruby의 OpenSSL 번들 인증서 업데이트
  ```bash
  brew install ca-certificates
  # 또는 Ruby 설치 도구(rbenv/asdf) 재설치 시 자동 갱신
  ```

### 5.5 매우 느린 진행 / 멈춤
- KOCW가 일시적으로 503/429를 반환하는 경우 → 스크립트가 자동 재시도 중일 수 있음. 30분 이상 변화 없으면 중단 후 재실행.
- 네트워크 대역폭 폭주 → `bin/*.rb` 안의 sleep 간격을 1.0~1.5초로 늘려보기.

### 5.6 한글이 깨진 CSV (엑셀에서)
- **해결**: UTF-8 BOM을 추가하거나, 엑셀에서 "데이터 → 텍스트에서 가져오기" 시 인코딩을 UTF-8로 지정.

## 6. Data Dictionary (테이블/컬럼 사전)

| 테이블 | 핵심 컬럼 | 설명 |
| --- | --- | --- |
| **`courses`** | `id`, `kem_id`, `cid`, `title`, `professor`, `university`, `organization`, `department`, `term`, `year`, `description`, `summary`, `content_type`, `ccl_license`, `language`, `ai_subtitle_flag`, `sign_language_flag`, `thumbnail_url`, `view_count` | 강의 1건당 1행. `kem_id`는 숫자 ID, `cid`는 암호화된 문자열 ID(둘 다 KOCW 내부 식별자). `content_type`은 1=video, 2=audio, 3=doc/pdf, 4=other, 6=flash, 7=authoring. `ai_subtitle_flag`/`sign_language_flag`는 0/1. |
| **`episodes`** | `id`, `course_id`, `episode_number`, `title`, `description`, `duration`, `content_type`, `lecture_id` | 강의의 차시(에피소드). `course_id` → `courses.id` 참조 (FK 미선언). `duration`은 "45:30" 같은 문자열. `lecture_id`는 KOCW AJAX 플레이어에서 사용하는 ID. |
| **`notices`** | `id`, `notice_id`, `notice_type`(=1), `title`, `author`, `view_count`, `published_at`, `content_html` | KOCW 공지사항. `notice_type=1`. 본문은 HTML 그대로 저장. |
| **`newsletters`** | `id`, `notice_id`, `title`, `author`, `view_count`, `published_at`, `content_html` | KOCW 뉴스레터. `notices`와 동일 스키마이지만 별도 테이블로 분리(소스별 쿼리 편의). |
| **`links`** | `id`, `course_id`, `url`, `link_type`, `description` | 강의 관련 외부 링크. `link_type`은 `'riss'` / `'external'` / `'download'` / `'related_lecture'` 등. `(course_id, url)` 유니크. |
| **`statistics`** | `id`, `source`, `metric_name`, `category`, `year`, `month`, `value`, `unit` | 시계열 통계. `source`는 `'main_site'` / `'stats_site'`. `category`는 `'web_access'` / `'mobile'` / `'search'` / `'certificate'` / `'api'` / `'lecture_db'`. `month`는 NULL이면 연간 합계. |
| **`assets`** | `id`, `course_id`(nullable), `url`, `asset_type`, `status`, `content_type`, `content_length`, `checked_at` | 썸네일·이미지 자산. `asset_type`은 `'thumbnail'` / `'notice_image'` 등. `status`는 `'ok'` / `'failed'` / `'broken'` / `'timeout'`. |

## 7. Rate Limiting (요청 제한 정책)

| 정책 | 값 | 이유 |
| --- | --- | --- |
| **기본 요청 간격** | **1.0초 / 요청** | KOCW 서버 보호 + IP 차단 회피. 스크립트 안에 `sleep 1.0`이 명시되어 있음. |
| **동시 연결 수** | **1** | 멀티 스레드/프로세스 금지. 동시에 두 스크립트 실행도 금지(같은 IP에서 부하 가중). |
| **User-Agent** | 일반 브라우저 값(예: `Mozilla/5.0 ...`) | 봇 차단 회피 |
| **재시도 정책** | HTTP 429/503 수신 시 **최대 3회**, 지수 백오프(2초 → 4초 → 8초) | 일시적 장애 흡수 |
| **총 실행 시간 상한** | 단계당 최대 8시간 | 무한 루프 방지 — 초과 시 중단 후 재개 |

**왜 중요한가**: KOCW는 학계/연구에서 사용되는 공공 서비스이며, 과도한 요청은 운영 기관(한국교육과정평가원)과의 관계를 손상시키고 향후 API 차단 위험을 만듭니다. 또한 1회 아카이브 정책이므로 더 빠르게 끝낼 필요 없이 **안정성을 우선**합니다.

## 8. Service Deadline (서비스 종료 일정)

| 이벤트 | 날짜 | 의미 | 실행자 액션 |
| --- | --- | --- | --- |
| **신규 강의 등록 종료** | **2026-09-30** | 신규/업데이트 강의 등록 불가. 그 시점까지의 강의만 신규 수집 가능. | Step 2(`fetch_courses.rb`)는 **9월 30일 이전에 1회 실행**하여 등록 가능한 모든 강의를 잡아야 함. |
| **서비스 종료** | **2026-12-30** | `www.kocw.net` 전면 종료. 이후 어떤 단계도 외부 사이트에 의존하는 작업은 불가능. | **모든 수집 단계를 12월 29일까지 완료**해야 함. 12월 30일 이후엔 Step 6/7(외부 통계 사이트)도 종료될 수 있음. |
| **아카이브 공개** | 2027년 1월 이후 | GitHub 공개 및 후속 활용 | `docs/` 문서 + LICENSE 정리 후 GitHub 릴리즈 |

**권장 타임라인**:
- **2026-09-30 이전**: 1차 수집 (모든 신규 강의 등록 종료 전에)
- **2026-10~11월**: 추가 수집 (메인 사이트에 변경분 생길 수 있음 — 1~2회 재실행)
- **2026-12-15**: 최종 수집 + 검증
- **2026-12-29**: 모든 작업 종료
- **2026-12-30**: KOCW 종료 → 즉시 외부 사이트 접근 불가 확인
- **2027-01**: GitHub 공개

---


# Part 2 — 작업 계획 (Work Plan)

> 아래는 기계 친화적인 작업 계획(원본 `.omo/plans/kocw-archive-plan.md`을 토대로 편집)입니다. 11개의 todo, 의존성 매트릭스, 검증 전략, 커밋 전략, 성공 기준을 포함합니다.

## TL;DR (For humans)

**Who this is for and what changes for them:**
KOCW(한국OpenCourseWare) 이용자 및 연구자에게 서비스 종료(2026.12.30) 이후에도 강의 메타데이터와 관련 자료를 검색·활용할 수 있는 아카이브 DB를 제공합니다.

**What you'll get:**
Ruby 기반 수집 도구로 KOCW의 강의 목록, 차시 정보, 공지사항, 뉴스레터, 통계 데이터를 SQLite DB와 CSV로 정리한 아카이브 프로젝트. 추가로 수집 가능한 정보(댓글, 수강확인증 등)에 대한 조사 보고서도 포함됩니다.

**Why this approach:**
Ruby는 사용자의 선호 언어이며, 정부/교육 포털 스크래핑에 적합한 Net::HTTP과 Nokogiri 생태계를 보유하고 있습니다. SQLite + CSV 조합은 설치 없이 바로 실행 가능하고 GitHub 공유에 최적입니다.

**What it will NOT do:**
- 영상/오디오 파일을 다운로드하지 않습니다.
- 로그인이 필요한 댓글, 수강확인증, 개인 수강 이력은 수집하지 않습니다.
- 실시간 동기화나 증분 업데이트를 지원하지 않습니다(1회 아카이브).
- 별도의 웹 UI는 제공하지 않습니다.

**Effort:** Large
**Risk:** Medium - KOCW 서비스 종료 전(2026.12.30)에 수집을 완료해야 하며, 사이트 구조 변경 가능성이 있습니다.
**Decisions to sanity-check:**
1. Ruby + SQLite/CSV 스택 선정
2. 썸네일은 URL만 기록하고 파일 존재 여부만 검증(다운로드는 미래 검토)
3. kocwstats.netlify.app 하드코딩 데이터도 파싱하여 포함

Your next move: `$ulw-execute` to run this plan. Full execution detail follows below.

---

> TL;DR (machine): Large effort, Medium risk, Ruby-based KOCW archive tool with SQLite/CSV output, GitHub-ready project structure.

## Scope
### Affected user and ideal state

**Affected users:**
1. **사용자 (아카이버)** - KOCW 서비스 종료 전에 강의 메타데이터와 관련 자료를 체계적으로 추출·보존하여 DB화하려는 운영자
2. **미래 연구자/학생** - KOCW 종료 이후에도 아카이브 DB를 검색하여 강의 정보, 교수, 대학, 관련 자료를 발견하려는 이용자
3. **GitHub 커뮤니티** - 오픈소스로 공개된 도구를 참고하거나 개선하려는 개발자

| Row | Statement | Reason |
| --- | --- | --- |
| IS-1 | 모든 공개 강의 메타데이터(강의명, 교수, 대학/기관, 학기, 설명, 요약, 콘텐츠 유형, CCL 라이선스, 언어, AI자막/수어 여부, 썸네일 URL)이 정규화된 검색 가능한 DB에 저장된다. | 아카이브의 핵심 목표; 미래 발견을 가능하게 함 |
| IS-2 | 모든 공지사항과 뉴스레터가 전문, 날짜, 조회수와 함께 보존한다. | 기관의 기록과 커뮤니케이션 역사 보존 |
| IS-3 | 강의별 관련 자료 링크(RISS, 외부 자원, 다운로드 링크)가 수집된다. | 포털보다 오래 생존할 수 있는 맥락 자원 |
| IS-4 | 추가 수집 가능한 정보(댓글, 통계, 수강확인증 등)의 목록과 수집 가능성, 접근 조건이 문서화된다. | 사용자가 명시적으로 요구한 조사 항목 |
| IS-5 | `docs/` 폴터에 실행자가 추가 질문 없이 따라할 수 있는 상세 작업 계획 문서가 존재한다. | 사용자가 명시적으로 요구한 산출물 |
| IS-6 | 프로젝트가 GitHub에 공개될 수 있는 구조(README, LICENSE, .gitignore)를 갖춘다. | 사용자가 명시한 공개 계획 |
| IS-7 | kocwstats.netlify.app의 하드코딩된 통계 데이터도 파싱하여 DB에 포함한다. | 메인 사이트에서 제공하지 않는 유니크한 시계열 데이터 |

| Row | Statement | Reason |
| --- | --- | --- |
| GAP-1 | DB 스키마가 존재하지 않는다. | Todo 1-2에서 해결 |
| GAP-2 | 수집 도구가 존재하지 않는다. | Todo 3-7에서 해결 |
| GAP-3 | 수집 가능/불가능 콘텐츠의 인벤토리가 없다. | Todo 8에서 해결 |
| GAP-4 | `docs/` 폴터나 계획 문서가 없다. | Todo 10에서 해결 |
| GAP-5 | GitHub 공개를 위한 프로젝트 구조가 없다. | Todo 1, 11에서 해결 |
| GAP-6 | kocwstats.netlify.app 데이터 수집 계획이 없다. | Todo 7에서 해결 |

### Must have
- Ruby 기반 스크래핑 도구
- SQLite DB + CSV 납품물
- 강의 메타데이터, 차시 목록, 관련 자료 링크
- 공지사항, 뉴스레터
- KOCW 메인 사이트 통계 Excel 데이터
- kocwstats.netlify.app 하드코딩 통계 데이터 파싱
- 썸네일/자산 URL 기록 및 존재 검증
- 추가 수집 정보 조사 보고서
- `docs/` 폴터의 작업 계획 문서
- GitHub 공개 준비 (README, LICENSE, .gitignore)

### Must NOT have (guardrails, anti-slop, scope boundaries)
- 영상 파일(MP4, FLV 등) 다운로드
- 오디오 파일 다운로드
- 문서 파일(PDF, PPT 등) 바이너리 다운로드 (URL은 수집)
- 로그인 필요한 사용자 생성 콘텐츠(댓글, 리뷰, 클립, 수강확인증)
- 수강/이수증 데이터 (로그인 + 수강 완료 필요)
- 실시간 동기화 또는 증분 업데이트 (서비스 종료 전 1회 아카이브)
- 아카이브 DB를 위한 웹 UI 개발
- 썸네일/이미지의 로컬 다운로드 (URL 기록 + 존재 검증만, 다운로드는 Phase 2로 연기)

## Verification strategy
> Zero human intervention - all verification is agent-executed.
- Test decision: tests-after (MiniTest or RSpec) + 수동 DB 쿼리 검증
- Evidence: `.omo/evidence/ulw/kocw-archive-plan/a<attempt>/task-<N>-kocw-archive-plan.<ext>`

## Execution strategy
### Parallel execution waves
> Target 5-8 todos per wave. Fewer than 3 (except the final) means you under-split.

**Wave 1: 프로젝트 기반 구조 및 DB 설계**
- Todo 1: Ruby 프로젝트 구조 및 의존성 설정
- Todo 2: SQLite DB 스키마 설계 및 마이그레이션

**Wave 2: 핵심 수집기 개발 (병렬 가능)**
- Todo 3: KOCW 강의 목록 수집기 (JSON 엔드포인트)
- Todo 4: KOCW 강의 상세 및 차시 정보 수집기
- Todo 5: 공지사항 및 뉴스레터 수집기

**Wave 3: 추가 데이터 및 보고서**
- Todo 6: 관련 자료 링크 및 썸네일 URL 검증
- Todo 7: KOCW 통계 데이터 수집 (메인 사이트 + stats 사이트)
- Todo 8: 추가 수집 정보 조사 보고서 작성

**Wave 4: 납품물 및 문서화**
- Todo 9: CSV 납품물 생성
- Todo 10: `docs/` 작업 계획 문서 작성
- Todo 11: GitHub 공개 준비 (README, LICENSE, .gitignore)

### Dependency matrix
| Todo | Depends on | Blocks | Can parallelize with |
| --- | --- | --- | --- |
| 1 | - | 2 | - |
| 2 | 1 | 3,4,5,6,7 | - |
| 3 | 2 | 4,6 | 5,7 |
| 4 | 2,3 | 6 | 5,7 |
| 5 | 2 | - | 3,4,6,7 |
| 6 | 2,3,4 | 9 | 5,7 |
| 7 | 2 | 9 | 3,4,5,6 |
| 8 | - | - | 1,2,3,4,5,6,7 |
| 9 | 2,3,4,5,6,7 | - | - |
| 10 | - | - | 1-9 |
| 11 | - | - | 1-9 |

## Todos
> Implementation + Test = ONE todo. Never separate.

- [ ] 1. Ruby 프로젝트 구조 및 의존성 설정
  What to do / Must NOT do: `Gemfile`, `Gemfile.lock`, `.ruby-version`, `.gitignore`, `README.md` 템플릿을 생성한다. 의존성: `sqlite3`, `nokogiri`, `httparty` 또는 `net/http` + `json`, `csv`. Must NOT do: Rails나 Sinatra 등 웹 프레임워크를 포함하지 않는다.
  Closes: GAP-5
  Parallelization: Wave 1 | Blocked by: - | Blocks: 2
  References (executor has NO interview context - be exhaustive): Ruby 3.x 표준 프로젝트 구조. lib/, bin/, db/, data/, docs/ 디렉토리 생성. bundler init으로 Gemfile 생성.
  Acceptance criteria (agent-executable): `bundle install`이 성공하고 `ruby -v`가 3.x를 출력하며 `ls lib/ bin/ db/ data/ docs/`가 모두 존재함을 확인
  QA scenarios (name the exact tool + invocation): happy - `bundle exec ruby -e "require 'sqlite3'; puts SQLite3::VERSION"` → 버전 출력. failure - `bundle install` 실패 시 Gemfile 의존성 오류 출력. Evidence `.omo/evidence/ulw/kocw-archive-plan/a1/task-1-kocw-archive-plan.txt`
  Recommended task executor category: quick
  Commit: Y | feat(project): Initialize Ruby project structure with dependencies

- [ ] 2. SQLite DB 스키마 설계 및 마이그레이션
  What to do / Must NOT do: 강의(`courses`), 차시(`lectures` 또는 `episodes`), 공지사항(`notices`), 뉴스레터(`newsletters`), 관련 자료 링크(`links`), 통계(`statistics`), 썸네일/자산(`assets`) 테이블을 설계한다. Must NOT do: 외래키 제약조건으로 복잡한 참조 무결성을 강제하지 않는다(아카이브 특성상 유연성 우선).
  Closes: GAP-1
  Parallelization: Wave 1 | Blocked by: 1 | Blocks: 3,4,5,6,7
  References (executor has NO interview context - be exhaustive): librarian 조사 결과 - 195개 대학 15,576강좌 + 25개 기관 1,968강좌. 강의 메타데이터 필드: title, professor, university/org, term/year, description, summary, content_type, ccl_license, language, ai_subtitle_flag, sign_language_flag, thumbnail_url. 차시 필드: course_id, episode_number, title, description, duration, content_type. 통계 필드: source(메인사이트/stats), metric_name, year, month, value, unit.
  Acceptance criteria (agent-executable): `ruby db/migrate.rb` 실행 후 `sqlite3 db/kocw_archive.db ".schema"`가 모든 테이블을 출력함을 확인
  QA scenarios: happy - 스키마 생성 후 `SELECT name FROM sqlite_master WHERE type='table';` → 7개 이상 테이블. failure - 잘못된 SQL 타입으로 마이그레이션 실패. Evidence `.omo/evidence/ulw/kocw-archive-plan/a1/task-2-kocw-archive-plan.txt`
  Recommended task executor category: quick
  Commit: Y | feat(db): Create SQLite schema for courses, episodes, notices, links, stats

- [ ] 3. KOCW 강의 목록 수집기 (JSON 엔드포인트)
  What to do / Must NOT do: `/home/search/majorCourses/lev.do`, `/home/special/themeCourses/lev.do`, `/home/enrolment/enrolmentLev.do`, `/home/search/univCoursesAll.do`, `/home/search/orgCoursesAll.do` 등의 엔드포인트를 호출하여 강의 목록을 수집한다. Must NOT do: 페이지당 요청 간격을 0.5초 미만으로 하지 않는다(예의 바른 크롤링).
  Closes: GAP-2 (일부)
  Parallelization: Wave 2 | Blocked by: 2 | Blocks: 4,6
  References (executor has NO interview context - be exhaustive): AJAX 엔드포인트는 POST 메서드, 파라미터: taxonCode, sortOption, page, ft 등. 응답: JSON 배열 `[{"levCourseList": [...], "paging": "...", "totalCount": N}]`. 강의 ID는 `cid`(암호화)와 `kemId`(숫자) 두 가지 형태.
  Acceptance criteria (agent-executable): `ruby bin/fetch_courses.rb` 실행 후 `sqlite3 db/kocw_archive.db "SELECT COUNT(*) FROM courses;"`가 1000 이상의 강의 수를 출력
  QA scenarios: happy - 10개 페이지 수집 후 DB에 100+ 행 삽입 확인. failure - 잘못된 POST 파라미터로 500 오류 수신 시 재시도 로그 기록. Evidence `.omo/evidence/ulw/kocw-archive-plan/a1/task-3-kocw-archive-plan.txt`
  Recommended task executor category: deep-low
  Commit: Y | feat(scraper): Add course list fetcher for KOCW JSON endpoints

- [ ] 4. KOCW 강의 상세 및 차시 정보 수집기
  What to do / Must NOT do: `/home/cview.do?cid=...` 또는 `/home/search/kemView.do?kemId=...`의 HTML을 파싱하여 강의 상세 설명, 차시 목록(차시보기), 관련 자료 링크를 추출한다. Must NOT do: 영상 파일 URL을 실제 다운로드하지 않는다.
  Closes: GAP-2 (일부)
  Parallelization: Wave 2 | Blocked by: 2,3 | Blocks: 6
  References (executor has NO interview context - be exhaustive): 강의 상세 페이지 HTML 구조. 차시 목록은 AJAX로 `/home/search/searchLectureLoc.do` (lectureId 파라미터)를 호출하여 로드. 콘텐츠 타입 아이콘: 비디오(1), 오디오(2), 문서/PDF(3), 기타(4), 플래시(6), 저작도구(7).
  Acceptance criteria (agent-executable): `ruby bin/fetch_course_details.rb` 실행 후 `sqlite3 db/kocw_archive.db "SELECT COUNT(*) FROM episodes;"`가 0보다 큰 값을 출력
  QA scenarios: happy - 10개 강의 상세 수집 후 episodes 테이블에 데이터 삽입 확인. failure - 404 페이지나 비공개 강의 접근 시 스킵하고 로그 기록. Evidence `.omo/evidence/ulw/kocw-archive-plan/a1/task-4-kocw-archive-plan.txt`
  Recommended task executor category: deep-low
  Commit: Y | feat(scraper): Add course detail and episode fetcher

- [ ] 5. 공지사항 및 뉴스레터 수집기
  What to do / Must NOT do: `/home/notice/noticeList.do?nt=1` (공지사항)과 `?nt=2` (뉴스레터)의 모든 페이지를 순회하여 제목, 작성자, 조회수, 등록일, 본문 HTML을 수집한다. Must NOT do: 공지사항의 첨부 파일을 다운로드하지 않는다(링크만 기록).
  Closes: GAP-2 (일부)
  Parallelization: Wave 2 | Blocked by: 2 | Blocks: -
  References (executor has NO interview context - be exhaustive): 공지사항은 `goPage(page)` 폼 서브밋, 페이지당 10개. 상세 URL: `/home/notice/noticeView.do?nt={type}&noticeId={id}`. 공지사항 이미지 경로: `/home/images/notice/`. 현재 약 494개 공지사항 존재.
  Acceptance criteria (agent-executable): `ruby bin/fetch_notices.rb` 실행 후 `sqlite3 db/kocw_archive.db "SELECT COUNT(*) FROM notices;"`와 `SELECT COUNT(*) FROM newsletters;`가 각각 100 이상, 50 이상을 출력
  QA scenarios: happy - 전체 페이지 순회 후 notices + newsletters 테이블에 데이터 삽입 확인. failure - 페이지네이션 끝 감지 실패 시 무한 루프 방지(timeout 30초). Evidence `.omo/evidence/ulw/kocw-archive-plan/a1/task-5-kocw-archive-plan.txt`
  Recommended task executor category: deep-low
  Commit: Y | feat(scraper): Add notices and newsletters fetcher

- [ ] 6. 관련 자료 링크 및 썸네일 URL 검증
  What to do / Must NOT do: 수집된 강의별로 관련 자료 링크(RISS, 외부 자원, 다운로드)와 썸네일 URL을 추출하여 `links`와 `assets` 테이블에 저장한다. 썸네일 URL에 대해 HEAD 요청으로 파일 존재 여부(HTTP 200)를 검증하고 `assets.status` 컬럼에 기록한다. Must NOT do: 파일을 실제 다운로드하지 않는다.
  Closes: GAP-2 (일부)
  Parallelization: Wave 3 | Blocked by: 2,3,4 | Blocks: 9
  References (executor has NO interview context - be exhaustive): 썸네일 경로: `/home/common/contents/thumbnail/...`. 관련 검색: `/home/search/relateSearch.do` (title, keyword, kemId 파라미터). HEAD 요청으로 Content-Type과 Content-Length 확인 가능.
  Acceptance criteria (agent-executable): `ruby bin/verify_assets.rb` 실행 후 `sqlite3 db/kocw_archive.db "SELECT COUNT(*) FROM assets WHERE status='ok';"`가 0보다 큰 값을 출력
  QA scenarios: happy - 100개 썸네일 URL 검증 후 ok/failed/broken 상태 분류 확인. failure - 타임아웃(5초) 초과 시 failed 상태 기록. Evidence `.omo/evidence/ulw/kocw-archive-plan/a1/task-6-kocw-archive-plan.txt`
  Recommended task executor category: deep-low
  Commit: Y | feat(scraper): Add related links and thumbnail URL verifier

- [ ] 7. KOCW 통계 데이터 수집 (메인 사이트 + stats 사이트)
  What to do / Must NOT do: (a) 메인 사이트의 `/home/kocwStatisticsExcel.do`를 호출하여 월별 Excel 리포트를 다운로드하고 파싱한다. (b) `https://kocwstats.netlify.app/`의 HTML 소스에서 하드코딩된 JavaScript 객체(`MONTHLY_DATA`, `ANNUAL_DATA`, `DB_MONTHLY`, `DB_ANNUAL`)를 정규식 또는 JSON 파서로 추출하여 `statistics` 테이블에 저장한다. Must NOT do: Excel 파일의 바이너리를 그대로 보관하지 않고 파싱 후 데이터만 DB에 저장한다.
  Closes: GAP-6
  Parallelization: Wave 3 | Blocked by: 2 | Blocks: 9
  References (executor has NO interview context - be exhaustive): kocwstats.netlify.app는 단일 HTML 파일(~2,950줄)로 Chart.js 4.4.1 기반. 데이터는 JS 상수로 하드코딩: `const MONTHLY_DATA = {...}`, `const ANNUAL_DATA = {...}`, `const DB_MONTHLY = {...}`, `const DB_ANNUAL = {...}`. 메인 사이트 Excel 엔드포인트는 월별 선택 가능(2013-2026).
  Acceptance criteria (agent-executable): `ruby bin/fetch_statistics.rb` 실행 후 `sqlite3 db/kocw_archive.db "SELECT COUNT(*) FROM statistics;"`가 100 이상을 출력
  QA scenarios: happy - stats 사이트 HTML 다운로드 후 JS 객체 파싱 → statistics 테이블 삽입 확인. failure - HTML 구조 변경으로 파싱 실패 시 오류 메시지와 원본 HTML 스니펫 로그. Evidence `.omo/evidence/ulw/kocw-archive-plan/a1/task-7-kocw-archive-plan.txt`
  Recommended task executor category: deep-low
  Commit: Y | feat(scraper): Add statistics fetcher for main site Excel and stats site JS data

- [ ] 8. 추가 수집 정보 조사 보고서 작성
  What to do / Must NOT do: 로그인이 필요한 영역(내강의실, 댓글, 수강확인증, 강의추천, 오류접수)과 수집되지 않은 데이터(사용자 리뷰, 개인 클립, API 호출 로그)에 대해 수집 가능성, 접근 조건(RISS 계정 필요, 2026.09.30 마감), 수집 방법, 윤리/법적 고려사항을 문서화한다. Must NOT do: 실제 로그인이나 댓글 수집을 구현하지 않는다.
  Closes: GAP-3
  Parallelization: Wave 3 | Blocked by: - | Blocks: -
  References (executor has NO interview context - be exhaustive): 로그인 URL `/home/login.do`, RISS SSO 연동. 내강의실 메뉴: 강의리스트, 수강확인증강의, 사용자의견, 내강의클립. 댓글 엔드포인트: `/home/search/searchComment.do` (kemId 파라미터, 공개 읽기 가능하나 쓰기는 로그인 필요). 수강확인증 발급은 95% 수강 완료 필요.
  Acceptance criteria (agent-executable): `docs/additional_collection_research.md` 파일이 존재하고 500단어 이상의 내용을 포함
  QA scenarios: happy - 문서가 5개 이상의 추가 수집 대상을 포함하고 각각에 대해 feasibility(high/medium/low)와 requirements를 기술. failure - 문서 누락 시 `test -f docs/additional_collection_research.md` 실패. Evidence `.omo/evidence/ulw/kocw-archive-plan/a1/task-8-kocw-archive-plan.txt`
  Recommended task executor category: unspecified-low
  Commit: Y | docs: Add research report on additional collectible information

- [ ] 9. CSV 납품물 생성
  What to do / Must NOT do: SQLite DB의 각 테이블(courses, episodes, notices, newsletters, links, assets, statistics)을 별도의 CSV 파일로 납품한다. `data/csv/` 디렉토리에 저장. Must NOT do: CSV에 이진 데이터나 HTML 태그를 포함하지 않는다(텍스트는 정제하여 저장).
  Closes: GAP-2 (완료)
  Parallelization: Wave 4 | Blocked by: 2,3,4,5,6,7 | Blocks: -
  References (executor has NO interview context - be exhaustive): Ruby CSV 표준 라이브러리 사용. 인코딩 UTF-8. 각 CSV는 헤더 행 포함.
  Acceptance criteria (agent-executable): `ruby bin/export_csv.rb` 실행 후 `ls data/csv/`에 7개 이상의 CSV 파일이 생성됨을 확인
  QA scenarios: happy - CSV 파일 열기 후 헤더 행과 100개 이상의 데이터 행 확인. failure - 빈 테이블 CSV 출력 시 1행(헤더만) 생성. Evidence `.omo/evidence/ulw/kocw-archive-plan/a1/task-9-kocw-archive-plan.txt`
  Recommended task executor category: quick
  Commit: Y | feat(export): Add CSV exporter for all archive tables

- [ ] 10. `docs/` 작업 계획 문서 작성
  What to do / Must NOT do: 본 계획 문서(`.omo/plans/kocw-archive-plan.md`)를 기반으로 `docs/kocw-archive-plan.md`를 작성한다. 실행자가 추가 질문 없이 따라할 수 있는 수준의 상세 지침(설치, 실행, 문제 해결)을 포함한다. Must NOT do: 구현 코드를 문서에 포함하지 않는다(링크만 제공).
  Closes: GAP-4
  Parallelization: Wave 4 | Blocked by: - | Blocks: -
  References (executor has NO interview context - be exhaustive): docs/ 폴터는 프로젝트 루트에 위치. Markdown 형식. 섹션: 프로젝트 개요, 설치 방법, 실행 방법, DB 스키마 설명, 수집 항목 목록, 주의사항, 기여 방법.
  Acceptance criteria (agent-executable): `test -f docs/kocw-archive-plan.md && wc -w docs/kocw-archive-plan.md`가 300단어 이상을 출력
  QA scenarios: happy - 문서에 설치, 실행, 문제 해결 섹션이 모두 존재. failure - 필수 섹션 누락. Evidence `.omo/evidence/ulw/kocw-archive-plan/a1/task-10-kocw-archive-plan.txt`
  Recommended task executor category: unspecified-low
  Commit: Y | docs: Add detailed work plan document in docs/

- [ ] 11. GitHub 공개 준비 (README, LICENSE, .gitignore)
  What to do / Must NOT do: 프로젝트를 GitHub에 공개할 수 있도록 `README.md`(프로젝트 소개, 설치, 사용법, 스크린샷/예시), `LICENSE`(MIT 권장), `.gitignore`(Ruby, SQLite, OS 관련)를 작성한다. Must NOT do: DB 파일(`*.db`)이나 CSV 파일을 Git에 포함하지 않는다(`.gitignore`에 명시).
  Closes: GAP-5 (완료)
  Parallelization: Wave 4 | Blocked by: - | Blocks: -
  References (executor has NO interview context - be exhaustive): GitHub Ruby 프로젝트 표준 `.gitignore` 템플릿. README에는 KOCW 서비스 종료일(2026.12.30)과 아카이브 목적을 명시. LICENSE는 MIT(간단하고 개방적) 또는 CC0(데이터용) 중 선택.
  Acceptance criteria (agent-executable): `test -f README.md && test -f LICENSE && git check-ignore -q db/kocw_archive.db`가 성공(마지막 명령은 ignored면 0 반환)
  QA scenarios: happy - `git ls-files | grep -E '\.(db|csv)$'`가 빈 출력(바이너리/데이터 파일 미포함). failure - `.gitignore` 누락으로 SQLite 파일이 tracked 상태. Evidence `.omo/evidence/ulw/kocw-archive-plan/a1/task-11-kocw-archive-plan.txt`
  Recommended task executor category: quick
  Commit: Y | chore(repo): Prepare for GitHub release with README, LICENSE, .gitignore

## Final verification wave
> Runs in parallel after ALL todos. ALL must APPROVE. Surface results and wait for the user's explicit okay before declaring complete.
- [ ] F1. DB 스키마 및 데이터 무결성 검증
  What: `sqlite3 db/kocw_archive.db`로 각 테이블의 행 수, NULL 비율, 중복 키 수를 집계. courses >= 1000, episodes >= 1000, notices >= 100, newsletters >= 50, statistics >= 100, assets >= 100.
  Recommended task executor category: unspecified-high
  Evidence: `.omo/evidence/ulw/kocw-archive-plan/a1/task-F1-kocw-archive-plan.txt`

- [ ] F2. CSV 납품물 품질 검증
  What: `csvlint` 또는 Ruby 스크립트로 모든 CSV의 인코딩(UTF-8), 헤더 일관성, 빈 파일 여부, 특수문자 파싱 오류 검사.
  Recommended task executor category: unspecified-high
  Evidence: `.omo/evidence/ulw/kocw-archive-plan/a1/task-F2-kocw-archive-plan.txt`

- [ ] F3. 수집 완결성 검증
  What: 메인 KOCW 사이트의 총 강의 수(약 17,500)와 DB의 courses 행 수를 비교. 80% 이상 수집 시 PASS. 공지사항 총 개수와 notices 행 수를 비교.
  Recommended task executor category: unspecified-high
  Evidence: `.omo/evidence/ulw/kocw-archive-plan/a1/task-F3-kocw-archive-plan.txt`

- [ ] F4. 이상 상태 충족 검증
  What: IS-1~IS-7 각각에 대해 대응하는 todo가 완료되었는지, 산출물이 존재하는지 매핑 검사. docs/ 문서와 추가 조사 보고서 존재 여부 확인. GitHub 준비 상태 확인.
  Recommended task executor category: unspecified-high
  Evidence: `.omo/evidence/ulw/kocw-archive-plan/a1/task-F4-kocw-archive-plan.txt`

## Commit strategy
- 각 Todo 완료 후 독립 커밋 (atomic commit)
- 커밋 메시지는 Conventional Commits 형식 준수: `feat(scraper): ...`, `feat(db): ...`, `docs: ...`, `chore(repo): ...`
- `feat`는 기능 추가, `docs`는 문서, `chore`는 설정/환경
- 최종 검증 wave 완료 후 `git tag v0.1.0` 생성

## Success criteria
> One row per IS row. The plan is complete only when every IS row has a delivering todo and a proving QA scenario; F4 checks the delivered behavior against these rows 1:1, and a shortfall becomes new `- [ ] N.` rows, never a note.
| IS | Delivering todo(s) | Proving QA scenario | Evidence |
| --- | --- | --- | --- |
| IS-1 | 2,3,4 | F1: courses >= 1000, episodes >= 1000 | `.omo/evidence/ulw/kocw-archive-plan/a1/task-F1-kocw-archive-plan.txt` |
| IS-2 | 2,5 | F1: notices >= 100, newsletters >= 50 | `.omo/evidence/ulw/kocw-archive-plan/a1/task-F1-kocw-archive-plan.txt` |
| IS-3 | 2,6 | F1: links >= 100 | `.omo/evidence/ulw/kocw-archive-plan/a1/task-F1-kocw-archive-plan.txt` |
| IS-4 | 8 | F4: docs/additional_collection_research.md 존재 및 500단어 이상 | `.omo/evidence/ulw/kocw-archive-plan/a1/task-F4-kocw-archive-plan.txt` |
| IS-5 | 10 | F4: docs/kocw-archive-plan.md 존재 및 300단어 이상 | `.omo/evidence/ulw/kocw-archive-plan/a1/task-F4-kocw-archive-plan.txt` |
| IS-6 | 1,11 | F4: README.md, LICENSE, .gitignore 존재, .db ignored | `.omo/evidence/ulw/kocw-archive-plan/a1/task-F4-kocw-archive-plan.txt` |
| IS-7 | 2,7 | F1: statistics >= 100 | `.omo/evidence/ulw/kocw-archive-plan/a1/task-F1-kocw-archive-plan.txt` |
