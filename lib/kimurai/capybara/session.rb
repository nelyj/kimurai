require 'nokogiri'
require 'murmurhash3'
require 'concurrent'
require 'capybara'

require_relative 'session/driver'
require_relative 'session/memory'
require_relative 'session/cookies'
require_relative 'session/headers'
require_relative 'session/proxy'

# to do: check about methods namespace

module Capybara
  class Session
    RETRY_REQUEST_ERRORS = [Net::ReadTimeout].freeze

    class << self
      attr_accessor :logger
    end

    def self.logger
      @logger ||= Logger.new(STDOUT)
    end

    # todo refactor, change name (to `settings` maybe?)
    def self.options
      @options ||= {}
    end

    def self.stats
      @stats ||= Concurrent::Hash.new.merge({
        requests: 0,
        responses: 0,
        requests_errors: Hash.new(0)
      })
    end

    # def self.current_instances
    #   ObjectSpace.each_object(self).to_a
    # end

    ###

    def options
      @options ||= {}
    end

    def stats
      @stats ||= {
        requests: 0,
        responses: 0,
        requests_errors: {},
        memory: [0]
      }
    end

    # ToDo: maybe merge #post_request to this method. Something like
    # visit(visit_url, method: :get, delay:)
    alias_method :original_visit, :visit
    def visit(visit_uri, delay: options[:before_request_delay], max_retries: 3)
      process_delay(delay) if delay

      begin
        retries ||= 0
        sleep_interval ||= 0

        check_request_options

        self.class.stats[:requests] += 1
        stats[:requests] += 1
        logger.info "Session: started get request to: #{visit_uri}"

        original_visit(visit_uri)
      rescue *RETRY_REQUEST_ERRORS => e
        error = e.inspect
        self.class.stats[:requests_errors][error] += 1
        logger.error "Session: request visit error: #{error} (url: #{visit_uri})"

        if (retries += 1) < max_retries
          logger.info "Session: sleep #{(sleep_interval += 10)} seconds and process " \
            "another retry (#{retries}) to the  url #{visit_uri}"
          sleep(sleep_interval) and retry
        else
          logger.error "Session: All retries (#{retries}) to the url #{visit_uri} is gone, no luck"
          raise e
        end
      else
        self.class.stats[:responses] += 1
        stats[:responses] += 1
        logger.info "Session: finished get request to: #{visit_uri}"
      end
    ensure
      print_stats
    end

    # default Content-Type of request data is 'application/x-www-form-urlencoded'.
    # To use json instead, convert data from hash to json (data.to_json) and set 'Content-Type' header
    # as 'application/json'.
    def post_request(url, data:, headers: { "Content-Type" => "application/x-www-form-urlencoded" })
      if driver_type == :mechanize
        begin
          set_delay(delay) if delay
          check_request_options

          self.class.stats[:requests] += 1
          stats[:requests] += 1
          logger.info "Session: started post request to: #{visit_uri}"

          driver.browser.agent.post(url, data, headers)

          self.class.stats[:responses] += 1
          stats[:responses] += 1
          logger.info "Session: finished post request to: #{visit_uri}"
        rescue => e
          raise e
        ensure
          print_stats
        end
      else
        raise "Not implemented in this driver"
      end
    end

    # pass a lambda as an action or url to visit
    # to do: set restriction to mechanize
    # notice: not safe with #recreate_driver! (any interactions with more
    # than one window)
    # ToDo: add description how to use this method
    def within_new_window_by(action: nil, url: nil)
      case
      when action
        opened_window = window_opened_by { action.call }
        within_window(opened_window) do
          yield
          current_window.close
        end
      when url
        within_window(open_new_window) do
          visit(url)

          yield
          current_window.close
        end
      else
        raise "Specify action or url"
      end
    end

    def current_response
      Nokogiri::HTML(body)
    end

    def resize_to(width, height)
      case driver_type
      when :poltergeist
        current_window.resize_to(width, height)
      when :selenium
        current_window.resize_to(width, height)
      when :mechanize
        logger.debug "Session: mechanize driver don't support this method. Skipped."
      end
    end

    private
    def logger
      self.class.logger
    end

    def print_stats
      logger.info "Stats visits: requests: " \
        "#{self.class.stats[:requests]}, responses: #{self.class.stats[:responses]}"

      memory = current_memory
      stats[:memory] << memory
      logger.debug "Session: current_memory: #{memory}"
    end

    def process_delay(delay)
      interval = delay.class == Range ? rand(delay) : delay
      logger.debug "Session: sleeping (#{interval}) before request..."

      sleep interval
    end

    def check_request_options
      # todo add checkings for a driver type
      if limit = options[:recreate_if_memory_more_than]
        memory = current_memory
        if memory > limit
          logger.warn "Session: limit (#{limit}) of current_memory (#{memory}) is exceeded"
          recreate_driver!
        end
      end

      if options[:before_request_clear_cookies]
        clear_cookies!
        logger.debug "Session: cleared cookies before request"
      end

      if options[:before_request_set_random_user_agent]
        user_agent = self.class.options[:user_agents_list].sample
        add_header("User-Agent", user_agent)
        logger.debug "Session: changed user_agent before request"
      end
    end
  end
end
