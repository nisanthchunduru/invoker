module Invoker
  # Class is responsible for managing all the processes Invoker is supposed
  # to manage. Takes care of starting, stopping and restarting processes.
  class ProcessManager
    LABEL_COLORS = [:green, :yellow, :blue, :magenta, :cyan]
    attr_accessor :open_pipes, :workers

    def initialize
      @open_pipes = {}
      @workers = {}
      @worker_mutex = Mutex.new
      @thread_group = ThreadGroup.new
    end

    def start_process(process_info)
      m, s = PTY.open
      s.raw! # disable newline conversion.

      pid = run_command(process_info, s)

      s.close

      worker = CommandWorker.new(process_info.label, m, pid, select_color)

      add_worker(worker)
      wait_on_pid(process_info.label, pid)
    end

    # Start a process given their name
    # @param process_name [String] Command label of process specified in config file.
    def start_process_by_name(process_name)
      if process_running?(process_name)
        Invoker::Logger.puts "\nProcess '#{process_name}' is already running".colorize(:red)
        return false
      end

      start_process_by_name_for_first_time(process_name)
    end

    def start_process_by_name_for_first_time(process_name)
      process_info = Invoker.config.process(process_name)
      start_process(process_info) if process_info
    end

    # Remove a process from list of processes managed by invoker supervisor.It also
    # kills the process before removing it from the list.
    #
    # @param remove_message [Invoker::IPC::Message::Remove]
    # @return [Boolean] if process existed and was removed else false
    def stop_process(remove_message)
      worker = workers[remove_message.process_name]
      command_label = remove_message.process_name
      return false unless worker
      signal_to_use = remove_message.signal || 'INT'

      Invoker::Logger.puts("Removing #{command_label} with signal #{signal_to_use}".colorize(:red))
      kill_or_remove_process(worker.pid, signal_to_use, command_label)
    end

    # Receive a message from user to restart a Process
    # @param [Invoker::IPC::Message::Reload]
    def restart_process(reload_message)
      command_label = reload_message.process_name
      if stop_process(reload_message.remove_message)
        Invoker.commander.schedule_event(command_label, :worker_removed) do
          start_process_by_name(command_label)
        end
      else
        start_process_by_name(command_label)
      end
    end

    def run_power_server
      return unless Invoker.can_run_balancer?(false)

      powerup_id = Invoker::Power::Powerup.fork_and_start
      wait_on_pid("powerup_manager", powerup_id)
      at_exit do
        begin
          Process.kill("INT", powerup_id)
        rescue Errno::ESRCH; end
      end
    end

    # Given a file descriptor returns the worker object
    #
    # @param fd [IO] an IO object with valid file descriptor
    # @return [Invoker::CommandWorker] The worker object which is associated with this fd
    def get_worker_from_fd(fd)
      open_pipes[fd.fileno]
    end

    def load_env(directory = nil)
      directory ||= ENV['PWD']

      if !directory || directory.empty? || !Dir.exist?(directory)
        return {}
      end

      default_env = File.join(directory, '.env')
      local_env = File.join(directory, '.env.local')
      env = {}

      if File.exist?(default_env)
        env.merge!(Dotenv::Environment.new(default_env))
      end

      if File.exist?(local_env)
        env.merge!(Dotenv::Environment.new(local_env))
      end

      env
    end

    def kill_workers
      @workers.each do |key, worker|
        kill_or_remove_process(worker.pid, "INT", worker.command_label)
      end
      @workers = {}
    end

    # List currently running commands
    def process_list
      Invoker::IPC::Message::ListResponse.from_workers(workers)
    end

    private

    def wait_on_pid(command_label, pid)
      raise Invoker::Errors::ToomanyOpenConnections if @thread_group.enclosed?

      thread = Thread.new do
        Process.wait(pid)
        message = "Process with command #{command_label} exited with status #{$?.exitstatus}"
        Invoker::Logger.puts("\n#{message}".colorize(:red))
        Invoker.notify_user(message)
        Invoker.commander.trigger(command_label, :exit)
      end
      @thread_group.add(thread)
    end

    def select_color
      selected_color = LABEL_COLORS.shift
      LABEL_COLORS.push(selected_color)
      selected_color
    end

    def process_running?(command_label)
      !!workers[command_label]
    end

    def kill_or_remove_process(pid, signal_to_use, command_label)
      process_kill(pid, signal_to_use)
      true
    rescue Errno::ESRCH
      Invoker::Logger.puts("Killing process with #{pid} and name #{command_label} failed".colorize(:red))
      remove_worker(command_label, false)
      false
    end

    def process_kill(pid, signal_to_use)
      if signal_to_use.to_i == 0
        Process.kill(signal_to_use, -Process.getpgid(pid))
      else
        Process.kill(signal_to_use.to_i, -Process.getpgid(pid))
      end
    end

    # Remove worker from all collections
    def remove_worker(command_label, trigger_event = true)
      worker = @workers[command_label]
      if worker
        @open_pipes.delete(worker.pipe_end.fileno)
        @workers.delete(command_label)
        # Move label color to front of array so it's reused first
        LABEL_COLORS.delete(worker.color)
        LABEL_COLORS.unshift(worker.color)
      end
      if trigger_event
        Invoker.commander.trigger(command_label, :worker_removed)
      end
    end

    # add worker to global collections
    def add_worker(worker)
      @open_pipes[worker.pipe_end.fileno] = worker
      @workers[worker.command_label] = worker
      Invoker.commander.watch_for_read(worker.pipe_end)
    end

    def run_command(process_info, write_pipe)
      command_label = process_info.label

      Invoker.commander.schedule_event(command_label, :exit) { remove_worker(command_label) }

      env_options = load_env(process_info.dir)

      spawn_options = {
        :chdir => process_info.dir || ENV['PWD'], :out => write_pipe, :err => write_pipe,
        :pgroup => true, :close_others => true, :in => :close
      }
      Invoker.run_without_bundler { spawn(env_options, process_info.cmd, spawn_options) }
    end
  end
end
