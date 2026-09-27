#!/usr/bin/env ruby
# frozen_string_literal: true

# bin/fetch_statistics.rb -- Fetch KOCW statistics from main + stats sites.
#
# Part A -- main site: Iterate years 2020..2026 and months 1..12, hit the
#   Excel export endpoint, and record one statistics row per (year, month).
#   The endpoint returns an Excel binary; this stage only logs that the
#   download was attempted. Actual workbook parsing is left for a follow-up.
#
# Part B -- stats site: Scrape https://kocwstats.netlify.app/, extract the
#   hardcoded JS data objects (MONTHLY_DATA / ANNUAL_DATA / DB_MONTHLY /
#   DB_ANNUAL) via regex, JSON.parse their bodies, and persist every
#   (metric_name, year, month) leaf into the statistics table.
#
# Both parts use INSERT OR REPLACE so re-runs are idempotent.
#
# Usage:
#   bundle exec ruby bin/fetch_statistics.rb

require_relative '../lib/kocw_client'
require 'sqlite3'
require 'json'
require 'net/http'
require 'uri'

DB_PATH            = File.expand_path('../db/kocw_archive.db', __dir__)
STATS_SITE_URL     = 'https://kocwstats.netlify.app/'
MAIN_SITE_YEARS    = (2020..2026).freeze
MAIN_SITE_MONTHS   = (1..12).freeze
MAIN_STAT_ENDPOINT = '/home/kocwStatisticsExcel.do'
MAIN_METRIC_NAME   = 'excel_download'

# Hardcoded JS data objects to extract from the stats site HTML.
STATS_OBJECT_NAMES = %w[MONTHLY_DATA ANNUAL_DATA DB_MONTHLY DB_ANNUAL].freeze

USER_AGENT = 'KOCW-Archive-Bot/0.1 (Research; kocw-archive)'

# ---------------------------------------------------------------------------
# Main site: walk every (year, month) combination, call the Excel export
# endpoint, and persist a single-row marker per attempt.
# ---------------------------------------------------------------------------
def fetch_main_site_statistics(db, client)
  saved = 0
  MAIN_SITE_YEARS.each do |year|
    MAIN_SITE_MONTHS.each do |month|
      begin
        client.get(MAIN_STAT_ENDPOINT, year: year, month: month)
        upsert_statistic(
          db,
          source:      'main_site',
          metric_name: MAIN_METRIC_NAME,
          category:    'main_site',
          year:        year,
          month:       month,
          value:       1,
          unit:        'count'
        )
        saved += 1
        puts "[main_site] recorded #{MAIN_METRIC_NAME} #{year}-#{format('%02d', month)}"
      rescue StandardError => e
        warn "[main_site] #{year}-#{month}: #{e.class}: #{e.message}"
      end
    end
  end
  saved
end

# ---------------------------------------------------------------------------
# Stats site: HTTP fetch, regex-extract JS blobs, JSON.parse, persist leaves.
# ---------------------------------------------------------------------------
def fetch_stats_site(db)
  html  = http_get(STATS_SITE_URL)
  blobs = extract_js_objects(html)

  total = 0
  STATS_OBJECT_NAMES.each do |var_name|
    json_text = blobs[var_name]
    next if json_text.nil? || json_text.empty?

    begin
      data = JSON.parse(json_text)
    rescue JSON::ParserError => e
      warn "[stats_site] skipping #{var_name}: #{e.class}: #{e.message}"
      next
    end

    unless data.is_a?(Hash)
      warn "[stats_site] #{var_name}: top-level JSON is not an object, skipping"
      next
    end

    total += persist_stats_data(db, data)
  end
  total
end

# Performs a simple GET via Net::HTTP. Used for the stats site because it is
# a Netlify static page unrelated to the KOCW HTTP client.
def http_get(url)
  uri = URI(url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = (uri.scheme == 'https')

  req = Net::HTTP::Get.new(uri.request_uri)
  req['User-Agent'] = USER_AGENT

  resp = http.request(req)
  unless resp.is_a?(Net::HTTPSuccess)
    raise "HTTP #{resp.code} for #{url}"
  end
  resp.body
end

# Extracts the body of each `const NAME = ({...});` JS assignment from the
# HTML. The /m flag lets `.*?` span newlines so multi-line JSON in <script>
# blocks is captured as a single match.
def extract_js_objects(html)
  result = {}
  STATS_OBJECT_NAMES.each do |name|
    pattern = /const\s+#{Regexp.escape(name)}\s*=\s*(\{.*?\});/m
    match = html.match(pattern)
    result[name] = match && match[1]
  end
  result
end

# Walks a parsed JSON data tree and writes one statistics row per leaf.
# Supports two leaf shapes:
#   { "2024" => { "1" => 12345, ... } }   -- monthly breakdown
#   { "2024" => 12345, ... }              -- annual totals (month=nil)
def persist_stats_data(db, data)
  count = 0
  data.each do |metric_name, year_data|
    next unless year_data.is_a?(Hash)

    category = categorize(metric_name)

    year_data.each do |year_str, month_data|
      year = parse_int(year_str)
      next if year.nil? || year.zero?

      case month_data
      when Hash
        month_data.each do |month_str, value|
          month = parse_int(month_str)
          next if month.nil? || month.zero?
          next unless numeric?(value)

          upsert_statistic(
            db,
            source:      'stats_site',
            metric_name: metric_name,
            category:    category,
            year:        year,
            month:       month,
            value:       value.to_f,
            unit:        'count'
          )
          count += 1
        end
      else
        next unless numeric?(month_data)
        upsert_statistic(
          db,
          source:      'stats_site',
          metric_name: metric_name,
          category:    category,
          year:        year,
          month:       nil,
          value:       month_data.to_f,
          unit:        'count'
        )
        count += 1
      end
    end
  end
  count
end

# Infers a category label from the metric name. Falls back to 'other'.
def categorize(metric_name)
  name = metric_name.to_s.downcase
  return 'web_access'  if name.include?('wv') || name.include?('web')
  return 'mobile'      if name.include?('mv') || name.include?('mobile')
  return 'search'      if name.include?('search')
  return 'certificate' if name.include?('cert')
  return 'api'         if name.include?('api')
  return 'lecture_db'  if name.start_with?('db_') || name.include?('lecture')

  'other'
end

def numeric?(value)
  value.is_a?(Numeric)
end

def parse_int(value)
  Integer(value.to_s, 10)
rescue ArgumentError, TypeError
  nil
end

# Single-row INSERT OR REPLACE into statistics.
def upsert_statistic(db, source:, metric_name:, category:, year:, month:, value:, unit:)
  db.execute(
    <<~SQL,
      INSERT OR REPLACE INTO statistics (
        source, metric_name, category, year, month, value, unit
      ) VALUES (?, ?, ?, ?, ?, ?, ?)
    SQL
    [source, metric_name, category, year, month, value, unit]
  )
end

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
begin
  unless File.exist?(DB_PATH)
    abort("Database not found at #{DB_PATH}. Run db/migrate.rb first.")
  end

  db     = SQLite3::Database.new(DB_PATH)
  client = KOCWClient.new

  main_count = fetch_main_site_statistics(db, client)
  puts "[main_site] recorded #{main_count} statistics"

  stats_count = fetch_stats_site(db)
  puts "Parsed #{stats_count} statistics from stats site"
rescue StandardError => e
  warn "[fetch_statistics] #{e.class}: #{e.message}"
  warn e.backtrace.first(5).join("\n") if e.backtrace
ensure
  db&.close
end
