#!/usr/bin/env ruby
# frozen_string_literal: true

# bin/export_csv.rb -- Export every KOCW archive table to its own CSV file
# under data/csv/.
#
# For each table in TABLES this script:
#   * Reads the column list from PRAGMA table_info(table).
#   * Runs SELECT * FROM table.
#   * Writes a header row followed by one row per result.
#   * Sanitizes text fields: strips HTML tags, collapses internal whitespace
#     (including newlines) into single spaces, and drops NUL bytes.
#
# Empty tables are written as header-only CSVs so the file still exists.
#
# Usage:
#   bundle exec ruby bin/export_csv.rb

require 'sqlite3'
require 'csv'
require 'fileutils'

DB_PATH     = File.expand_path('../db/kocw_archive.db', __dir__)
CSV_DIR     = File.expand_path('../data/csv', __dir__)
TABLES      = %w[courses episodes notices newsletters links assets statistics].freeze
HTML_TAG_RE = /<[^>]*>/.freeze

# Sanitize a single cell. Non-strings (Integer, Float, nil, etc.) are
# returned untouched so the CSV layout stays aligned with the SQLite types.
def sanitize(value)
  return value unless value.is_a?(String)

  value.gsub(HTML_TAG_RE, '').gsub(/\s+/, ' ').delete("\0").strip
end

db = SQLite3::Database.new(DB_PATH)
FileUtils.mkdir_p(CSV_DIR)

TABLES.each do |table|
  csv_path = File.join(CSV_DIR, "#{table}.csv")

  # PRAGMA returns rows like [cid, name, type, notnull, dflt_value, pk];
  # column 1 is the column name we want for the header row.
  columns = db.execute("PRAGMA table_info(#{table})").map { |row| row[1] }
  rows    = db.execute("SELECT * FROM #{table}")

  CSV.open(csv_path, 'w', headers: true) do |csv|
    csv << columns
    rows.each { |row| csv << row.map { |cell| sanitize(cell) } }
  end

  puts "Exported #{rows.length} rows from #{table}"
end