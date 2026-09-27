#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/kocw_client'
require 'sqlite3'

DB_PATH = File.expand_path('../db/kocw_archive.db', __dir__)

# Fetches a JSON course listing from a KOCW AJAX endpoint.
def fetch_json_courses(endpoint, params)
  client = KOCWClient.new
  client.post(endpoint, params)
end

# Upserts a single course record into the courses table.
def save_course(db, course_data)
  sql = <<~SQL
    INSERT OR REPLACE INTO courses (
      kem_id, cid, title, professor, university, organization,
      department, term, year, description, content_type,
      ccl_license, thumbnail_url
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  SQL

  db.execute(sql, [
    course_data['kemId'],
    course_data['cid'],
    course_data['title'],
    course_data['professor'],
    course_data['university'],
    course_data['organization'],
    course_data['department'],
    course_data['term'],
    course_data['year'],
    course_data['description'],
    course_data['contentType'],
    course_data['cclLicense'],
    course_data['thumbnailUrl']
  ])
end

begin
  db      = SQLite3::Database.new(DB_PATH)
  endpoint = '/home/search/majorCourses/lev.do'
  saved    = 0

  (1..3).each do |page_num|
    response = fetch_json_courses(endpoint, {
      taxonCode:   '',
      sortOption:  'created_date_desc',
      page:        page_num
    })

    response['levCourseList'].each do |course|
      save_course(db, course)
      saved += 1
    end

    puts "Saved #{saved} courses"
  end
rescue StandardError => e
  warn "[fetch_courses] #{e.class}: #{e.message}"
  warn e.backtrace.first(5).join("\n") if e.backtrace
ensure
  db&.close
end
