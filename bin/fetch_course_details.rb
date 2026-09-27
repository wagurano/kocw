#!/usr/bin/env ruby
# frozen_string_literal: true

# bin/fetch_course_details.rb -- Fetch and archive KOCW course detail pages.
#
# For each course already in the courses table, fetches the detail page at
# /home/cview.do and extracts:
#   * description / summary text  -> updates the courses row
#   * per-episode rows (number, title, description, duration, content_type)
#     -> upserts into the episodes table via INSERT OR REPLACE.
#
# Limited to the first 10 courses for safe testing. Re-runs are idempotent.
#
# Usage:
#   bundle exec ruby bin/fetch_course_details.rb

require_relative '../lib/kocw_client'
require 'sqlite3'
require 'nokogiri'

DB_PATH = File.expand_path('../db/kocw_archive.db', __dir__)

COURSE_LIMIT = 10

# CSS selectors tried in order when locating the detailed description block.
# The first match wins.
DESCRIPTION_SELECTORS = %w[
  .course_detail
  .detail_view
  .course_info
  .course_description
  .course_summary_view
].freeze

# CSS selectors tried in order when locating the short summary block.
SUMMARY_SELECTORS = %w[
  .course_summary
  .summary
  .abstract
  .course_abstract
].freeze

# CSS selectors tried in order when locating the episode list container.
EPISODE_LIST_SELECTORS = %w[
  .lecture_list
  .lec_list
  .episode_list
  .lectures
  .lecture
  .epi_list
].freeze

# CSS selectors tried in order to find an episode title inside a row.
EPISODE_TITLE_SELECTORS   = '.tit, .title, .lec_tit, .episode_tit, a'
# CSS selectors tried in order to find an episode number inside a row.
EPISODE_NUMBER_SELECTORS  = '.no, .num, .idx, .order, .episode_no'
# CSS selectors tried in order to find an episode description inside a row.
EPISODE_DESC_SELECTORS    = '.desc, .description, .lec_desc'
# CSS selectors tried in order to find an episode duration inside a row.
EPISODE_DURATION_SELECTORS = '.time, .duration, .runtime, .playtime'
# CSS selectors tried in order to find an episode content_type inside a row.
EPISODE_TYPE_SELECTORS    = '.type, .content_type'

# ---------------------------------------------------------------------------
# Fetches the detail page for a single course.
# Returns Nokogiri::HTML::Document (or whatever KOCWClient#get returns).
# ---------------------------------------------------------------------------
def fetch_course_detail(client, cid)
  client.get('/home/cview.do', { cid: cid })
end

# ---------------------------------------------------------------------------
# Pulls the detailed description and (optional) short summary from the page.
# Returns { description:, summary: } -- either field may be nil.
# ---------------------------------------------------------------------------
def extract_description(doc)
  return { description: nil, summary: nil } unless doc.is_a?(Nokogiri::HTML::Document)

  description_node = DESCRIPTION_SELECTORS.map { |sel| doc.css(sel).first }.compact.first
  summary_node     = SUMMARY_SELECTORS.map     { |sel| doc.css(sel).first }.compact.first

  {
    description: clean_text(description_node),
    summary:     clean_text(summary_node),
  }
end

# ---------------------------------------------------------------------------
# Finds the episode list container and returns parsed episode hashes.
# Returns Array<Hash> -- may be empty.
# ---------------------------------------------------------------------------
def extract_episodes(doc)
  return [] unless doc.is_a?(Nokogiri::HTML::Document)

  container = EPISODE_LIST_SELECTORS.map { |sel| doc.css(sel).first }.compact.first
  return [] unless container

  rows = container.css('li, tr, .item, .episode, .lec_item').to_a
  rows = container.css('>*').to_a if rows.empty?
  rows = [container] if rows.empty?

  rows.filter_map { |row| parse_episode_row(row) }
end

# ---------------------------------------------------------------------------
# Parses a single episode row into a hash. Returns nil for rows that have
# no usable title (filters out header / blank rows).
# ---------------------------------------------------------------------------
def parse_episode_row(row)
  title = clean_text(row.css(EPISODE_TITLE_SELECTORS).first)
  return nil if title.nil? || title.empty?

  {
    episode_number: parse_int_or_nil(row.css(EPISODE_NUMBER_SELECTORS).first&.text),
    title:          title,
    description:    clean_text(row.css(EPISODE_DESC_SELECTORS).first),
    duration:       clean_text(row.css(EPISODE_DURATION_SELECTORS).first),
    content_type:   parse_int_or_nil(row.css(EPISODE_TYPE_SELECTORS).first&.text),
    lecture_id:     extract_lecture_id(row),
  }
