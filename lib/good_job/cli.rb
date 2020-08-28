require 'thor'

module GoodJob
  class CLI < Thor
    RAILS_ENVIRONMENT_RB = File.expand_path("config/environment.rb")

    desc :start, <<~DESCRIPTION
      Executes queued jobs.

      All options can be configured with environment variables. 
      See option descriptions for the matching environment variable name.

      == Configuring queues
      Separate multiple queues with commas; exclude queues with a leading minus; 
      separate isolated execution pools with semicolons and threads with colons.

    DESCRIPTION
    method_option :max_threads,
                  type: :numeric,
                  banner: 'COUNT',
                  desc: "Maximum number of threads to use for working jobs. (env var: GOOD_JOB_MAX_THREADS, default: 5)"
    method_option :queues,
                  type: :string,
                  banner: "QUEUE_LIST",
                  desc: "Queues to work from. (env var: GOOD_JOB_QUEUES, default: *)"
    method_option :poll_interval,
                  type: :numeric,
                  banner: 'SECONDS',
                  desc: "Interval between polls for available jobs in seconds (env var: GOOD_JOB_POLL_INTERVAL, default: 1)"
    def start
      set_up_application!

      notifier = GoodJob::Notifier.new
      configuration = GoodJob::Configuration.new(options)
      scheduler = GoodJob::Scheduler.from_configuration(configuration)
      notifier.recipients << [scheduler, :create_thread]

      @stop_good_job_executable = false
      %w[INT TERM].each do |signal|
        trap(signal) { @stop_good_job_executable = true }
      end

      Kernel.loop do
        sleep 0.1
        break if @stop_good_job_executable || scheduler.shutdown? || notifier.shutdown?
      end

      notifier.shutdown
      scheduler.shutdown
    end

    default_task :start

    desc :cleanup_preserved_jobs, <<~DESCRIPTION
      Deletes preserved job records. 

      By default, GoodJob deletes job records when the job is performed and this
      command is not necessary.

      However, when `GoodJob.preserve_job_records = true`, the jobs will be
      preserved in the database. This is useful when wanting to analyze or
      inspect job performance.

      If you are preserving job records this way, use this command regularly
      to delete old records and preserve space in your database.

    DESCRIPTION
    method_option :before_seconds_ago,
                  type: :numeric,
                  banner: 'SECONDS',
                  default: 24 * 60 * 60,
                  desc: "Delete records finished more than this many seconds ago"
    def cleanup_preserved_jobs
      set_up_application!

      timestamp = Time.current - options[:before_seconds_ago]
      ActiveSupport::Notifications.instrument("cleanup_preserved_jobs.good_job", { before_seconds_ago: options[:before_seconds_ago], timestamp: timestamp }) do |payload|
        deleted_records_count = GoodJob::Job.finished(timestamp).delete_all

        payload[:deleted_records_count] = deleted_records_count
      end
    end

    no_commands do
      def set_up_application!
        require RAILS_ENVIRONMENT_RB
        return unless defined?(GOOD_JOB_LOG_TO_STDOUT) && GOOD_JOB_LOG_TO_STDOUT && !ActiveSupport::Logger.logger_outputs_to?(GoodJob.logger, STDOUT)

        GoodJob::LogSubscriber.loggers << ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(STDOUT))
        GoodJob::LogSubscriber.reset_logger
      end
    end
  end
end
