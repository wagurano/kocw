#!/usr/bin/env ruby
# frozen_string_literal: true

# bin/verify_assets.rb -- Verify thumbnail URLs from the courses table,
# recording accessibility results into the assets table.
#
# For each course with a non-null thumbnail_url (first 100 rows):
#   * Sends an HTTP HEAD request with a 5-second timeout.
#   * Classifies the result as one of:
#       - 'ok'      : HTTP 200
#       - 'failed'  : network timeout (Net::OpenTimeout / Net::ReadTimeout)
#       - 'broken'  : HTTP 404 or any 5xx response
#   * Records content_type and content_length from response headers.
#   * Upserts a row in the assets table via INSERT OR REPLACE.
#
# Usage:
#   bundle exec ruby bin/verify_assets.rb

require_relative '../lib/kocw_client'
require 'sqlite3'
require 'net/http'
require 'uri'

DB_PATH      = File.expand_path('../db/kocw_archive.db', __dir__)
LIMIT        = 100
HTTP_TIMEOUT = 5 # seconds, applied to both open and read
USER_AGENT   = 'KOCW-Archive-Bot/0.1 (Research; kocw-archive)'

# ---------------------------------------------------------------------------
# Performs an HTTP HEAD request to the given URL with a 5-second timeout.
# Returns a Hash with keys:
#   :status         - 'ok' | 'failed' | 'broken'
#   :content_type   - response Content-Type header (or nil)
#   :content_length - response Content-Length header parsed as Integer (or nil)
# ---------------------------------------------------------------------------
def check_thumbnail(url)
  uri  = URI.parse(url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.open_timeout = HTTP_TIMEOUT
  http.read_timeout = HTTP_TIMEOUT
  http.use_ssl = (uri.scheme == 'https')

  request = Net::HTTP::Head.new(uri.request_uri)
  request['User-Agent'] = USER_AGENT

  response = http.request(request)
  code     = response.code.to_i

  {
    status:         classify(code),
    content_type:   response['content-type'],
    content_length: parse_int_or_nil(response['content-length']),
  }
rescue Net::OpenTimeout, Net::ReadTimeout
  { status: 'failed', content_type: nil, content_length: nil }
rescue StandardError
  { status: 'broken', content_type: nil, content_length: nil }
end

# ---------------------------------------------------------------------------
# Maps an HTTP response code to one of the three recorded statuses.
#   200          -> 'ok'
#   404 or 5xx   -> 'broken'
#   anything else-> 'broken' (URL did not return the expected content)
# ---------------------------------------------------------------------------
def classify(http_code)
  case http_code
  when 200           then 'ok'
  when 404, 500..599 then 'broken'
  else                    'broken'
  end
end

# ---------------------------------------------------------------------------
# Best-effort integer parse. Returns Integer or nil.
# ---------------------------------------------------------------------------
def parse_int_or_nil(text)
  return nil if text.nil?

  Integer(text.to_s, 10)
rescue ArgumentError
  nil
end

# ---------------------------------------------------------------------------
# Upserts a row in the assets table via INSERT OR REPLACE so re-runs are
# idempotent.
# ---------------------------------------------------------------------------
def record_asset(db, course_id, url, result)
  db.execute(
    <<~SQL,
      INSERT OR REPLACE INTO assets (
        course_id, url, asset_type, status, content_type, content_length, checked_at
      ) VALUES (?, ?, 'thumbnail', ?, ?, ?, CURRENT_TIMESTAMP)
    SQL
    [
      course_id,
      url,
      result[:status],
      result[:content_type],
      result[:content_length],
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

  db = SQLite3::Database.new(DB_PATH)
  rows = db.execute(
    'SELECT id, thumbnail_url FROM courses WHERE thumbnail_url IS NOT NULL LIMIT ?',
    LIMIT,
  )

  total = rows.length
  if total.zero?
    puts '[verify_assets] No courses with thumbnails in database.'
    return
  end

  puts "[verify_assets] Checking #{total} thumbnail URL(s)"

  rows.each_with_index do |(course_id, url), idx|
    begin
      result = check_thumbnail(url)
      record_asset(db, course_id, url, result)
    rescue StandardError => e
      warn "  ! error on course_id=#{course_id}: #{e.class}: #{e.message}"
      puts "Checked #{idx + 1}/#{LIMIT}: ERROR #{url}"
      next
    end

    puts "Checked #{idx + 1}/#{LIMIT}: #{result[:status].upcase} #{url}"
  end

  db.close
end

main if $PROGRAM_NAME == __FILE__
