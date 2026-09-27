#!/usr/bin/env ruby
# frozen_string_literal: true

# db/migrate.rb -- Schema migration for the KOCW Archive database.
#
# Creates a fresh SQLite database with the 7 archive tables:
#   courses, episodes, notices, newsletters, links, statistics, assets
# plus supporting indexes.
#
# Archive semantics:
#   * Existing DB file is removed before recreation. This is an idempotent
#     rebuild -- Wave 2 collectors re-populate rows from KOCW sources on
#     every run, so retaining stale schema state is undesirable.
#   * Foreign-key constraints are intentionally NOT enforced. Orphaned or
#     re-numbered references from upstream are expected; flexibility wins
#     over referential integrity here.
#
# Invocations (both work):
#   bundle exec ruby db/migrate.rb
#   ruby db/migrate.rb          # via `require "bundler/setup"` below

require "bundler/setup"
require "sqlite3"
require "fileutils"

DB_PATH = File.expand_path("kocw_archive.db", __dir__)

SCHEMA = <<~SQL
  -- Drop existing tables in reverse creation order. No FK constraints are
  -- declared, but dropping in reverse avoids any incidental coupling and
  -- makes the rebuild idempotent.
  DROP TABLE IF EXISTS assets;
  DROP TABLE IF EXISTS statistics;
  DROP TABLE IF EXISTS links;
  DROP TABLE IF EXISTS newsletters;
  DROP TABLE IF EXISTS notices;
  DROP TABLE IF EXISTS episodes;
  DROP TABLE IF EXISTS courses;

  -- ============================================================
  -- courses : lecture-level metadata
  -- kem_id = KOCW numeric ID, cid = encrypted (string) ID.
  -- Either identifier alone is sufficient for upstream lookup.
  -- ============================================================
  CREATE TABLE courses (
    id                 INTEGER PRIMARY KEY AUTOINCREMENT,
    kem_id             INTEGER NOT NULL,
    cid                TEXT    NOT NULL,
    title              TEXT    NOT NULL,
    professor          TEXT,
    university         TEXT,
    organization       TEXT,
    department         TEXT,
    term               TEXT,
    year               INTEGER,
    description        TEXT,
    summary            TEXT,
    content_type       INTEGER,   -- 1=video, 2=audio, 3=doc/pdf, 4=other, 6=flash, 7=authoring
    ccl_license        TEXT,
    language           TEXT,
    ai_subtitle_flag   INTEGER DEFAULT 0,
    sign_language_flag INTEGER DEFAULT 0,
    thumbnail_url      TEXT,
    view_count         INTEGER DEFAULT 0,
    created_at         DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at         DATETIME DEFAULT CURRENT_TIMESTAMP
  );

  CREATE UNIQUE INDEX idx_courses_kem_id       ON courses(kem_id);
  CREATE UNIQUE INDEX idx_courses_cid          ON courses(cid);
  CREATE        INDEX idx_courses_university   ON courses(university);
  CREATE        INDEX idx_courses_year         ON courses(year);
  CREATE        INDEX idx_courses_content_type ON courses(content_type);

  -- ============================================================
  -- episodes : per-lecture video / audio segments
  -- lecture_id is used by KOCW's AJAX player endpoint.
  -- ============================================================
  CREATE TABLE episodes (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    course_id      INTEGER NOT NULL,
    episode_number INTEGER,
    title          TEXT,
    description    TEXT,
    duration       TEXT,        -- e.g. "45:30"
    content_type   INTEGER,
    lecture_id     TEXT,
    created_at     DATETIME DEFAULT CURRENT_TIMESTAMP
  );

  CREATE INDEX idx_episodes_course_id  ON episodes(course_id);
  CREATE INDEX idx_episodes_lecture_id ON episodes(lecture_id);

  -- ============================================================
  -- notices : KOCW announcements (notice_type = 1)
  -- ============================================================
  CREATE TABLE notices (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    notice_id    INTEGER NOT NULL,
    notice_type  INTEGER,
    title        TEXT    NOT NULL,
    author       TEXT,
    view_count   INTEGER DEFAULT 0,
    published_at DATETIME,
    content_html TEXT,
    created_at   DATETIME DEFAULT CURRENT_TIMESTAMP
  );

  CREATE INDEX idx_notices_notice_id     ON notices(notice_id);
  CREATE INDEX idx_notices_notice_type   ON notices(notice_type);
  CREATE INDEX idx_notices_published_at  ON notices(published_at);

  -- ============================================================
  -- newsletters : KOCW newsletter archive (notice_type = 2)
  -- Same shape as notices but kept in its own table so per-source
  -- archive queries can target either feed independently.
  -- ============================================================
  CREATE TABLE newsletters (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    notice_id    INTEGER NOT NULL,
    title        TEXT    NOT NULL,
    author       TEXT,
    view_count   INTEGER DEFAULT 0,
    published_at DATETIME,
    content_html TEXT,
    created_at   DATETIME DEFAULT CURRENT_TIMESTAMP
  );

  CREATE INDEX idx_newsletters_notice_id    ON newsletters(notice_id);
  CREATE INDEX idx_newsletters_published_at ON newsletters(published_at);

  -- ============================================================
  -- links : course-related URLs (RISS, downloads, related lectures)
  -- ============================================================
  CREATE TABLE links (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    course_id   INTEGER NOT NULL,
    url         TEXT    NOT NULL,
    link_type   TEXT,           -- 'riss' | 'external' | 'download' | 'related_lecture' | ...
    description TEXT,
    created_at  DATETIME DEFAULT CURRENT_TIMESTAMP
  );

  CREATE        INDEX        idx_links_course_id  ON links(course_id);
  CREATE        INDEX        idx_links_link_type  ON links(link_type);
  CREATE UNIQUE INDEX        idx_links_course_url ON links(course_id, url);

  -- ============================================================
  -- statistics : per-month / per-year metrics scraped from
  -- KOCW's main + stats pages. month may be NULL for annual totals.
  -- ============================================================
  CREATE TABLE statistics (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    source      TEXT,           -- 'main_site' | 'stats_site' | ...
    metric_name TEXT    NOT NULL, -- 'web_visits' | 'mobile_visits' | 'lecture_count' | ...
    category    TEXT,           -- 'web_access' | 'mobile' | 'search' | 'certificate' | 'api' | 'lecture_db'
    year        INTEGER,
    month       INTEGER,
    value       REAL,
    unit        TEXT,           -- 'count' | 'percent' | ...
    created_at  DATETIME DEFAULT CURRENT_TIMESTAMP
  );

  CREATE INDEX idx_statistics_year_month   ON statistics(year, month);
  CREATE INDEX idx_statistics_source       ON statistics(source);
  CREATE INDEX idx_statistics_metric_name  ON statistics(metric_name);
  CREATE INDEX idx_statistics_category     ON statistics(category);

  -- ============================================================
  -- assets : thumbnail / image asset URLs + integrity check status
  -- course_id is nullable so notice / newsletter images can also live here.
  -- ============================================================
  CREATE TABLE assets (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    course_id      INTEGER,
    url            TEXT    NOT NULL,
    asset_type     TEXT,        -- 'thumbnail' | 'notice_image' | ...
    status         TEXT,        -- 'ok' | 'failed' | 'broken' | 'timeout'
    content_type   TEXT,        -- HTTP Content-Type from HEAD/GET
    content_length INTEGER,
    checked_at     DATETIME,
    created_at     DATETIME DEFAULT CURRENT_TIMESTAMP
  );

  CREATE INDEX idx_assets_course_id  ON assets(course_id);
  CREATE INDEX idx_assets_url        ON assets(url);
  CREATE INDEX idx_assets_asset_type ON assets(asset_type);
  CREATE INDEX idx_assets_status     ON assets(status);
SQL

EXPECTED_TABLES = %w[
  courses
  episodes
  notices
  newsletters
  links
  statistics
  assets
].freeze

def migrate!(db_path, schema)
  FileUtils.rm_f(db_path)

  db = SQLite3::Database.new(db_path)
  begin
    db.execute_batch(schema)
  ensure
    db.close
  end
end

def verify!(db_path, expected)
  db = SQLite3::Database.new(db_path, readonly: true)
  begin
    found = db
      .execute("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
      .flatten
  ensure
    db.close
  end

  missing = expected - found
  extra   = found - expected

  if missing.any? || extra.any?
    abort("Schema verification failed. missing=#{missing.inspect} extra=#{extra.inspect}")
  end

  found
end

def main
  migrate!(DB_PATH, SCHEMA)
  tables = verify!(DB_PATH, EXPECTED_TABLES)

  puts "[OK] Migrated: #{DB_PATH}"
  puts "     Tables (#{tables.size}): #{tables.join(", ")}"
end

main if $PROGRAM_NAME == __FILE__