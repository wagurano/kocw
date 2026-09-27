# KOCW Archive

[![Ruby](https://img.shields.io/badge/Ruby-3.4.9-CC342D?logo=ruby&logoColor=white)](https://www.ruby-lang.org)
[![SQLite](https://img.shields.io/badge/SQLite-003B57?logo=sqlite&logoColor=white)](https://www.sqlite.org)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](./LICENSE)

A Ruby-based archive tool that crawls, parses, and persists lecture data from
**KOCW (Korean OpenCourseWare)** into a local SQLite database for offline
reference and long-term preservation.

## Overview

KOCW has been a flagship Korean open educational resource platform operated by
KERIS (Korea Education and Research Information Service), hosting thousands of
university lectures from institutions across the country.

**The KOCW service is scheduled to end on 2026-12-30.**

To prevent the loss of these valuable educational resources, this project
provides a reproducible, automated way to mirror KOCW's public data — course
metadata, lecture episodes, announcements, newsletters, related links, usage
statistics, and asset references — into a self-contained SQLite database that
can be queried, exported, and archived indefinitely.

## Features

- **7 archive tables** capturing the full breadth of KOCW's public data:
  - `courses` — lecture-level metadata (title, professor, university, term, license, ...)
  - `episodes` — per-lecture video / audio segments with duration and player IDs
  - `notices` — KOCW announcements
  - `newsletters` — KOCW periodic newsletter archive
  - `links` — course-related URLs (RISS, downloads, related lectures, ...)
  - `statistics` — per-month / per-year usage metrics
  - `assets` — thumbnail and image asset URLs with integrity-check status
- **CSV export** of every table for portability and spreadsheet analysis
- **Polite scraping** — pacing, retries, and a custom HTTP client that
  respects KOCW's infrastructure
- **Idempotent schema migration** via `db/migrate.rb` — rebuild the database
  from scratch on every run
- **Asset verification** to flag broken thumbnails and notice images

## Installation

Requirements:

- **Ruby 3.4.9** (managed via `.ruby-version` / asdf)
- **Bundler 4.x**

```bash
bundle install
```

This installs the project's runtime gems:

| Gem       | Role                              |
| --------- | --------------------------------- |
| `sqlite3` | Local persistence                 |
| `nokogiri` | HTML/XML parsing                 |
| `httparty` | HTTP client for KOCW endpoints   |

`csv` is part of Ruby's standard library — no extra gem required.

## Usage

The archive is built in stages. Run each step from the project root:

```bash
# 1. Install dependencies
bundle install

# 2. Initialize (or rebuild) the local SQLite database
ruby db/migrate.rb

# 3. Run the fetchers to populate each table
ruby bin/fetch_courses.rb
ruby bin/fetch_notices.rb
ruby bin/fetch_course_details.rb
ruby bin/verify_assets.rb
ruby bin/fetch_statistics.rb

# 4. Export every table to CSV for portable analysis
ruby bin/export_csv.rb
```

Each fetcher writes directly to `db/kocw_archive.db` and logs progress to
stdout. Re-running a fetcher is safe — rows are upserted by their natural
keys (e.g. `kem_id`, `notice_id`).

## Project Structure

```
kocw/
├── README.md              # This file
├── LICENSE                # GNU GPL v3.0 License
├── Gemfile                # Ruby gem dependencies
├── Gemfile.lock           # Locked gem versions
├── .ruby-version          # Pinned Ruby version (3.4.9)
│
├── bin/                   # Executable scripts (CLI entrypoints)
│   ├── fetch_courses.rb
│   ├── fetch_notices.rb
│   ├── fetch_course_details.rb
│   ├── verify_assets.rb
│   ├── fetch_statistics.rb
│   └── export_csv.rb
│
├── db/                    # SQLite database and schema
│   ├── kocw_archive.db    # Generated database (gitignored)
│   └── migrate.rb         # Schema migration (creates 7 tables + indexes)
│
├── lib/                   # Application source code
│   └── kocw_client.rb     # HTTP client for KOCW endpoints
│
├── data/
│   └── csv/               # Downloaded CSV inputs / exports (gitignored)
│
├── docs/                  # Project documentation and notes
│
└── tmp/                   # Temporary working files (gitignored)
```

## Data Collected

A summary of what each table contains:

| Table         | Purpose                                                              |
| ------------- | -------------------------------------------------------------------- |
| `courses`     | Lecture-level metadata: `kem_id`, `cid`, title, professor, university, department, term, year, description, summary, content type, CC license, language, AI / sign-language flags, thumbnail, view count. |
| `episodes`    | Per-lecture video / audio segments linked to a course: episode number, title, description, duration, content type, KOCW player `lecture_id`. |
| `notices`     | KOCW announcements (`notice_type = 1`): title, author, view count, published timestamp, full HTML body. |
| `newsletters` | KOCW newsletter archive (`notice_type = 2`): same shape as notices, kept separate for per-source queries. |
| `links`       | Course-related URLs: RISS references, download links, related lectures — each tagged with a `link_type`. |
| `statistics`  | Per-month / per-year metrics from KOCW's main and stats pages: web visits, mobile visits, lecture counts, search volume, etc. |
| `assets`      | Thumbnail and image asset URLs with verification status (`ok`, `failed`, `broken`, `timeout`), HTTP content type, and size. |

CSV exports for every table are written under `data/csv/`.

## Contributing

Contributions are welcome — bug reports, schema improvements, additional
fetchers, and documentation fixes.

1. Fork the repository
2. Create a feature branch (`git checkout -b feat/my-improvement`)
3. Make your change and add or update tests where applicable
4. Ensure `bundle install` succeeds and `ruby db/migrate.rb` produces the
   expected 7 tables
5. Open a pull request with a clear description of the change

Please keep scraping behavior polite (pacing, retries, sensible User-Agent)
so we don't put unnecessary load on KOCW's infrastructure during its final
months of operation.

## 라이선스 (License)

> ⚠️ **주의 (Caution)**: 이 프로젝트는 **GNU GPL v3.0** 라이선스를 적용하고 있습니다. 이는 강력한 카피레프트(copyleft) 라이선스로, 본 저장소를 포크하거나 수정하여 **배포(공개 또는 비공개 모두 포함)**할 경우, **수정된 소스 코드도 동일한 GPL v3.0 조건으로 공개**해야 함을 의미합니다. 본 코드를 상업적으로 사용하거나 낮은 부분에 포함하는 것은 가능하지만, 그 파생 작업물 역시 GPL v3.0으로 공개되어야 합니다. 라이선스 선택에 신중을 기해 주시기 바랍니다.

이 프로젝트의 코드(스크래핑 도구, 스크립트, 데이터베이스 스키마, 마이그레이션
코드 등)는 **GNU GPL v3.0 (GNU General Public License Version 3)** 하에
배포됩니다. 전체 라이선스 전문은 [`LICENSE`](./LICENSE) 파일을 참고하세요.

다만 GPL 적용 범위를 명확히 하기 위해 다음 사항을 분명히 합니다.

1. **프로젝트 코드 라이선스 (Project Code License)**: 본 저장소에 포함된
   모든 소스 코드 — 스크래핑 도구, 스크립트, 데이터베이스 스키마,
   마이그레이션 코드, HTTP 클라이언트 등 — 는 **GNU GPL v3.0** 하에
   라이선스됩니다. 본 저장소를 포크하거나 수정본을 배포할 경우, 동일한
   GPL v3.0 조건을 따라야 합니다.

2. **KOCW 데이터는 GPL이 아님 (KOCW Data Is NOT GPL)**: 본 도구를 통해
   스크래핑된 KOCW 강의 메타데이터(`courses`, `episodes`), 강의 설명,
   공지사항(`notices`), 뉴스레터(`newsletters`), 관련 링크(`links`),
   통계(`statistics`), 그리고 그 외 모든 아카이브된 콘텐츠는 **본 GPL
   라이선스의 적용을 받지 않습니다**. 해당 데이터의 저작권은 각 강의의
   원저작자(대학교, 교수, KERIS 등)에 있으며, KOCW가 정한 크리에이티브
   커먼즈 (Creative Commons, CCL) 라이선스 정책의 적용을 받습니다.

3. **데이터에 대한 GPL 전파 없음 (No GPL Infection on Data)**: GPL
   라이선스는 본 저장소의 **소스 코드에만** 적용됩니다. GPL의 카피레프트
   (copyleft) 효과는 데이터베이스(`db/kocw_archive.db`) 또는 CSV 내보내기
   파일(`data/csv/`)에 저장된 아카이브된 KOCW 데이터로 **전파되지
   않습니다**. 즉, 본 도구의 GPL 코드와 별도로, KOCW 데이터는 각 강의에
   표시된 CCL 조건에 따라 자유롭게 사용할 수 있습니다.

4. **원 저작권 존중 의무 (Users Must Respect Original Copyright)**: 본
   도구를 사용하거나 본 저장소에서 생성된 데이터베이스/CSV를 활용하는
   모든 사용자는 KOCW의 이용약관(terms of service)을 준수해야 하며,
   원 콘텐츠 작성자(대학교, 교수, KERIS)의 지적 재산권을 존중해야 합니다.
   강의 데이터를 사용하거나 재배포할 때는 각 강의에 표시된 CCL 라이선스
   조건을 반드시 확인하시기 바랍니다.

5. **상표권 (Trademark)**: "KOCW"는 한국 정부 및 KERIS(한국교육과정평가원 /
   Korea Education and Research Information Service)의 등록 상표입니다.
   본 프로젝트는 KOCW 또는 KERIS와 무관한 독립적인 커뮤니티 활동이며,
   KOCW / KERIS의 공식 제품, 서비스, 또는 보증 활동을 의미하지 않습니다.

요약하자면, **본 저장소의 GPL v3.0은 작성된 코드에만 적용되며, 수집된
KOCW 데이터 자체에는 적용되지 않습니다.** 모든 사용자는 원저작자의
저작권과 KOCW의 CCL 정책을 존중해야 합니다.

## Acknowledgments

- **KOCW (Korean OpenCourseWare)** — for hosting and curating thousands of
  open lectures from universities across Korea.
- **KERIS (한국교육과정평가원 / Korea Education and Research Information
  Service)** — for operating and maintaining the KOCW platform and its
  open data infrastructure.