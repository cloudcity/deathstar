module Deathstar

  # This is the primary entry point for configuring asynchronous test suite runs.
  #
  # Configure and create an instance, then launch tests asynchronously using {#enqueue}.
  class TestSession < ActiveRecord::Base
    include Sidekiq::Worker
    sidekiq_options :retry => false, :backtrace => true

    belongs_to :end_point
    has_many :client_devices, :through => :end_point
    has_many :test_results, :dependent => :delete_all

    validates :devices, numericality: {only_integer: true, greater_than_or_equal_to: 1}
    validates :run_time, numericality: {only_integer: true, greater_than_or_equal_to: 0}

    before_validation :set_defaults, on: :create

    # @return [TestSession]
    def self.new_with_defaults # useful in the controller to serve the 'new' form w/ sensible defaults
      new.tap { |ts| ts.send :set_defaults }
    end

    # @!attribute [rw] test_names
    # @return [Array<String>]
    def test_names=(tn)
      @suite_names = nil
      tn = Array.wrap(tn)
      tn.reject!(&:blank?)
      write_attribute(:test_names, tn)
    end

    # XXX This is mostly for backward compatability.
    # @!attribute [rw] suite_names
    # @return [Array<String>]
    def suite_names
      @suite_names ||= test_names.map {|tn| tn.split('#',2).first }.uniq
    end

    # XXX This is mostly for backward compatability.
    # @!attribute [rw] suite_names
    # @return [Array<String>]
    def suite_names=(sns)
      @suite_names = Array.wrap(sns)
      write_attribute(:test_names, suite_classes.
        map {|sc| sc.test_names.map {|tn| "#{sc.name}##{tn}" } }.flatten)
      @suite_names
    end

    # Get the requested test_names for the given suite.
    # @param suite_class [Deathstar::Suite] suite subclass
    # @return [Array<String>] test names for the given suite
    def suite_test_names suite_class
      s = /^#{suite_class.name}#/
      test_names.select {|tn| tn.match(s) }.map{|tn| tn.split('#',2).last }.uniq
    end

    # Enqueue the TestSession to generate devices and start the suite(s). This is the primary
    # entry point for the dashboard code and the rake taks.
    #
    # @param worker_count [Integer] Number of active sidekiq workers.
    # @return [void]
    def enqueue worker_count=1
      self.class.perform_async(test_session_id: id, workers: worker_count)
    end

    # Register and login the required number of devices for this test session. If the
    # needed amount of devices is already cached this will be a noop. This method blocks
    # until registration and login are completed.
    #
    # @param count [Integer] Total number of devices to generate.
    # @return [void]
    def initialize_devices count=devices
      client = Client.new(base_url, max_concurrency: [count, 200].min) # Typheous gets flaky above 200
      if end_point.nil?
        update(end_point: EndPoint.find_or_create_by(base_url: base_url))
      end
      log "setup", "Checking for #{count} generated devices in the local database."
      end_point.generate_devices(count) {|progress| log "setup", "Devices: #{progress}" }
      log "setup", "Checking for #{count} logged in users."
      end_point.register_and_login_devices client,
                                           ->(r) { log "setup", "Logged in #{r[:response][:session_token]}" },
                                           ->(r) { log "setup", "Device registration or login failed: #{r}" }
    end

    # Add a result log message, also spits to stdout in development mode.
    #
    # @param test [String] test name or other string for grouping
    # @param message [String] logged message
    # @return [TestResult]
    def log test, message
      puts message if Rails.env.development?
      TestResult.new(suite_name: self.class.name, test_name: test, messages: message).tap do |tr|
        test_results << tr
      end
    end

    # Safely return the suites as classes.
    # @return [Array<Class>]
    def suite_classes
      suite_names.map(&:safe_constantize).compact
    end

    # @!visibility private
    # This is not meant to be used by developers, but is an entry point for Sidekiq.
    # The worker initializes the needed devices before starting the test suites.
    def perform opts={}
      session = self.class.find(opts['test_session_id'])
      workers = opts['workers']
      session.initialize_devices(workers * session.devices)
      session.suite_classes.each do |s|
        offset = 0
        workers.times do
          s.perform_async(test_session_id:session.id, device_offset:offset, test_names:session.suite_test_names(s))
          offset += session.devices
        end
      end
    end

    private

    def set_defaults
      self.devices = ENV['DEVICES'] || 50 if self.devices.blank?
      self.run_time = ENV['RUN_TIME'] || 0 if self.run_time.blank?
    end

  end
end
