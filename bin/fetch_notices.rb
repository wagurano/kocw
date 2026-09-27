#!/usr/bin/env ruby
# frozen_string_literal: true

# bin/fetch_notices.rb -- Fetch and archive KOCW notices and newsletters.
#
# Iterates the notice board (nt_type=1) and the newsletter board (nt_type=2),
# walks pages 1..5 of each, and persists each notice into the local SQLite
# archive using INSERT OR REPLACE so re-runs are idempotent.
#
# Usage:
#   bundle exec ruby bin/fetch_notices.rb

require_relative "../lib/kocw_client"
require "sqlite3"
require "nokogiri"
require "fileutils"

DB_PATH = File.expand_path("../db/kocw_archive.db", __dir__)

NOTICE_LABELS = { 1 => "notices", 2 => "newsletters" }.freeze
PAGE_RANGE    = (1..5).freeze

# ---------------------------------------------------------------------------
# Fetches a single page of the notice/newsletter list.
# Returns a Nokogiri::HTML::Document.
# ---------------------------------------------------------------------------
def fetch_notice_list(nt_type, page)
  client = KOCWClient.new
  client.get("/home/notice/noticeList.do", { nt: nt_type, page: page })
end

# ---------------------------------------------------------------------------
# Extracts an array of notice hashes from a list page.
# Each hash has :notice_id, :title, :author, :view_count, :published_at.
# Uses CSS selectors against the `.board_list` table.
# ---------------------------------------------------------------------------
def parse_notice_list(doc)
  return [] unless doc.is_a?(Nokogiri::HTML::Document)

  rows = doc.css(".board_list tr")
  rows.filter_map do |row|
    notice_id = extract_notice_id(row)
    next if notice_id.nil?

    title_cell = row.css(".tit a, .title a, td.tit a, td.title a").first
    title      = (title_cell || row.css("a").first)&.text&.strip
    title      = nil if title.nil? || title.empty?

    {
      notice_id:    notice_id,
      title:        title,
      author:       row.css(".writer, .author, td.writer, td.author").first&.text&.strip,
      view_count:   parse_int(row.css(".hit, .view, td.hit, td.view").first&.text),
      published_at: row.css(".date, td.date, time").first&.text&.strip,
    }
  end
end

# ---------------------------------------------------------------------------
# Fetches the detail page of a single notice.
# Returns a Nokogiri::HTML::Document.
# ---------------------------------------------------------------------------
def fetch_notice_detail(nt_type, notice_id)
  client = KOCWClient.new
  client.get("/home/notice/noticeView.do", { nt: nt_type, noticeId: notice_id })
end

# ---------------------------------------------------------------------------
# Persists a notice (or newsletter) into the appropriate table.
# Uses INSERT OR REPLACE so re-runs are idempotent.
# ---------------------------------------------------------------------------
def save_notice(db, nt_type, notice_data)
  case nt_type
  when 1
    db.execute(
      "INSERT OR REPLACE INTO notices (notice_id, notice_type, title, author, view_count, published_at, content_html) VALUES (?, ?, ?, ?, ?, ?, ?)",
      [
        notice_data[:notice_id],
        nt_type,
        notice_data[:title],
        notice_data[:author],
        notice_data[:view_count] || 0,
        notice_data[:published_at],
        notice_data[:content_html],
      ],
    )
  when 2
    db.execute(
      "INSERT OR REPLACE INTO newsletters (notice_id, title, author, view_count, published_at, content_html) VALUES (?, ?, ?, ?, ?, ?)",
      [
        notice_data[:notice_id],
        notice_data[:title],
        notice_data[:author],
        notice_data[:view_count] || 0,
        notice_data[:published_at],
        notice_data[:content_html],
      ],
    )
  else
    return false
  end
  true
end

# ---------------------------------------------------------------------------
# Extracts the notice_id from a list row by inspecting link href / data-* /
# onclick attributes. Returns Integer or nil.
# ---------------------------------------------------------------------------
def extract_notice_id(row)
  link = row.css("a").find { |a| href = a["href"].to_s; href.include?("noticeId") || href.include?("noticeView") }
  return nil unless link

  href = link["href"].to_s
  if (m = href.match(/noticeId=(\d+)/))
    m[1].to_i
  elsif (m = href.match(/noticeView\.do\?nt=(\d+)&noticeId=(\d+)/))
    m[2].to_i
  elsif link["data-id"] && link["data-id"] =~ /\d+/
    link["data-id"].to_i
  elsif (onclick = link["onclick"].to_s) && (m = onclick.match(/(\d+)/))
    m[1].to_i
  end
end

# ---------------------------------------------------------------------------
# Best-effort integer parse: keeps digits, drops the rest.
# ---------------------------------------------------------------------------
def parse_int(text)
  return 0 if text.nil?
  Integer(text.to_s.gsub(/[^\d]/, ""), 10)
rescue ArgumentError
  0
end

# ---------------------------------------------------------------------------
# Extracts the rendered HTML body from a detail page.
# ---------------------------------------------------------------------------
def extract_detail_html(doc)
  return nil unless doc.is_a?(Nokogiri::HTML::Document)

  container = doc.css(".board_view, .view_content, .content, .notice_view").first
  container ? container.to_html : nil
end

# ---------------------------------------------------------------------------
# Entry point.
# ---------------------------------------------------------------------------
def main
  unless File.exist?(DB_PATH)
    abort("Database not found at #{DB_PATH}. Run db/migrate.rb (or bin/init_db.rb) first.")
  end

  db = SQLite3::Database.new(DB_PATH)

  total_saved  = 0
  total_errors = 0

  NOTICE_LABELS.each do |nt_type, label|
    puts "[#{label}] starting (nt_type=#{nt_type})"

    PAGE_RANGE.each do |page|
      begin
        puts "  -> fetching page #{page}"
        doc     = fetch_notice_list(nt_type, page)
        notices = parse_notice_list(doc)

        if notices.empty?
          puts "     (no rows on page #{page})"
          next
        end

        puts "     found #{notices.size} notice(s) on page #{page}"

        notices.each do |notice|
          begin
            detail_doc   = fetch_notice_detail(nt_type, notice[:notice_id])
            notice[:content_html] = extract_detail_html(detail_doc)

            if save_notice(db, nt_type, notice)
              total_saved += 1
              puts "     + saved notice_id=#{notice[:notice_id]} title=#{notice[:title].inspect}"
            end
          rescue StandardError => e
            total_errors += 1
            warn "     ! detail error notice_id=#{notice[:notice_id]}: #{e.class}: #{e.message}"
          end
        end
      rescue StandardError => e
        total_errors += 1
        warn "  ! list error nt_type=#{nt_type} page=#{page}: #{e.class}: #{e.message}"
      end
    end
  end

  db.close
  puts "[DONE] saved=#{total_saved} errors=#{total_errors}"
end

main if $PROGRAM_NAME == __FILE__