end

# ---------------------------------------------------------------------------
# Tries several attribute paths to find a lecture identifier on a row.
# Returns String or nil.
# ---------------------------------------------------------------------------
def extract_lecture_id(row)
  link = row.css('a').find { |a| a['href'].to_s.match?(/lecId|lectureId|lecture|view/i) } ||
         row.css('a').first
  return nil unless link

  href = link['href'].to_s
  data = (link['data-id'] || link['data-lec-id'] || link['data-lecture-id']).to_s

  if (m = href.match(/(?:lecId|lectureId)\s*=\s*(\d+)/) || href.match(%r{lecture/(\d+)}))
    m[1]
  elsif (m = data.match(/\d+/))
    m[0]
  elsif (m = href.match(/(\d+)/))
    m[1]
  end
end

# ---------------------------------------------------------------------------
# Best-effort text cleanup: collapses whitespace and strips.
# Accepts a Nokogiri node, NodeSet, or String.
# ---------------------------------------------------------------------------
def clean_text(node)
  return nil if node.nil?

  text = node.respond_to?(:text) ? node.text : node.to_s
  return nil if text.nil?

  cleaned = text.gsub(/\s+/, ' ').strip
  cleaned.empty? ? nil : cleaned
end

# ---------------------------------------------------------------------------
# Best-effort integer parse: keeps digits, drops the rest.
# Returns Integer or nil (when nothing parseable is found).
# ---------------------------------------------------------------------------
def parse_int_or_nil(text)
  return nil if text.nil?

  digits = text.to_s.gsub(/[^\d]/, '')
  return nil if digits.empty?

  Integer(digits, 10)
rescue ArgumentError
  nil
end

# ---------------------------------------------------------------------------
# Updates the description/summary fields on a course row, but only when at
# least one of them was extracted -- avoids clobbering existing data with
# NULL on a re-run where extraction failed.
# ---------------------------------------------------------------------------
def update_course_text(db, kem_id, description, summary)
  sets   = []
  params = []

  if description
    sets   << 'description = ?'
    params << description
  end
  if summary
    sets   << 'summary = ?'
    params << summary
  end
  return if sets.empty?

  sets   << 'updated_at = CURRENT_TIMESTAMP'
  params << kem_id

  db.execute(
    "UPDATE courses SET #{sets.join(', ')} WHERE kem_id = ?",
    params,
  )
end

# ---------------------------------------------------------------------------
# Upserts an episode row. Uses INSERT OR REPLACE so re-runs are idempotent.
# ---------------------------------------------------------------------------
def save_episode(db, course_id, episode)
  db.execute(
    <<~SQL,
      INSERT OR REPLACE INTO episodes (
        course_id, episode_number, title, description, duration, content_type, lecture_id
      ) VALUES (?, ?, ?, ?, ?, ?, ?)
    SQL
    [
      course_id,
      episode[:episode_number],
      episode[:title],
      episode[:description],
      episode[:duration],
      episode[:content_type],
      episode[:lecture_id],
    ],
  )
end

# ---------------------------------------------------------------------------
# Entry point.
# ---------------------------------------------------------------------------
def main
  unless File.exist?(DB_PATH)
    abort("Database not found at #{DB_PATH}. Run db/migrate.rb first.")
  end

  db     = SQLite3::Database.new(DB_PATH)
  client = KOCWClient.new

  courses = db.execute('SELECT kem_id, cid FROM courses LIMIT ?', COURSE_LIMIT)
  total   = courses.length

  if total.zero?
    puts '[fetch_course_details] No courses in database. Run bin/fetch_courses.rb first.'
    return
  end

  puts "[fetch_course_details] Processing #{total} course(s)"

  total_episodes = 0
  total_errors   = 0

  courses.each_with_index do |(kem_id, cid), idx|
    puts "Processing course #{idx + 1}/#{total}: #{kem_id}"
    begin
      doc    = fetch_course_detail(client, cid)
      fields = extract_description(doc)
      update_course_text(db, kem_id, fields[:description], fields[:summary])

      episodes = extract_episodes(doc)
      episodes.each { |ep| save_episode(db, kem_id, ep) }
      total_episodes += episodes.length

      puts "  + saved description + #{episodes.length} episode(s)"
    rescue StandardError => e
      total_errors += 1
      warn "  ! error on kem_id=#{kem_id} cid=#{cid}: #{e.class}: #{e.message}"
    end
  end

  db.close
  puts "[DONE] episodes=#{total_episodes} errors=#{total_errors}"
end

main if $PROGRAM_NAME == __FILE__
