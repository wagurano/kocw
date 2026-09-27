# frozen_string_literal: true

require "httparty"
require "nokogiri"
require "json"

# HTTP client for scraping the KOCW (Korean OpenCourseWare) website.
#
# Features:
# - Polite 1-second delay between requests
# - Automatic retry with exponential backoff on 500-class responses
# - Response parsing: JSON for AJAX endpoints, Nokogiri::HTML for HTML pages
#
# Usage:
#   client = KOCWClient.new
#   doc    = client.get("/Home/Course/view/{courseId}")           # => Nokogiri::HTML::Document
#   data   = client.get("/Home/Api/someEndpoint", { id: 42 })     # => Hash
class KOCWClient
  include HTTParty

  BASE_URL       = "http://www.kocw.net"
  USER_AGENT     = "KOCW-Archive-Bot/0.1 (Research; kocw-archive)"
  REQUEST_DELAY  = 1.0   # seconds between requests
  MAX_RETRIES    = 3
  INITIAL_BACKOFF = 1.0  # seconds; doubled on each retry

  # Paths matching this regex are treated as AJAX/JSON endpoints.
  JSON_PATH_PATTERN = %r{/Api/|/api/}

  headers "User-Agent" => USER_AGENT
  default_options.update(headers: { "User-Agent" => USER_AGENT })

  def initialize(base_url: BASE_URL, logger: nil)
    self.class.base_uri(base_url)
    @base_url = base_url
    @logger   = logger
    @mutex    = Mutex.new
  end

  # GET request. Returns Nokogiri::HTML::Document for HTML responses
  # or Hash for JSON responses.
  def get(path, params = {})
    request(:get, path, params)
  end

  # POST request. Returns Nokogiri::HTML::Document for HTML responses
  # or Hash for JSON responses.
  def post(path, params = {})
    request(:post, path, params)
  end

  private

  def request(method, path, params)
    attempt = 0
    backoff = INITIAL_BACKOFF

    begin
      attempt += 1
      throttle!

      response = case method
                 when :get  then self.class.get(path, query: params)
                 when :post then self.class.post(path, body: params)
                 end

      raise ServerError.new(response.code, response.body) if retryable_status?(response.code)

      parse(response, path: path)
    rescue ServerError => e
      if attempt <= MAX_RETRIES
        log("Retry #{attempt}/#{MAX_RETRIES} after #{e.code} for #{method.upcase} #{path} (sleep #{backoff}s)")
        sleep(backoff)
        backoff *= 2
        retry
      else
        log("Giving up on #{method.upcase} #{path} after #{attempt} attempts: #{e.message}")
        raise
      end
    end
  end

  # Sleeps REQUEST_DELAY between requests, thread-safe.
  def throttle!
    @mutex.synchronize { sleep(REQUEST_DELAY) }
  end

  def retryable_status?(code)
    code.to_i >= 500
  end

  # Decides whether to parse as JSON or HTML based on the path hint
  # and response Content-Type header.
  def parse(response, path:)
    content_type = response.headers["content-type"].to_s.downcase

    if path.match?(JSON_PATH_PATTERN) || content_type.include?("json")
      JSON.parse(response.body)
    else
      Nokogiri::HTML(response.body)
    end
  end

  def log(message)
    return unless @logger
    @logger.info("[KOCWClient] #{message}")
  end

  # Raised internally to trigger the retry loop on 5xx responses.
  class ServerError < StandardError
    attr_reader :code, :body

    def initialize(code, body)
      @code = code
      @body = body.to_s[0, 200]
      super("HTTP #{code}: #{@body}")
    end
  end
end